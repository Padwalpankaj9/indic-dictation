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
    static func captureFrontmostApp() -> TargetApp? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        return TargetApp(name: app.localizedName ?? bundleID, bundleIdentifier: bundleID)
    }

    static func paste(_ text: String, into target: TargetApp?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let target, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)

            if let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }
}
