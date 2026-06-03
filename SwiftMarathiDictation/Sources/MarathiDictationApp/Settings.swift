import Foundation

enum ModifierName: String, CaseIterable, Codable {
    case command = "Command"
    case option = "Option"
    case shift = "Shift"
    case control = "Control"
    case function = "Function"
}

struct ShortcutPreset: Codable, Equatable {
    let name: String
    let modifiers: [ModifierName]
}

enum AppSettings {
    private static let livePreviewKey = "livePreviewEnabled"
    private static let selectedMicrophoneUIDKey = "selectedMicrophoneUID"

    static let presets: [ShortcutPreset] = [
        ShortcutPreset(name: "Command + Option", modifiers: [.command, .option]),
        ShortcutPreset(name: "Command + Shift", modifiers: [.command, .shift]),
        ShortcutPreset(name: "Option + Shift", modifiers: [.option, .shift]),
        ShortcutPreset(name: "Command + Control", modifiers: [.command, .control]),
        ShortcutPreset(name: "Control + Option", modifiers: [.control, .option]),
        ShortcutPreset(name: "Function", modifiers: [.function]),
        ShortcutPreset(name: "Function + Option", modifiers: [.function, .option])
    ]

    static let defaultPreset = presets[0]
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/indic-dictation-swift/settings.json")
    private static let legacySettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/marathi-dictation-swift/settings.json")

    static func loadShortcut() -> ShortcutPreset {
        guard
            let data = try? Data(contentsOf: readableSettingsURL),
            let decoded = try? JSONDecoder().decode(ShortcutPreset.self, from: data),
            let preset = presets.first(where: { $0.name == decoded.name })
        else {
            return defaultPreset
        }
        return preset
    }

    static func saveShortcut(_ preset: ShortcutPreset) {
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(preset)
            try data.write(to: settingsURL)
        } catch {
            NSLog("Failed to save shortcut: \(error)")
        }
    }

    static func loadLivePreviewEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: livePreviewKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: livePreviewKey)
    }

    static func saveLivePreviewEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: livePreviewKey)
    }

    static func loadSelectedMicrophoneUID() -> String? {
        guard let uid = UserDefaults.standard.string(forKey: selectedMicrophoneUIDKey),
              !uid.isEmpty else {
            return nil
        }
        return uid
    }

    static func saveSelectedMicrophoneUID(_ uid: String?) {
        guard let uid, !uid.isEmpty else {
            UserDefaults.standard.removeObject(forKey: selectedMicrophoneUIDKey)
            return
        }
        UserDefaults.standard.set(uid, forKey: selectedMicrophoneUIDKey)
    }

    private static var readableSettingsURL: URL {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            return settingsURL
        }
        if FileManager.default.fileExists(atPath: legacySettingsURL.path) {
            return legacySettingsURL
        }
        return settingsURL
    }
}

enum AppPaths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Indic Dictation")

    static func dataURL(folder: String, fileName: String) throws -> URL {
        let folderURL = appSupport.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent(fileName)
    }
}
