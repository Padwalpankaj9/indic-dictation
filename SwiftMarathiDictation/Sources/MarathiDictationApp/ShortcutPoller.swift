import AppKit
import ApplicationServices
import Carbon

enum ShortcutPoller {
    static func isPressed(_ preset: ShortcutPreset) -> Bool {
        let states = Dictionary(uniqueKeysWithValues: ModifierName.allCases.map { modifier in
            (modifier, isModifierPressed(modifier))
        })
        return preset.modifiers.allSatisfy { states[$0] == true }
    }

    private static func isModifierPressed(_ modifier: ModifierName) -> Bool {
        switch modifier {
        case .command:
            return isKeyDown(kVK_Command) || isKeyDown(kVK_RightCommand)
        case .option:
            return isKeyDown(kVK_Option) || isKeyDown(kVK_RightOption)
        case .shift:
            return isKeyDown(kVK_Shift) || isKeyDown(kVK_RightShift)
        case .control:
            return isKeyDown(kVK_Control) || isKeyDown(kVK_RightControl)
        case .function:
            return isKeyDown(kVK_Function) || CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        }
    }

    private static func isKeyDown(_ keyCode: Int) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }
}

struct TargetApp: @unchecked Sendable {
    let name: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let focusedElement: AXUIElement?

    var hasFocusedElement: Bool {
        focusedElement != nil
    }
}

enum PasteHelper {
    static func captureFrontmostApp(ignoring ignoredBundleIdentifiers: Set<String> = []) -> TargetApp? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        guard !ignoredBundleIdentifiers.contains(bundleID) else {
            return nil
        }
        let focusedElement = captureFocusedTextElement(processIdentifier: app.processIdentifier)
        return TargetApp(
            name: app.localizedName ?? bundleID,
            bundleIdentifier: bundleID,
            processIdentifier: app.processIdentifier,
            focusedElement: focusedElement
        )
    }

    @MainActor
    static func paste(_ text: String, into target: TargetApp?) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        NSLog(
            "Indic Dictation: paste requested into \(target?.name ?? "current app"), focused element: \(target?.hasFocusedElement == true ? "yes" : "no")"
        )
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        activate(target)
        try await Task.sleep(nanoseconds: 450_000_000)
        focusStoredElement(in: target)
        try await Task.sleep(nanoseconds: 150_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        if let target {
            vDown?.postToPid(target.processIdentifier)
            vUp?.postToPid(target.processIdentifier)
        } else {
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    @MainActor
    private static func activate(_ target: TargetApp?) {
        guard let target else { return }

        if let app = NSRunningApplication(processIdentifier: target.processIdentifier)
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).first {
            app.activate(options: [.activateAllWindows])
            return
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func captureFocusedTextElement(processIdentifier: pid_t) -> AXUIElement? {
        guard PermissionManager.accessibilityGranted else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = value as! AXUIElement
        return isTextInputElement(element) ? element : nil
    }

    @MainActor
    private static func focusStoredElement(in target: TargetApp?) {
        guard let element = target?.focusedElement else { return }
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSLog("Indic Dictation: refocus stored element result \(result.rawValue)")
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(element, kAXRoleAttribute as CFString) {
            let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
            if textRoles.contains(role) {
                return true
            }
        }

        var selectedRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        ) == .success {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
