import AppKit
import Foundation

enum WakeWordResources {
    static let phrase = "Hey Vaani"
    static let directory = AppPaths.appSupport.appendingPathComponent("WakeWord")
    static let libraryFileName = "libpv_porcupine.dylib"
    static let modelFileName = "porcupine_params.pv"
    static let keywordFileName = "hey_vaani_mac.ppn"
    static let accessKeyFileName = "picovoice_access_key.txt"

    static var libraryURL: URL {
        directory.appendingPathComponent(libraryFileName)
    }

    static var modelURL: URL {
        directory.appendingPathComponent(modelFileName)
    }

    static var keywordURL: URL {
        directory.appendingPathComponent(keywordFileName)
    }

    static var accessKeyURL: URL {
        directory.appendingPathComponent(accessKeyFileName)
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
        if !fileManager.fileExists(atPath: libraryURL.path) {
            missing.append(libraryFileName)
        }
        if !fileManager.fileExists(atPath: modelURL.path) {
            missing.append(modelFileName)
        }
        if !fileManager.fileExists(atPath: keywordURL.path) {
            missing.append(keywordFileName)
        }
        if loadAccessKey() == nil {
            missing.append("PICOVOICE_ACCESS_KEY or \(accessKeyFileName)")
        }
        return WakeWordSetupStatus(directory: directory, missingItems: missing)
    }

    static func loadAccessKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["PICOVOICE_ACCESS_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        guard let raw = try? String(contentsOf: accessKeyURL, encoding: .utf8) else {
            return nil
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
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
            Folder: \(directory.path)
            """
        }

        return """
        Wake phrase: \(WakeWordResources.phrase)
        Setup: Needs files
        Folder: \(directory.path)
        Missing:
        \(missingItems.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
