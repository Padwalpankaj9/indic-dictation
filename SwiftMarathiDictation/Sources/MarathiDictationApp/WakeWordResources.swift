import AppKit
import Foundation

enum WakeWordResources {
    static let phrase = "Hey Vaani"
    static let directory = AppPaths.appSupport.appendingPathComponent("WakeWord")
    static let classifierFileName = "hey_vaani.onnx"

    static var classifierURL: URL {
        directory.appendingPathComponent(classifierFileName)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func openDirectory() throws {
        try ensureDirectory()
        NSWorkspace.shared.open(directory)
    }

    static func setupStatus() -> WakeWordSetupStatus {
        let fileManager = FileManager.default
        var missing: [String] = []
        if !fileManager.fileExists(atPath: classifierURL.path) {
            missing.append(classifierFileName)
        }
        return WakeWordSetupStatus(directory: directory, missingItems: missing)
    }
}

struct WakeWordSetupStatus {
    let directory: URL
    let missingItems: [String]

    var isReady: Bool {
        missingItems.isEmpty
    }

    var shortSummary: String {
        isReady ? "Wake word ready" : "Wake word setup needed"
    }

    var detailedSummary: String {
        if isReady {
            return """
            Wake phrase: \(WakeWordResources.phrase)
            Setup: Ready
            Engine: LiveKit WakeWord
            Folder: \(directory.path)
            """
        }

        return """
        Wake phrase: \(WakeWordResources.phrase)
        Engine: LiveKit WakeWord
        Setup: Needs classifier model
        Folder: \(directory.path)
        Missing:
        \(missingItems.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
