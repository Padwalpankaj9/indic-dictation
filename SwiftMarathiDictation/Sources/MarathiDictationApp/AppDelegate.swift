import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let systemDefaultMicrophoneUID = "__system_default__"

    private var statusItem: NSStatusItem!
    private var selectedShortcut = AppSettings.loadShortcut()
    private var selectedMicrophoneUID = AppSettings.loadSelectedMicrophoneUID()
    private let selectedQualityMode = DictationQualityMode.accurate
    private var hotkeyEnabled = true
    private var livePreviewEnabled = AppSettings.loadLivePreviewEnabled()
    private var polishEnabled = AppSettings.loadPolishEnabled()
    private var handsFreeModeEnabled = AppSettings.loadHandsFreeModeEnabled()
    private var wakeWordSensitivity = AppSettings.loadWakeWordSensitivity()
    private var isHandsFreeRecording = false
    private var handsFreeSpeechDetected = false
    private var handsFreeStartedAt: Date?
    private var handsFreeLastVoiceAt: Date?
    private var handsFreeStopShortcutWasPressed = false
    private let handsFreeIdleTimeout: TimeInterval = 10 * 60
    private let handsFreeIdleVoiceLevelThreshold: Float = 0.075
    private var handsFreeIdleTimer: Timer?
    private var handsFreeIdleLastActivityAt: Date?
    private var targetApp: TargetApp?
    private var lastTargetApp: TargetApp?
    private var lastFocusedTarget: FocusedTargetInfo?
    private var lastPasteResult: PasteResult?
    private var wakeWordStatus = WakeWordResources.setupStatus()
    private var latestWakeConfidence: Float?
    private var latestWakeStreak = 0
    private var lastWakeTriggerSamples: [Int16]?
    private var latestEnglish = ""
    private var liveEnglish = ""
    private var currentStatus = "Ready"
    private var asrPrompt = AppSettings.loadASRPrompt()
    private var lastStreamErrorMessage: String?
    private var lastTargetAppCapturedAt: Date?

    private let recorder = AudioRecorder()
    private let indicator = VoiceIndicator()
    private let functionKeyMonitor = FunctionKeyMonitor()
    private let wakeSampleRecorder = WakeWordSampleRecorder()
    private lazy var wakeWordListener = WakeWordListener(meter: indicator.meter)
    private var audioStreamer: LiveAudioStreamer?
    private var audioBuffer: StreamingAudioBuffer?
    private var streamingClient: SarvamStreamingClient?
    private var warmStreamingClient: SarvamStreamingClient?
    private var isPreparingWarmClient = false
    private var warmClientPingTimer: Timer?
    private var recordingStartedAt: Date?
    private var activeRecordingID: UUID?
    private var finalizingRecordingID: UUID?
    private var cancelledRecordingIDs: Set<UUID> = []
    private var escapeCancelWasPressed = false
    private var didMarkFirstServerEvent = false
    private var didMarkFirstText = false
    private var latencyStartedAt: Date?
    private var latencyMarks: [String] = []
    private var pollTimer: Timer?
    private var handsFreeSilenceTimer: Timer?
    private var debugWindow: NSWindow?
    private var debugTextView: NSTextView?
    private var isShowingAPIKeyWindow = false
    private let ignoredTargetBundleIdentifiers: Set<String> = {
        var identifiers: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver"
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            identifiers.insert(bundleIdentifier)
        }
        return identifiers
    }()
    private lazy var shortcutState = ShortcutStateMachine(
        startRecording: { [weak self] locked in self?.startRecording(locked: locked) },
        stopRecording: { [weak self] in self?.stopRecording() },
        statusChanged: { [weak self] status in self?.setStatus(status) }
    )

    private let statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
    private let permissionsMenuItem = NSMenuItem(title: "Permissions: Checking...", action: #selector(checkPermissions), keyEquivalent: "")
    private let apiKeyMenuItem = NSMenuItem(title: "API Key...", action: #selector(showAPIKeySettings), keyEquivalent: "")
    private let vocabularyMenuItem = NSMenuItem(title: "Vocabulary Hints...", action: #selector(showVocabularySettings), keyEquivalent: "")
    private let hotkeyMenuItem = NSMenuItem(title: "Hotkey Enabled", action: #selector(toggleHotkey), keyEquivalent: "")
    private let livePreviewMenuItem = NSMenuItem(title: "Show Live Preview", action: #selector(toggleLivePreview), keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Responses", action: #selector(togglePolish), keyEquivalent: "")
    private let handsFreeMenuItem = NSMenuItem(title: "Hands-free Mode", action: #selector(toggleHandsFreeMode), keyEquivalent: "")
    private let wakeWordConfidenceMenuItem = NSMenuItem(title: "Confidence: --", action: nil, keyEquivalent: "")
    private let wakeWordSensitivityMenuItem = NSMenuItem(title: "Sensitivity: 0.50", action: nil, keyEquivalent: "")
    private let shortcutMenu = NSMenu()
    private let microphoneMenu = NSMenu()
    private lazy var wakeWordSensitivitySlider: NSSlider = {
        let slider = NSSlider(
            value: wakeWordSensitivity,
            minValue: 0.0,
            maxValue: 1.0,
            target: self,
            action: #selector(changeWakeWordSensitivity(_:))
        )
        slider.isContinuous = false
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        slider.toolTip = "Lower is stricter. Higher wakes more easily."
        return slider
    }()
    private lazy var wakeWordSensitivitySliderItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))
        wakeWordSensitivitySlider.frame = NSRect(x: 14, y: 7, width: 192, height: 18)
        view.addSubview(wakeWordSensitivitySlider)
        item.view = view
        return item
    }()

    private var wakeWordThreshold: Float {
        Float(1.0 - wakeWordSensitivity)
    }

    deinit {
        NSLog("Indic Dictation: AppDelegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        requestNotificationPermission()
        checkPermissions()
        functionKeyMonitor.start()
        startPolling()
        let hasAPIKey = SarvamClient.hasConfiguredAPIKey()
        if hasAPIKey {
            prepareWarmStreamingClient()
            startWarmClientKeepalive()
        } else {
            setStatus("API key needed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showAPIKeySetupIfNeeded()
            }
        }
        if hasAPIKey, handsFreeModeEnabled {
            startWakeWordListener()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWakeWordListener()
        stopHandsFreeSilenceMonitor()
        stopHandsFreeIdleMonitor()
        functionKeyMonitor.stop()
        pollTimer?.invalidate()
        warmClientPingTimer?.invalidate()
    }

    private func configureStatusItem() {
        NSLog("Indic Dictation: configuring status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            if let iconURL = Bundle.module.url(forResource: "menubar-icon", withExtension: "png", subdirectory: "Icons"),
               let icon = NSImage(contentsOf: iconURL) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "MD"
            }
            button.toolTip = "Indic Dictation"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(statusMenuItem)
        permissionsMenuItem.target = self
        menu.addItem(permissionsMenuItem)
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)
        vocabularyMenuItem.target = self
        menu.addItem(vocabularyMenuItem)
        menu.addItem(.separator())

        handsFreeMenuItem.target = self
        handsFreeMenuItem.state = handsFreeModeEnabled ? .on : .off
        menu.addItem(handsFreeMenuItem)

        hotkeyMenuItem.target = self
        hotkeyMenuItem.state = .on
        menu.addItem(hotkeyMenuItem)

        let shortcutRoot = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutMenu.autoenablesItems = false
        for preset in AppSettings.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            shortcutMenu.addItem(item)
        }
        shortcutRoot.submenu = shortcutMenu
        menu.addItem(shortcutRoot)

        let microphoneRoot = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenu.autoenablesItems = false
        microphoneRoot.submenu = microphoneMenu
        menu.addItem(microphoneRoot)

        livePreviewMenuItem.target = self
        livePreviewMenuItem.state = livePreviewEnabled ? .on : .off
        menu.addItem(livePreviewMenuItem)

        polishMenuItem.target = self
        polishMenuItem.state = polishEnabled ? .on : .off
        polishMenuItem.toolTip = "Restructure dictated text into clean short paragraphs with \(PolishClient.model) before pasting."
        menu.addItem(polishMenuItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy Last English", action: #selector(copyLastEnglish), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let wakeWordRoot = NSMenuItem(title: "Wake Word", action: nil, keyEquivalent: "")
        let wakeWordMenu = NSMenu()
        wakeWordConfidenceMenuItem.isEnabled = false
        wakeWordMenu.addItem(wakeWordConfidenceMenuItem)
        wakeWordSensitivityMenuItem.isEnabled = false
        wakeWordMenu.addItem(wakeWordSensitivityMenuItem)
        wakeWordMenu.addItem(wakeWordSensitivitySliderItem)
        wakeWordRoot.submenu = wakeWordMenu
        menu.addItem(wakeWordRoot)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Indic Dictation", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenu()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollHotkey()
            }
        }
    }

    private func pollHotkey() {
        updateLastTargetApp()
        let isEscapePressed = ShortcutPoller.isEscapePressed()
        if isEscapePressed, !escapeCancelWasPressed {
            escapeCancelWasPressed = true
            if cancelActiveDictation(reason: "Cancelled") {
                return
            }
        } else if !isEscapePressed {
            escapeCancelWasPressed = false
        }

        let isPressed = ShortcutPoller.isPressed(selectedShortcut, functionKeyDown: functionKeyMonitor.isDown)
        if isHandsFreeRecording {
            if !handsFreeModeEnabled {
                cancelActiveDictation(reason: "Hands-free off")
                return
            }
            if activeRecordingID != nil, isPressed, !handsFreeStopShortcutWasPressed {
                handsFreeStopShortcutWasPressed = true
                setStatus("Manual stop")
                stopRecording()
            } else if !isPressed {
                handsFreeStopShortcutWasPressed = false
            }
            shortcutState.reset(notify: false)
            return
        }
        guard hotkeyEnabled else { return }
        shortcutState.update(isPressed: isPressed, now: Date().timeIntervalSinceReferenceDate)
        if debugWindow?.isVisible == true {
            updateDebugWindow()
        }
    }

    private func updateLastTargetApp() {
        guard activeRecordingID == nil, finalizingRecordingID == nil, !wakeSampleRecorder.isRecording else { return }
        // Accessibility lookups are expensive; twice a second is plenty since
        // recording start does its own fresh capture anyway.
        if let lastCheck = lastTargetAppCapturedAt, Date().timeIntervalSince(lastCheck) < 0.5 {
            return
        }
        lastTargetAppCapturedAt = Date()
        guard let app = PasteHelper.captureFrontmostApp(ignoring: ignoredTargetBundleIdentifiers) else { return }
        lastTargetApp = preferredTarget(captured: app)
    }

    private func preferredTarget(captured: TargetApp?) -> TargetApp? {
        guard let captured else {
            return lastTargetApp
        }

        if captured.hasFocusedElement {
            return captured
        }

        if let lastTargetApp,
           lastTargetApp.bundleIdentifier == captured.bundleIdentifier,
           lastTargetApp.hasFocusedElement {
            return lastTargetApp
        }

        return captured
    }

    @objc private func toggleHotkey() {
        hotkeyEnabled.toggle()
        if !hotkeyEnabled {
            shortcutState.reset()
        }
        setStatus(hotkeyEnabled ? "Ready" : "Hotkey off")
        refreshMenu()
    }

    @objc private func toggleHandsFreeMode() {
        handsFreeModeEnabled.toggle()
        AppSettings.saveHandsFreeModeEnabled(handsFreeModeEnabled)
        if handsFreeModeEnabled {
            startWakeWordListener()
        } else {
            if isHandsFreeRecording {
                cancelActiveDictation(reason: "Hands-free off")
            }
            stopWakeWordListener()
            stopHandsFreeSilenceMonitor()
            stopHandsFreeIdleMonitor()
        }
        setStatus(handsFreeModeEnabled ? "Hands-free ready" : "Hands-free off")
        refreshMenu()
    }

    @objc private func showAPIKeySettings() {
        showAPIKeyWindow(isFirstRun: false)
    }

    private func showAPIKeySetupIfNeeded() {
        guard !SarvamClient.hasConfiguredAPIKey() else { return }
        showAPIKeyWindow(isFirstRun: true)
    }

    private func showAPIKeyWindow(isFirstRun: Bool) {
        guard !isShowingAPIKeyWindow else { return }
        isShowingAPIKeyWindow = true
        defer { isShowingAPIKeyWindow = false }

        NSApp.activate(ignoringOtherApps: true)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Paste your Sarvam API key"
        field.focusRingType = .default

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isFirstRun ? "Set Up Sarvam API Key" : "Sarvam API Key"
        alert.informativeText = """
        Indic Dictation calls Sarvam directly from your Mac. Paste your own Sarvam API key here. It will be stored securely in macOS Keychain.
        """
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Key")
        alert.addButton(withTitle: isFirstRun ? "Later" : "Cancel")

        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            if isFirstRun {
                setStatus("API key needed")
            }
            return
        }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setStatus("API key needed")
            showNotification(title: "API key needed", body: "Paste a Sarvam API key before using dictation.")
            return
        }

        do {
            try SarvamAPIKeyStore.saveKey(key)
            setStatus("API key saved")
            showNotification(title: "API key saved", body: "Indic Dictation will use this key for Sarvam requests.")
            prepareWarmStreamingClient()
            startWarmClientKeepalive()
        } catch {
            setStatus("API key save failed")
            showNotification(title: "Could not save API key", body: error.localizedDescription)
        }
        refreshMenu()
    }

    @objc private func showVocabularySettings() {
        NSApp.activate(ignoringOtherApps: true)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.string = asrPrompt
        textView.isRichText = false
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Vocabulary Hints"
        alert.informativeText = """
        Names and terms you dictate often, separated by commas. Sarvam uses these as hints, so unusual words like names or work jargon come out right.
        """
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textView

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        asrPrompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.saveASRPrompt(asrPrompt)
        // The warm socket was opened with the old prompt, so swap it out.
        warmStreamingClient?.close()
        warmStreamingClient = nil
        prepareWarmStreamingClient()
        setStatus(asrPrompt.isEmpty ? "Vocabulary hints cleared" : "Vocabulary hints saved")
    }

    @objc private func changeWakeWordSensitivity(_ sender: NSSlider) {
        wakeWordSensitivity = min(1.0, max(0.0, sender.doubleValue))
        AppSettings.saveWakeWordSensitivity(wakeWordSensitivity)

        let shouldRestartListener = wakeWordListener.isRunning
        if shouldRestartListener {
            stopWakeWordListener()
            startWakeWordListener()
        }
        setStatus(String(format: "Wake sensitivity %.2f", wakeWordSensitivity))
        refreshMenu()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard
            let name = sender.representedObject as? String,
            let preset = AppSettings.presets.first(where: { $0.name == name })
        else {
            return
        }
        selectedShortcut = preset
        AppSettings.saveShortcut(preset)
        setStatus("Shortcut: \(preset.name)")
        refreshMenu()
    }

    @objc private func toggleLivePreview() {
        livePreviewEnabled.toggle()
        AppSettings.saveLivePreviewEnabled(livePreviewEnabled)
        if livePreviewEnabled, !liveEnglish.isEmpty, activeRecordingID != nil {
            indicator.setPreview(liveEnglish)
        } else {
            indicator.clearPreview()
        }
        setStatus(livePreviewEnabled ? "Live preview on" : "Live preview off")
        refreshMenu()
    }

    @objc private func togglePolish() {
        if !polishEnabled, !PolishClient.hasConfiguredAPIKey() {
            setStatus("OpenRouter key needed")
            showNotification(
                title: "OpenRouter key needed",
                body: "Add INDIC_DICTATION_OPENROUTER_API_KEY or OPENROUTER_API_KEY to ~/.config/shell/secrets.env to use polishing."
            )
            return
        }
        polishEnabled.toggle()
        AppSettings.savePolishEnabled(polishEnabled)
        setStatus(polishEnabled ? "Polish on" : "Polish off")
        refreshMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }

        if uid == Self.systemDefaultMicrophoneUID {
            selectedMicrophoneUID = nil
            AppSettings.saveSelectedMicrophoneUID(nil)
            setStatus("Mic: System Default")
            refreshMenu()
            return
        }

        selectedMicrophoneUID = uid
        AppSettings.saveSelectedMicrophoneUID(uid)

        do {
            let device = try AudioInputDeviceManager.applySelectedInput(uid: uid)
            setStatus("Mic: \(device?.name ?? "Selected")")
            if audioStreamer != nil {
                showNotification(
                    title: "Microphone changed",
                    body: "The new microphone will be used on the next recording."
                )
            }
        } catch {
            setStatus("Mic unavailable")
            showNotification(title: "Microphone unavailable", body: error.localizedDescription)
        }

        refreshMenu()
    }

    @objc private func refreshMicrophones() {
        rebuildMicrophoneMenu()
        setStatus("Microphones refreshed")
        updateDebugWindow()
    }

    @objc private func copyLastEnglish() {
        guard !latestEnglish.isEmpty else {
            setStatus("No English yet")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestEnglish, forType: .string)
        setStatus("Copied last English")
    }

    @objc private func checkWakeWordSetup() {
        wakeWordStatus = WakeWordResources.setupStatus()
        setStatus(wakeWordStatus.shortSummary)
        showNotification(title: "Wake Word", body: wakeWordStatus.shortSummary)
        updateDebugWindow()
    }

    @objc private func openWakeWordFolder() {
        do {
            try WakeWordResources.openDirectory()
            setStatus("Opened wake word folder")
        } catch {
            setStatus("Could not open folder")
            showNotification(title: "Wake word folder error", body: error.localizedDescription)
        }
        updateDebugWindow()
    }

    @objc private func recordWakeWordSample() {
        recordWakeWordTrainingSample(kind: .wake)
    }

    @objc private func recordNegativeWakeWordSample() {
        recordWakeWordTrainingSample(kind: .negative)
    }

    @objc private func openWakeWordTrainingFolder() {
        do {
            try WakeWordTrainingResources.openDirectory()
            setStatus("Opened training folder")
        } catch {
            setStatus("Could not open folder")
            showNotification(title: "Training folder error", body: error.localizedDescription)
        }
        refreshMenu()
    }

    @objc private func markLastWakeAsFalseTrigger() {
        guard let samples = lastWakeTriggerSamples else {
            setStatus("No wake sample to mark")
            return
        }

        do {
            let url = try WakeWordTrainingResources.saveSamples(samples, kind: .negative)
            lastWakeTriggerSamples = nil
            setStatus("False wake saved")
            showNotification(
                title: "False wake saved",
                body: "\(url.lastPathComponent) saved. Retrain wake word to apply it."
            )
        } catch {
            setStatus("False wake save failed")
            showNotification(title: "False wake save failed", body: error.localizedDescription)
        }
        refreshMenu()
    }

    @objc private func checkPermissions() {
        PermissionManager.requestInitialPrompts { [weak self] in
            self?.refreshMenu()
            self?.updateDebugWindow()
        }
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startRecording(locked: Bool) {
        guard activeRecordingID == nil else { return }
        if isHandsFreeRecording, !handsFreeModeEnabled {
            isHandsFreeRecording = false
            indicator.hide()
            setStatus("Hands-free off")
            return
        }
        guard !wakeSampleRecorder.isRecording else {
            setStatus("Sample recording active")
            return
        }

        guard SarvamClient.hasConfiguredAPIKey() else {
            setStatus("API key needed")
            showAPIKeyWindow(isFirstRun: true)
            return
        }

        guard PermissionManager.microphoneGranted else {
            setStatus("Microphone permission needed")
            PermissionManager.requestMicrophone { [weak self] in
                self?.refreshMenu()
            }
            return
        }

        applySelectedMicrophoneBeforeRecording()

        let capturedTarget = PasteHelper.captureFrontmostApp(ignoring: ignoredTargetBundleIdentifiers)
        targetApp = isHandsFreeRecording ? preferredTarget(captured: capturedTarget) : capturedTarget
        if let targetApp {
            lastTargetApp = targetApp
        }
        latestEnglish = ""
        liveEnglish = ""
        lastStreamErrorMessage = nil
        latencyStartedAt = Date()
        latencyMarks = []
        didMarkFirstServerEvent = false
        didMarkFirstText = false
        let recordingID = UUID()
        activeRecordingID = recordingID
        markLatency(isHandsFreeRecording ? "wake word" : "hotkey down")
        indicator.clearPreview()
        indicator.showRecording(targetFrame: targetApp?.frame)
        let mode = isHandsFreeRecording ? "Hands-free recording" : locked ? "Locked recording" : "Recording"
        setStatus("\(mode) into \(targetApp?.name ?? "unknown target")")

        let buffer = StreamingAudioBuffer()
        buffer.onFirstChunk = { [weak self] in
            Task { @MainActor in
                self?.markLatency("first mic chunk")
            }
        }
        buffer.onFirstSend = { [weak self] in
            Task { @MainActor in
                self?.markLatency("first audio sent")
            }
        }
        audioBuffer = buffer

        do {
            let streamer = LiveAudioStreamer(meter: indicator.meter) { data in
                buffer.append(data)
            }
            try streamer.start()
            audioStreamer = streamer
            recordingStartedAt = Date()
            markLatency("mic started")
        } catch {
            activeRecordingID = nil
            audioBuffer = nil
            indicator.hide()
            setStatus("Mic error")
            showNotification(title: "Microphone error", body: error.localizedDescription)
            return
        }

        Task {
            do {
                let (qualityMode, prompt) = await MainActor.run {
                    (self.selectedQualityMode, self.asrPrompt)
                }
                let warmClient = await MainActor.run {
                    self.takeWarmStreamingClient(for: qualityMode)
                }
                let client = warmClient ?? SarvamStreamingClient(qualityMode: qualityMode, prompt: prompt)

                let shouldAttach = await MainActor.run {
                    guard self.activeRecordingID == recordingID else {
                        return false
                    }
                    self.configureStreamingClient(client)
                    self.streamingClient = client
                    self.markLatency(warmClient == nil ? "websocket connecting" : "warm websocket used")
                    return true
                }
                guard shouldAttach else {
                    client.close()
                    return
                }

                if warmClient == nil || !client.isUsable {
                    try await client.connect()
                    await MainActor.run {
                        self.markLatency("websocket ready")
                    }
                }

                let stillRecording = await MainActor.run {
                    self.activeRecordingID == recordingID
                }
                guard stillRecording else {
                    client.close()
                    return
                }

                buffer.attach(client)
                await MainActor.run {
                    self.setStatus("Listening...")
                }
            } catch {
                await MainActor.run {
                    self.audioStreamer?.stop()
                    self.audioStreamer = nil
                    self.audioBuffer?.clear()
                    self.audioBuffer = nil
                    self.streamingClient = nil
                    self.activeRecordingID = nil
                    self.indicator.hide()
                    self.setStatus("Streaming error")
                    self.showNotification(title: "Streaming error", body: error.localizedDescription)
                    self.finishHandsFreeCycleIfNeeded()
                }
            }
        }
    }

    private func recordWakeWordTrainingSample(kind: WakeWordSampleKind) {
        guard audioStreamer == nil, activeRecordingID == nil else {
            setStatus("Finish dictation first")
            return
        }

        guard PermissionManager.microphoneGranted else {
            setStatus("Microphone permission needed")
            PermissionManager.requestMicrophone { [weak self] in
                self?.refreshMenu()
            }
            return
        }

        do {
            indicator.clearPreview()
            indicator.setPreview(kind.prompt)
            indicator.showRecording()
            let split = try wakeSampleRecorder.record(kind: kind) { [weak self] result in
                guard let self else { return }
                self.indicator.hide()
                switch result {
                case let .success(url):
                    self.setStatus("Saved sample: \(url.lastPathComponent)")
                    self.showNotification(title: "Wake sample saved", body: url.lastPathComponent)
                case let .failure(error):
                    self.setStatus("Sample failed")
                    self.showNotification(title: "Sample recording failed", body: error.localizedDescription)
                }
                self.refreshMenu()
            }
            setStatus("Recording \(split.rawValue). \(kind.prompt)")
        } catch {
            indicator.hide()
            setStatus("Sample failed")
            showNotification(title: "Sample recording failed", body: error.localizedDescription)
        }
        refreshMenu()
    }

    private func stopRecording() {
        guard audioStreamer != nil || streamingClient != nil || audioBuffer != nil else { return }
        guard let recordingID = activeRecordingID else { return }
        stopHandsFreeSilenceMonitor()
        let streamer = audioStreamer
        let buffer = audioBuffer
        let client = streamingClient
        let targetApp = self.targetApp
        let startedAt = recordingStartedAt ?? Date()

        markLatency("hotkey released")
        audioStreamer = nil
        audioBuffer = nil
        streamingClient = nil
        recordingStartedAt = nil
        activeRecordingID = nil
        finalizingRecordingID = recordingID

        streamer?.stop()
        indicator.showProcessing()
        setStatus("Finalizing...")

        Task {
            defer {
                buffer?.clear()
            }
            do {
                await MainActor.run {
                    self.markLatency("flush start")
                }
                await buffer?.drain()
                await MainActor.run {
                    self.markLatency("audio drained")
                }
                let result = await client?.finish() ?? StreamingTranslationResult(text: "", chunkCount: 0)

                // Optional second pass: restructure the text into clean short
                // paragraphs. Any failure quietly falls back to the raw text.
                let shouldPolish = await MainActor.run {
                    self.markLatency("stream finalized")
                    return self.polishEnabled && !result.text.isEmpty && !self.cancelledRecordingIDs.contains(recordingID)
                }
                var finalText = result.text
                if shouldPolish {
                    await MainActor.run {
                        self.setStatus("Polishing...")
                        self.markLatency("polish start")
                    }
                    finalText = await PolishClient().polishOrOriginal(result.text)
                    await MainActor.run {
                        self.markLatency("polish complete")
                    }
                }
                let pastedText = finalText

                let latency = Date().timeIntervalSince(startedAt)
                try await MainActor.run {
                    guard !self.cancelledRecordingIDs.contains(recordingID) else {
                        self.finishCancelledRecording(recordingID)
                        return
                    }
                    self.latestEnglish = pastedText
                    self.prepareWarmStreamingClient()
                    guard PermissionManager.pasteEventsGranted else {
                        if self.finalizingRecordingID == recordingID {
                            self.finalizingRecordingID = nil
                        }
                        self.indicator.hide()
                        self.setStatus("Paste permission needed")
                        self.showNotification(title: "Permission needed", body: "Enable Accessibility for Indic Dictation to paste into other apps.")
                        self.finishHandsFreeCycleIfNeeded()
                        return
                    }
                    guard !pastedText.isEmpty else {
                        if self.finalizingRecordingID == recordingID {
                            self.finalizingRecordingID = nil
                        }
                        self.indicator.hide()
                        // Tell the user the real reason instead of blaming the mic.
                        if let serverError = self.lastStreamErrorMessage {
                            self.setStatus("Sarvam error")
                            self.showNotification(title: "Sarvam error", body: serverError)
                        } else {
                            self.setStatus("No speech detected")
                        }
                        self.finishHandsFreeCycleIfNeeded()
                        return
                    }
                    self.lastPasteResult = try PasteHelper.paste(pastedText, into: targetApp)
                    self.markLatency("paste complete")
                    if self.finalizingRecordingID == recordingID {
                        self.finalizingRecordingID = nil
                    }
                    self.indicator.hide()
                    self.setStatus("Pasted. \(String(format: "%.1f", latency))s")
                    self.finishHandsFreeCycleIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.prepareWarmStreamingClient()
                    if self.finalizingRecordingID == recordingID {
                        self.finalizingRecordingID = nil
                    }
                    self.cancelledRecordingIDs.remove(recordingID)
                    self.indicator.hide()
                    self.setStatus("Error")
                    self.showNotification(title: "Dictation error", body: error.localizedDescription)
                    self.finishHandsFreeCycleIfNeeded()
                }
            }
        }
    }

    private func configureStreamingClient(_ client: SarvamStreamingClient) {
        client.onText = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeRecordingID != nil else { return }
                if !self.didMarkFirstText {
                    self.didMarkFirstText = true
                    self.markLatency("first English text")
                }
                self.liveEnglish = text
                if self.livePreviewEnabled {
                    self.indicator.setPreview(text)
                }
                if self.currentStatus != "Listening..." {
                    self.setStatus("Listening...")
                } else if self.debugWindow?.isVisible == true {
                    self.updateDebugWindow()
                }
            }
        }
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if !self.didMarkFirstServerEvent {
                    self.didMarkFirstServerEvent = true
                    self.markLatency("first server event")
                }
                if event == "START_SPEECH" {
                    guard self.activeRecordingID != nil else { return }
                    self.indicator.showRecording()
                }
                if event.hasPrefix("SERVER_ERROR: ") {
                    self.lastStreamErrorMessage = String(event.dropFirst("SERVER_ERROR: ".count))
                }
            }
        }
        client.onTiming = { [weak self] label in
            Task { @MainActor in
                self?.markLatency(label)
            }
        }
    }

    private func applySelectedMicrophoneBeforeRecording() {
        guard selectedMicrophoneUID != nil else { return }

        do {
            _ = try AudioInputDeviceManager.applySelectedInput(uid: selectedMicrophoneUID)
        } catch {
            NSLog("Indic Dictation: selected microphone unavailable: \(error)")
            showNotification(
                title: "Microphone unavailable",
                body: "Using the current system default microphone for this recording."
            )
        }
    }

    private func prepareWarmStreamingClient() {
        guard SarvamClient.hasConfiguredAPIKey() else { return }
        guard warmStreamingClient == nil, !isPreparingWarmClient else { return }
        isPreparingWarmClient = true
        let qualityMode = selectedQualityMode
        let prompt = asrPrompt

        Task {
            let client = SarvamStreamingClient(qualityMode: qualityMode, prompt: prompt)
            do {
                try await client.connect()
                await MainActor.run {
                    if self.warmStreamingClient == nil {
                        self.warmStreamingClient = client
                    } else {
                        client.close()
                    }
                    self.isPreparingWarmClient = false
                }
            } catch {
                await MainActor.run {
                    self.isPreparingWarmClient = false
                }
            }
        }
    }

    private func startWarmClientKeepalive() {
        warmClientPingTimer?.invalidate()
        warmClientPingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pingWarmStreamingClient()
            }
        }
    }

    // Idle sockets get killed quietly by servers and NATs. A ping every 30s
    // either keeps the warm socket alive or tells us to open a fresh one,
    // so dictation never starts on a dead connection.
    private func pingWarmStreamingClient() {
        guard let client = warmStreamingClient else { return }
        client.ping { [weak self] alive in
            Task { @MainActor in
                guard let self, self.warmStreamingClient === client else { return }
                guard !alive else { return }
                client.close()
                self.warmStreamingClient = nil
                self.prepareWarmStreamingClient()
            }
        }
    }

    private func takeWarmStreamingClient(for qualityMode: DictationQualityMode) -> SarvamStreamingClient? {
        guard let client = warmStreamingClient, client.isUsable, client.qualityMode == qualityMode, client.prompt == asrPrompt else {
            warmStreamingClient?.close()
            warmStreamingClient = nil
            return nil
        }
        warmStreamingClient = nil
        return client
    }

    private func startWakeWordListener() {
        guard handsFreeModeEnabled, activeRecordingID == nil, finalizingRecordingID == nil, !wakeSampleRecorder.isRecording, !wakeWordListener.isRunning else {
            return
        }
        guard PermissionManager.microphoneGranted else {
            setStatus("Microphone permission needed")
            PermissionManager.requestMicrophone { [weak self] in
                self?.refreshMenu()
            }
            return
        }

        applySelectedMicrophoneBeforeRecording()
        do {
            try wakeWordListener.start(
                threshold: wakeWordThreshold,
                onScore: { [weak self] confidence, streak in
                    self?.updateWakeScore(confidence: confidence, streak: streak)
                },
                onWake: { [weak self] confidence, samples in
                    self?.handleWakeWordDetected(confidence: confidence, samples: samples)
                }
            )
            startHandsFreeIdleMonitor()
            setStatus("Hands-free ready")
        } catch {
            handsFreeModeEnabled = false
            AppSettings.saveHandsFreeModeEnabled(false)
            stopHandsFreeIdleMonitor()
            setStatus("Hands-free unavailable")
            showNotification(title: "Hands-free unavailable", body: error.localizedDescription)
        }
        refreshMenu()
    }

    private func updateWakeScore(confidence: Float, streak: Int) {
        latestWakeConfidence = confidence
        latestWakeStreak = streak
        if let latestWakeConfidence {
            wakeWordConfidenceMenuItem.title = String(format: "Confidence: %.2f  Streak: %d", latestWakeConfidence, latestWakeStreak)
        }
        updateDebugWindow()
    }

    private func stopWakeWordListener() {
        wakeWordListener.stop()
        stopHandsFreeIdleMonitor()
        refreshMenu()
    }

    private func handleWakeWordDetected(confidence: Float, samples: [Int16]) {
        guard handsFreeModeEnabled, activeRecordingID == nil, finalizingRecordingID == nil else {
            if !handsFreeModeEnabled {
                stopWakeWordListener()
                indicator.hide()
            }
            return
        }
        handsFreeStopShortcutWasPressed = false
        lastWakeTriggerSamples = samples
        latestWakeConfidence = confidence
        latestWakeStreak = 2
        stopWakeWordListener()
        setStatus(String(format: "Wake heard %.2f", confidence))
        isHandsFreeRecording = true
        startRecording(locked: true)
        if activeRecordingID != nil {
            startHandsFreeSilenceMonitor()
        } else {
            finishHandsFreeCycleIfNeeded()
        }
    }

    private func startHandsFreeSilenceMonitor() {
        stopHandsFreeSilenceMonitor()
        handsFreeStartedAt = Date()
        handsFreeLastVoiceAt = nil
        handsFreeSpeechDetected = false

        handsFreeSilenceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHandsFreeSilence()
            }
        }
    }

    private func stopHandsFreeSilenceMonitor() {
        handsFreeSilenceTimer?.invalidate()
        handsFreeSilenceTimer = nil
    }

    private func checkHandsFreeSilence() {
        guard isHandsFreeRecording, activeRecordingID != nil, let startedAt = handsFreeStartedAt else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let level = indicator.meter.value
        if level > 0.075 {
            handsFreeSpeechDetected = true
            handsFreeLastVoiceAt = now
            return
        }

        guard elapsed >= 2.0 else { return }

        if handsFreeSpeechDetected, let handsFreeLastVoiceAt, now.timeIntervalSince(handsFreeLastVoiceAt) >= 1.5 {
            setStatus("Silence detected")
            stopRecording()
        } else if !handsFreeSpeechDetected, elapsed >= 8.0 {
            setStatus("No speech detected")
            stopRecording()
        }
    }

    private func finishHandsFreeCycleIfNeeded() {
        guard isHandsFreeRecording else { return }
        isHandsFreeRecording = false
        handsFreeSpeechDetected = false
        handsFreeStartedAt = nil
        handsFreeLastVoiceAt = nil
        handsFreeStopShortcutWasPressed = false
        if handsFreeModeEnabled {
            startWakeWordListener()
        }
    }

    @discardableResult
    private func cancelActiveDictation(reason: String) -> Bool {
        guard activeRecordingID != nil || finalizingRecordingID != nil || audioStreamer != nil || streamingClient != nil || audioBuffer != nil else {
            return false
        }

        let activeRecordingIDToCancel = activeRecordingID
        let finalizingRecordingIDToCancel = finalizingRecordingID
        if let activeRecordingIDToCancel {
            cancelledRecordingIDs.insert(activeRecordingIDToCancel)
        }
        if let finalizingRecordingIDToCancel {
            cancelledRecordingIDs.insert(finalizingRecordingIDToCancel)
        }

        stopHandsFreeSilenceMonitor()
        let streamer = audioStreamer
        let buffer = audioBuffer
        let client = streamingClient

        audioStreamer = nil
        audioBuffer = nil
        streamingClient = nil
        recordingStartedAt = nil
        activeRecordingID = nil
        finalizingRecordingID = nil
        liveEnglish = ""

        streamer?.stop()
        buffer?.clear()
        client?.close()
        shortcutState.reset(notify: false, stopActive: false)
        indicator.hide()
        setStatus(reason)
        prepareWarmStreamingClient()
        finishHandsFreeCycleIfNeeded()
        if finalizingRecordingIDToCancel == nil, let activeRecordingIDToCancel {
            cancelledRecordingIDs.remove(activeRecordingIDToCancel)
        }
        return true
    }

    private func finishCancelledRecording(_ recordingID: UUID) {
        cancelledRecordingIDs.remove(recordingID)
        if finalizingRecordingID == recordingID {
            finalizingRecordingID = nil
        }
        indicator.hide()
        setStatus("Cancelled")
        prepareWarmStreamingClient()
        finishHandsFreeCycleIfNeeded()
    }

    private func startHandsFreeIdleMonitor() {
        stopHandsFreeIdleMonitor()
        handsFreeIdleLastActivityAt = Date()
        handsFreeIdleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHandsFreeIdleTimeout()
            }
        }
    }

    private func stopHandsFreeIdleMonitor() {
        handsFreeIdleTimer?.invalidate()
        handsFreeIdleTimer = nil
        handsFreeIdleLastActivityAt = nil
    }

    private func checkHandsFreeIdleTimeout() {
        guard handsFreeModeEnabled, wakeWordListener.isRunning, activeRecordingID == nil else { return }

        let now = Date()
        if indicator.meter.value > handsFreeIdleVoiceLevelThreshold {
            handsFreeIdleLastActivityAt = now
            return
        }

        guard let lastActivity = handsFreeIdleLastActivityAt else {
            handsFreeIdleLastActivityAt = now
            return
        }
        guard now.timeIntervalSince(lastActivity) >= handsFreeIdleTimeout else { return }

        pauseHandsFreeAfterIdleTimeout()
    }

    private func pauseHandsFreeAfterIdleTimeout() {
        guard handsFreeModeEnabled else { return }

        handsFreeModeEnabled = false
        AppSettings.saveHandsFreeModeEnabled(false)
        stopWakeWordListener()
        stopHandsFreeSilenceMonitor()
        setStatus("Hands-free slept after 10m idle")
        showNotification(
            title: "Hands-free paused",
            body: "No voice activity for 10 minutes. Turn Hands-free Mode back on from the menu when you need it."
        )
        refreshMenu()
    }

    private func markLatency(_ label: String) {
        let now = Date()
        if latencyStartedAt == nil {
            latencyStartedAt = now
        }
        let elapsed = now.timeIntervalSince(latencyStartedAt ?? now)
        latencyMarks.append(String(format: "%6.3fs  %@", elapsed, label))
        if latencyMarks.count > 24 {
            latencyMarks.removeFirst(latencyMarks.count - 24)
        }
        updateDebugWindow()
    }

    private func setStatus(_ status: String) {
        currentStatus = status
        statusMenuItem.title = "Status: \(status)"
        updateDebugWindow()
    }

    private func refreshMenu() {
        wakeWordStatus = WakeWordResources.setupStatus()
        permissionsMenuItem.title = "Permissions: \(PermissionManager.compactSummary)"
        permissionsMenuItem.isHidden = PermissionManager.allRequiredGranted
        apiKeyMenuItem.title = SarvamClient.hasConfiguredAPIKey() ? "API Key: Set..." : "API Key: Needed..."
        hotkeyMenuItem.state = hotkeyEnabled ? .on : .off
        livePreviewMenuItem.state = livePreviewEnabled ? .on : .off
        polishMenuItem.state = polishEnabled ? .on : .off
        handsFreeMenuItem.state = handsFreeModeEnabled ? .on : .off
        if let latestWakeConfidence {
            wakeWordConfidenceMenuItem.title = String(format: "Confidence: %.2f  Streak: %d", latestWakeConfidence, latestWakeStreak)
        } else {
            wakeWordConfidenceMenuItem.title = "Confidence: --"
        }
        wakeWordSensitivityMenuItem.title = String(
            format: "Sensitivity: %.2f  Threshold: %.2f",
            wakeWordSensitivity,
            wakeWordThreshold
        )
        wakeWordSensitivitySlider.doubleValue = wakeWordSensitivity
        for item in shortcutMenu.items {
            item.state = item.title == selectedShortcut.name ? .on : .off
        }
        rebuildMicrophoneMenu()
        updateDebugWindow()
    }

    private func rebuildMicrophoneMenu() {
        microphoneMenu.removeAllItems()

        do {
            let devices = try AudioInputDeviceManager.inputDevices()
            let defaultDevice = try? AudioInputDeviceManager.defaultInputDevice()
            let currentItem = NSMenuItem(
                title: "Current: \(microphoneDisplayName(devices: devices, defaultDevice: defaultDevice))",
                action: nil,
                keyEquivalent: ""
            )
            currentItem.isEnabled = false
            microphoneMenu.addItem(currentItem)
            microphoneMenu.addItem(.separator())

            let systemTitle: String
            if let defaultDevice {
                systemTitle = "System Default (\(defaultDevice.name))"
            } else {
                systemTitle = "System Default"
            }
            let systemItem = NSMenuItem(title: systemTitle, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            systemItem.target = self
            systemItem.representedObject = Self.systemDefaultMicrophoneUID
            systemItem.state = selectedMicrophoneUID == nil ? .on : .off
            microphoneMenu.addItem(systemItem)

            if devices.isEmpty {
                let emptyItem = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                microphoneMenu.addItem(emptyItem)
            } else {
                microphoneMenu.addItem(.separator())
                for device in devices {
                    var title = device.name
                    if device.id == defaultDevice?.id {
                        title += " (system)"
                    }
                    let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = device.uid
                    item.state = selectedMicrophoneUID == device.uid ? .on : .off
                    microphoneMenu.addItem(item)
                }
            }
        } catch {
            let errorItem = NSMenuItem(title: "Could not load microphones", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            microphoneMenu.addItem(errorItem)
        }

        microphoneMenu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Microphones", action: #selector(refreshMicrophones), keyEquivalent: "")
        refreshItem.target = self
        microphoneMenu.addItem(refreshItem)
    }

    private func microphoneDisplayName(
        devices: [AudioInputDevice],
        defaultDevice: AudioInputDevice?
    ) -> String {
        if let uid = selectedMicrophoneUID {
            if let selectedDevice = devices.first(where: { $0.uid == uid }) {
                return selectedDevice.name
            }
            return "Selected mic unavailable"
        }

        if let defaultDevice {
            return "System Default: \(defaultDevice.name)"
        }

        return "System Default"
    }

    private func microphoneDebugSummary() -> String {
        do {
            let devices = try AudioInputDeviceManager.inputDevices()
            let defaultDevice = try? AudioInputDeviceManager.defaultInputDevice()
            return microphoneDisplayName(devices: devices, defaultDevice: defaultDevice)
        } catch {
            return "Unavailable"
        }
    }

    private func createDebugWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Indic Dictation Debug"
        window.center()

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        debugWindow = window
        debugTextView = textView
    }

    private func updateDebugWindow() {
        guard let debugTextView else { return }
        let latest = latestEnglish.isEmpty ? "(none)" : latestEnglish
        let live = liveEnglish.isEmpty ? "(none)" : liveEnglish
        let target = targetApp?.name ?? "(none)"
        let latency = latencyMarks.isEmpty ? "(none)" : latencyMarks.joined(separator: "\n")
        let focused = lastFocusedTarget?.summary ?? "(none)"
        let paste = lastPasteResult?.summary ?? "(none)"
        let samples = WakeWordTrainingResources.sampleCounts().debugSummary
        debugTextView.string = """
        Status: \(currentStatus)
        Hotkey: \(hotkeyEnabled ? "Enabled" : "Disabled")
        Hands-free: \(handsFreeModeEnabled ? "Enabled" : "Disabled")
        Wake Listener: \(wakeWordListener.isRunning ? "Running" : "Stopped")
        Wake Sensitivity: \(String(format: "%.2f", wakeWordSensitivity)) (threshold \(String(format: "%.2f", wakeWordThreshold)))
        Shortcut: \(selectedShortcut.name)
        Function Monitor: \(functionKeyMonitor.isListening ? "Running" : "Stopped"), tap \(functionKeyMonitor.tapLocationDescription), down \(functionKeyMonitor.isDown ? "yes" : "no"), last \(functionKeyMonitor.lastEventSummary)
        Response Mode: \(selectedQualityMode.name)
        Polish: \(polishEnabled ? PolishClient.model : "Off")
        Microphone: \(microphoneDebugSummary())
        Target: \(target)

        Permissions:
        \(PermissionManager.detailedSummary)

        Wake Word:
        \(wakeWordStatus.detailedSummary)

        Wake Word Samples:
        \(samples)

        Focused Target:
        \(focused)

        Last Paste:
        \(paste)

        Live English:
        \(live)

        Last English:
        \(latest)

        Latency:
        \(latency)
        """
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
