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
    private var targetApp: TargetApp?
    private var lastFocusedTarget: FocusedTargetInfo?
    private var lastPasteResult: PasteResult?
    private var wakeWordStatus = WakeWordResources.setupStatus()
    private var latestEnglish = ""
    private var liveEnglish = ""
    private var currentStatus = "Ready"

    private let recorder = AudioRecorder()
    private let indicator = VoiceIndicator()
    private var audioStreamer: LiveAudioStreamer?
    private var audioBuffer: StreamingAudioBuffer?
    private var streamingClient: SarvamStreamingClient?
    private var warmStreamingClient: SarvamStreamingClient?
    private var isPreparingWarmClient = false
    private var recordingStartedAt: Date?
    private var activeRecordingID: UUID?
    private var didMarkFirstServerEvent = false
    private var didMarkFirstText = false
    private var latencyStartedAt: Date?
    private var latencyMarks: [String] = []
    private var pollTimer: Timer?
    private var debugWindow: NSWindow?
    private var debugTextView: NSTextView?
    private lazy var shortcutState = ShortcutStateMachine(
        startRecording: { [weak self] locked in self?.startRecording(locked: locked) },
        stopRecording: { [weak self] in self?.stopRecording() },
        statusChanged: { [weak self] status in self?.setStatus(status) }
    )

    private let statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
    private let permissionsMenuItem = NSMenuItem(title: "Permissions: Checking...", action: #selector(checkPermissions), keyEquivalent: "")
    private let hotkeyMenuItem = NSMenuItem(title: "Hotkey Enabled", action: #selector(toggleHotkey), keyEquivalent: "")
    private let livePreviewMenuItem = NSMenuItem(title: "Show Live Preview", action: #selector(toggleLivePreview), keyEquivalent: "")
    private let wakeWordStatusMenuItem = NSMenuItem(title: "Check Wake Word Setup", action: #selector(checkWakeWordSetup), keyEquivalent: "")
    private let shortcutMenu = NSMenu()
    private let microphoneMenu = NSMenu()

    deinit {
        NSLog("Indic Dictation: AppDelegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        requestNotificationPermission()
        checkPermissions()
        startPolling()
        prepareWarmStreamingClient()
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
        menu.addItem(.separator())

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

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy Last English", action: #selector(copyLastEnglish), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let wakeWordRoot = NSMenuItem(title: "Wake Word", action: nil, keyEquivalent: "")
        let wakeWordMenu = NSMenu()
        wakeWordStatusMenuItem.target = self
        wakeWordMenu.addItem(wakeWordStatusMenuItem)
        let openWakeWordFolderItem = NSMenuItem(title: "Open Wake Word Folder", action: #selector(openWakeWordFolder), keyEquivalent: "")
        openWakeWordFolderItem.target = self
        wakeWordMenu.addItem(openWakeWordFolderItem)
        wakeWordRoot.submenu = wakeWordMenu
        menu.addItem(wakeWordRoot)

        let diagnosticsRoot = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        let inspectFocusedItem = NSMenuItem(title: "Inspect Focused Target", action: #selector(inspectFocusedTarget), keyEquivalent: "")
        inspectFocusedItem.target = self
        diagnosticsMenu.addItem(inspectFocusedItem)
        let pasteTestItem = NSMenuItem(title: "Test Paste Into Current Field", action: #selector(testPasteIntoCurrentField), keyEquivalent: "")
        pasteTestItem.target = self
        diagnosticsMenu.addItem(pasteTestItem)
        diagnosticsRoot.submenu = diagnosticsMenu
        menu.addItem(diagnosticsRoot)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Open Debug Window", action: #selector(openDebugWindow), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        let permissionsRoot = NSMenuItem(title: "Open Permission Settings", action: nil, keyEquivalent: "")
        let permissionsMenu = NSMenu()
        permissionsMenu.addItem(settingsItem(title: "Microphone", action: #selector(openMicrophoneSettings)))
        permissionsMenu.addItem(settingsItem(title: "Input Monitoring", action: #selector(openInputMonitoringSettings)))
        permissionsMenu.addItem(settingsItem(title: "Accessibility", action: #selector(openAccessibilitySettings)))
        permissionsRoot.submenu = permissionsMenu
        menu.addItem(permissionsRoot)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Indic Dictation", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenu()
    }

    private func settingsItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollHotkey()
            }
        }
    }

    private func pollHotkey() {
        guard hotkeyEnabled else { return }
        let isPressed = ShortcutPoller.isPressed(selectedShortcut)
        shortcutState.update(isPressed: isPressed, now: Date().timeIntervalSinceReferenceDate)
    }

    @objc private func toggleHotkey() {
        hotkeyEnabled.toggle()
        if !hotkeyEnabled {
            shortcutState.reset()
        }
        setStatus(hotkeyEnabled ? "Ready" : "Hotkey off")
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

    @objc private func inspectFocusedTarget() {
        lastFocusedTarget = PasteHelper.focusedTargetInfo()
        if let lastFocusedTarget {
            setStatus("Focused: \(lastFocusedTarget.appName)")
        } else {
            setStatus("No focused target")
        }
        updateDebugWindow()
    }

    @objc private func testPasteIntoCurrentField() {
        let target = PasteHelper.captureFrontmostApp()
        do {
            lastPasteResult = try PasteHelper.paste("Indic Dictation paste test", into: target)
            setStatus("Paste test sent")
        } catch {
            setStatus("Paste test failed")
            showNotification(title: "Paste test failed", body: error.localizedDescription)
        }
        updateDebugWindow()
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

    @objc private func checkPermissions() {
        PermissionManager.requestInitialPrompts { [weak self] in
            self?.refreshMenu()
            self?.updateDebugWindow()
        }
        refreshMenu()
    }

    @objc private func openMicrophoneSettings() {
        PermissionManager.openSettings(.microphone)
    }

    @objc private func openInputMonitoringSettings() {
        PermissionManager.openSettings(.inputMonitoring)
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.openSettings(.accessibility)
    }

    @objc private func openDebugWindow() {
        if debugWindow == nil {
            createDebugWindow()
        }
        updateDebugWindow()
        debugWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startRecording(locked: Bool) {
        guard PermissionManager.microphoneGranted else {
            setStatus("Microphone permission needed")
            PermissionManager.requestMicrophone { [weak self] in
                self?.refreshMenu()
            }
            return
        }

        applySelectedMicrophoneBeforeRecording()

        targetApp = PasteHelper.captureFrontmostApp()
        latestEnglish = ""
        liveEnglish = ""
        latencyStartedAt = Date()
        latencyMarks = []
        didMarkFirstServerEvent = false
        didMarkFirstText = false
        let recordingID = UUID()
        activeRecordingID = recordingID
        markLatency("hotkey down")
        indicator.clearPreview()
        indicator.showRecording()
        let mode = locked ? "Locked recording" : "Recording"
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
                let qualityMode = await MainActor.run {
                    self.selectedQualityMode
                }
                let warmClient = await MainActor.run {
                    self.takeWarmStreamingClient(for: qualityMode)
                }
                let client = warmClient ?? SarvamStreamingClient(qualityMode: qualityMode)

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
                }
            }
        }
    }

    private func stopRecording() {
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
                let latency = Date().timeIntervalSince(startedAt)
                try await MainActor.run {
                    self.markLatency("stream finalized")
                    self.latestEnglish = result.text
                    self.prepareWarmStreamingClient()
                    guard PermissionManager.pasteEventsGranted else {
                        self.indicator.hide()
                        self.setStatus("Paste permission needed")
                        self.showNotification(title: "Permission needed", body: "Enable Accessibility for Indic Dictation to paste into other apps.")
                        return
                    }
                    guard !result.text.isEmpty else {
                        self.indicator.hide()
                        self.setStatus("No speech detected")
                        return
                    }
                    self.lastPasteResult = try PasteHelper.paste(result.text, into: targetApp)
                    self.markLatency("paste complete")
                    self.indicator.hide()
                    self.setStatus("Pasted. \(String(format: "%.1f", latency))s")
                }
            } catch {
                await MainActor.run {
                    self.prepareWarmStreamingClient()
                    self.indicator.hide()
                    self.setStatus("Error")
                    self.showNotification(title: "Dictation error", body: error.localizedDescription)
                }
            }
        }
    }

    private func configureStreamingClient(_ client: SarvamStreamingClient) {
        client.onText = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
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
                    self.indicator.showRecording()
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
        guard warmStreamingClient == nil, !isPreparingWarmClient else { return }
        isPreparingWarmClient = true
        let qualityMode = selectedQualityMode

        Task {
            let client = SarvamStreamingClient(qualityMode: qualityMode)
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

    private func takeWarmStreamingClient(for qualityMode: DictationQualityMode) -> SarvamStreamingClient? {
        guard let client = warmStreamingClient, client.isUsable, client.qualityMode == qualityMode else {
            warmStreamingClient?.close()
            warmStreamingClient = nil
            return nil
        }
        warmStreamingClient = nil
        return client
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
        hotkeyMenuItem.state = hotkeyEnabled ? .on : .off
        livePreviewMenuItem.state = livePreviewEnabled ? .on : .off
        wakeWordStatusMenuItem.title = wakeWordStatus.shortSummary
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
        debugTextView.string = """
        Status: \(currentStatus)
        Hotkey: \(hotkeyEnabled ? "Enabled" : "Disabled")
        Shortcut: \(selectedShortcut.name)
        Response Mode: \(selectedQualityMode.name)
        Microphone: \(microphoneDebugSummary())
        Target: \(target)

        Permissions:
        \(PermissionManager.detailedSummary)

        Wake Word:
        \(wakeWordStatus.detailedSummary)

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
