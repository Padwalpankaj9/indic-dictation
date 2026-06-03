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
        .appendingPathComponent(".config/marathi-dictation-swift/settings.json")

    static func loadShortcut() -> ShortcutPreset {
        guard
            let data = try? Data(contentsOf: settingsURL),
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
}

enum AppPaths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marathi Dictation")

    static func dataURL(folder: String, fileName: String) throws -> URL {
        let folderURL = appSupport.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent(fileName)
    }
}
