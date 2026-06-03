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

enum DictationQualityMode: String, CaseIterable, Codable, Equatable {
    case fast
    case balanced
    case accurate

    var name: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .accurate:
            return "Accurate"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "lowest latency"
        case .balanced:
            return "recommended"
        case .accurate:
            return "more context"
        }
    }

    var flushTimeoutSeconds: TimeInterval {
        switch self {
        case .fast:
            return 0.35
        case .balanced:
            return 0.95
        case .accurate:
            return 1.45
        }
    }

    var streamingQueryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "language-code", value: "mr-IN"),
            URLQueryItem(name: "model", value: "saaras:v3"),
            URLQueryItem(name: "mode", value: "translate"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "input_audio_codec", value: "pcm_s16le"),
            URLQueryItem(name: "vad_signals", value: "true"),
            URLQueryItem(name: "flush_signal", value: "true")
        ]

        switch self {
        case .fast:
            items.append(contentsOf: [
                URLQueryItem(name: "high_vad_sensitivity", value: "true"),
                URLQueryItem(name: "min_speech_frames", value: "1"),
                URLQueryItem(name: "first_turn_min_speech_frames", value: "1"),
                URLQueryItem(name: "negative_frames_count", value: "2"),
                URLQueryItem(name: "negative_frames_window", value: "3"),
                URLQueryItem(name: "pre_speech_pad_frames", value: "2"),
                URLQueryItem(name: "num_initial_ignored_frames", value: "0")
            ])
        case .balanced:
            items.append(URLQueryItem(name: "high_vad_sensitivity", value: "true"))
        case .accurate:
            items.append(URLQueryItem(name: "high_vad_sensitivity", value: "false"))
        }

        return items
    }
}

enum AppSettings {
    private static let livePreviewKey = "livePreviewEnabled"
    private static let selectedMicrophoneUIDKey = "selectedMicrophoneUID"
    private static let dictationQualityModeKey = "dictationQualityMode"

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

    static func loadDictationQualityMode() -> DictationQualityMode {
        guard let rawValue = UserDefaults.standard.string(forKey: dictationQualityModeKey),
              let mode = DictationQualityMode(rawValue: rawValue) else {
            return .accurate
        }
        return mode
    }

    static func saveDictationQualityMode(_ mode: DictationQualityMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: dictationQualityModeKey)
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
