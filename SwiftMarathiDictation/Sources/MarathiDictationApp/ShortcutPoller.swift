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

struct FocusedTargetInfo {
    let appName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let role: String?
    let subrole: String?
    let title: String?

    var summary: String {
        [
            "App: \(appName)",
            "Bundle: \(bundleIdentifier ?? "(unknown)")",
            "PID: \(processIdentifier.map(String.init) ?? "(unknown)")",
            "Role: \(role ?? "(unknown)")",
            "Subrole: \(subrole ?? "(none)")",
            "Title: \(title ?? "(none)")",
            "Likely editable: \(likelyEditable ? "yes" : "unknown")"
        ].joined(separator: "\n")
    }

    var likelyEditable: Bool {
        guard let role else { return false }
        return role.localizedCaseInsensitiveContains("text")
            || role.localizedCaseInsensitiveContains("field")
            || role.localizedCaseInsensitiveContains("area")
    }
}

struct PasteResult {
    let target: TargetApp?
    let focusedTarget: FocusedTargetInfo?
    let textLength: Int
    let method: String
    let usedClipboard: Bool

    var summary: String {
        [
            "Method: \(method)",
            "Target: \(target?.name ?? "(frontmost)")",
            "Focused app: \(focusedTarget?.appName ?? "(unknown)")",
            "Focused role: \(focusedTarget?.role ?? "(unknown)")",
            "Text length: \(textLength)",
            "Clipboard used: \(usedClipboard ? "yes" : "no")"
        ].joined(separator: "\n")
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

    static func focusedTargetInfo() -> FocusedTargetInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        var processIdentifier: pid_t?
        var role: String?
        var subrole: String?
        var title: String?

        if focusedError == .success, let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success {
                processIdentifier = pid
            }
            role = stringAttribute(kAXRoleAttribute, from: element)
            subrole = stringAttribute(kAXSubroleAttribute, from: element)
            title = stringAttribute(kAXTitleAttribute, from: element)
        }

        return FocusedTargetInfo(
            appName: app.localizedName ?? app.bundleIdentifier ?? "(unknown)",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: processIdentifier ?? app.processIdentifier,
            role: role,
            subrole: subrole,
            title: title
        )
    }

    @discardableResult
    static func paste(_ text: String, into target: TargetApp?) throws -> PasteResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PasteResult(
                target: target,
                focusedTarget: focusedTargetInfo(),
                textLength: 0,
                method: "skipped empty text",
                usedClipboard: false
            )
        }

        activate(target)
        focusStoredElement(in: target)

        if let element = target?.focusedElement ?? captureFrontmostApp()?.focusedElement,
           insertByAccessibility(text, into: element) {
            return PasteResult(
                target: target,
                focusedTarget: focusedTargetInfo(),
                textLength: text.count,
                method: "accessibility text insert",
                usedClipboard: false
            )
        }

        return pasteViaClipboard(text, into: target)
    }

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

    private static func focusStoredElement(in target: TargetApp?) {
        guard let element = target?.focusedElement else { return }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func insertByAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        if isSettable(kAXSelectedTextAttribute, on: element),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return true
        }

        guard isSettable(kAXValueAttribute, on: element),
              let currentValue = stringAttribute(kAXValueAttribute, from: element) else {
            return false
        }

        let currentNSString = currentValue as NSString
        let selectedRange = selectedTextRange(from: element) ?? CFRange(location: currentNSString.length, length: 0)
        guard selectedRange.location >= 0, selectedRange.location <= currentNSString.length else {
            return false
        }

        let safeLength = min(max(selectedRange.length, 0), currentNSString.length - selectedRange.location)
        let mutable = NSMutableString(string: currentValue)
        mutable.replaceCharacters(in: NSRange(location: selectedRange.location, length: safeLength), with: text)

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable.copy() as! CFString) == .success else {
            return false
        }

        let insertedLength = (text as NSString).length
        var newRange = CFRange(location: selectedRange.location + insertedLength, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }
        return true
    }

    private static func pasteViaClipboard(_ text: String, into target: TargetApp?) -> PasteResult {
        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in ignoredClipboardTypes {
            item.setData(Data(), forType: type)
        }
        pasteboard.writeObjects([item])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            activate(target)
            focusStoredElement(in: target)
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                previous.restore(to: .general)
            }
        }

        return PasteResult(
            target: target,
            focusedTarget: focusedTargetInfo(),
            textLength: text.count,
            method: "clipboard fallback + restore",
            usedClipboard: true
        )
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        guard let valueRef, CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = valueRef as! AXValue
        guard AXValueGetType(value) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(kAXRoleAttribute, from: element) {
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

    private static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static let ignoredClipboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]
}

private struct PasteboardSnapshot: @unchecked Sendable {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let copiedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    copy.setString(string, forType: type)
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: copiedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
