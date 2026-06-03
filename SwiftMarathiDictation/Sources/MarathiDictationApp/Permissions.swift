import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PrivacyPane: String {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"
    case microphone = "Privacy_Microphone"
}

enum PermissionManager {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess() || AXIsProcessTrusted()
    }

    static var pasteEventsGranted: Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var compactSummary: String {
        "Mic \(mark(microphoneGranted))  Input \(mark(inputMonitoringGranted))  Paste \(mark(pasteEventsGranted))"
    }

    static var detailedSummary: String {
        [
            "Microphone: \(word(microphoneGranted))",
            "Input Monitoring: \(word(inputMonitoringGranted))",
            "Accessibility: \(word(accessibilityGranted))",
            "Paste Events: \(word(pasteEventsGranted))"
        ].joined(separator: "\n")
    }

    static func requestInitialPrompts(onMicrophoneResolved: @escaping @MainActor () -> Void) {
        requestMicrophone(onResolved: onMicrophoneResolved)

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }

        if !AXIsProcessTrusted() {
            let key = "AXTrustedCheckOptionPrompt"
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    static func requestMicrophone(onResolved: @escaping @MainActor () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    onResolved()
                }
            }
        default:
            Task { @MainActor in
                onResolved()
            }
        }
    }

    static func openSettings(_ pane: PrivacyPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func mark(_ granted: Bool) -> String {
        granted ? "OK" : "Needs setup"
    }

    private static func word(_ granted: Bool) -> String {
        granted ? "Granted" : "Needs setup"
    }
}
