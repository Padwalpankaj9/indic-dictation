import AppKit
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

struct TargetApp {
    let name: String
    let bundleIdentifier: String
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
        return TargetApp(name: app.localizedName ?? bundleID, bundleIdentifier: bundleID)
    }

    @MainActor
    static func paste(_ text: String, into target: TargetApp?) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        NSLog("Indic Dictation: paste requested into \(target?.name ?? "current app")")
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        activate(target)
        try await Task.sleep(nanoseconds: 350_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        try await Task.sleep(nanoseconds: 800_000_000)
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    @MainActor
    private static func activate(_ target: TargetApp?) {
        guard let target else { return }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).first {
            app.activate(options: [.activateAllWindows])
            return
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
