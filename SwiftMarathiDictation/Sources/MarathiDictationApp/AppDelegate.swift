import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var selectedShortcut = AppSettings.loadShortcut()
    private var hotkeyEnabled = true
    private var targetApp: TargetApp?
    private var latestEnglish = ""
    private var currentStatus = "Ready"

    private let recorder = AudioRecorder()
    private let indicator = VoiceIndicator()
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
    private let shortcutMenu = NSMenu()

    deinit {
        NSLog("Marathi Dictation: AppDelegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        requestNotificationPermission()
        checkPermissions()
        startPolling()
    }

    private func configureStatusItem() {
        NSLog("Marathi Dictation: configuring status item")
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
            button.toolTip = "Marathi Dictation"
        }

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        permissionsMenuItem.target = self
        menu.addItem(permissionsMenuItem)
        menu.addItem(.separator())

        hotkeyMenuItem.target = self
        hotkeyMenuItem.state = .on
        menu.addItem(hotkeyMenuItem)

        let shortcutRoot = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        for preset in AppSettings.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            shortcutMenu.addItem(item)
        }
        shortcutRoot.submenu = shortcutMenu
        menu.addItem(shortcutRoot)

        let copyItem = NSMenuItem(title: "Copy Last English", action: #selector(copyLastEnglish), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

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
        let quitItem = NSMenuItem(title: "Quit Marathi Dictation", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func copyLastEnglish() {
        guard !latestEnglish.isEmpty else {
            setStatus("No English yet")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestEnglish, forType: .string)
        setStatus("Copied last English")
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

        targetApp = PasteHelper.captureFrontmostApp()
        do {
            try recorder.start()
            indicator.showRecording()
            let mode = locked ? "Locked recording" : "Recording"
            setStatus("\(mode) into \(targetApp?.name ?? "unknown target")")
        } catch {
            setStatus("Mic error")
            showNotification(title: "Microphone error", body: error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard let result = recorder.stop() else { return }
        let targetApp = self.targetApp
        indicator.showProcessing()
        setStatus("Translating...")

        Task {
            do {
                let started = Date()
                let sarvamClient = SarvamClient()
                let translation = try await sarvamClient.translate(audioURL: result.url)
                let latency = Date().timeIntervalSince(started)
                try await MainActor.run {
                    self.latestEnglish = translation.transcript
                    guard PermissionManager.pasteEventsGranted else {
                        self.indicator.hide()
                        self.setStatus("Paste permission needed")
                        self.showNotification(title: "Permission needed", body: "Enable Accessibility for Marathi Dictation to paste into other apps.")
                        return
                    }
                    try PasteHelper.paste(translation.transcript, into: targetApp)
                    self.indicator.hide()
                    self.setStatus("Pasted. \(String(format: "%.1f", latency))s")
                }
            } catch {
                await MainActor.run {
                    self.indicator.hide()
                    self.setStatus("Error")
                    self.showNotification(title: "Dictation error", body: error.localizedDescription)
                }
            }
        }
    }

    private func setStatus(_ status: String) {
        currentStatus = status
        statusMenuItem.title = "Status: \(status)"
        updateDebugWindow()
    }

    private func refreshMenu() {
        permissionsMenuItem.title = "Permissions: \(PermissionManager.compactSummary)"
        hotkeyMenuItem.state = hotkeyEnabled ? .on : .off
        for item in shortcutMenu.items {
            item.state = item.title == selectedShortcut.name ? .on : .off
        }
        updateDebugWindow()
    }

    private func createDebugWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Marathi Dictation Debug"
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
        let target = targetApp?.name ?? "(none)"
        debugTextView.string = """
        Status: \(currentStatus)
        Hotkey: \(hotkeyEnabled ? "Enabled" : "Disabled")
        Shortcut: \(selectedShortcut.name)
        Target: \(target)

        Permissions:
        \(PermissionManager.detailedSummary)

        Last English:
        \(latest)
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
