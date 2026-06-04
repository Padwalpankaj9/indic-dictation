import AppKit
import Foundation

enum WakeWordResources {
    static let phrase = "Hey Vaani"
    static let directory = AppPaths.appSupport.appendingPathComponent("WakeWord")
    static let classifierFileName = "hey_vaani.onnx"

    static var classifierURL: URL {
        directory.appendingPathComponent(classifierFileName)
    }

    static var bundledClassifierURL: URL? {
        Bundle.module.url(
            forResource: "hey_vaani",
            withExtension: "onnx",
            subdirectory: "WakeWord"
        )
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func installBundledClassifierIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: classifierURL.path) else { return }
        guard let bundledClassifierURL else { return }

        try ensureDirectory()
        try fileManager.copyItem(at: bundledClassifierURL, to: classifierURL)
    }

    static func openDirectory() throws {
        try ensureDirectory()
        NSWorkspace.shared.open(directory)
    }

    static func setupStatus() -> WakeWordSetupStatus {
        try? installBundledClassifierIfNeeded()

        let fileManager = FileManager.default
        var missing: [String] = []
        if !fileManager.fileExists(atPath: classifierURL.path) {
            missing.append(classifierFileName)
        }
        return WakeWordSetupStatus(directory: directory, missingItems: missing)
    }
}

enum WakeWordSampleKind {
    case wake
    case negative

    var prompt: String {
        switch self {
        case .wake:
            return "Say \"Hey Vaani\""
        case .negative:
            return "Say anything except \"Hey Vaani\""
        }
    }
}

enum WakeWordSampleSplit: String, CaseIterable {
    case positiveTrain = "positive_train"
    case positiveTest = "positive_test"
    case negativeTrain = "negative_train"
    case negativeTest = "negative_test"
}

struct WakeWordSampleCounts {
    let positiveTrain: Int
    let positiveTest: Int
    let negativeTrain: Int
    let negativeTest: Int

    var positiveTotal: Int {
        positiveTrain + positiveTest
    }

    var negativeTotal: Int {
        negativeTrain + negativeTest
    }

    var menuSummary: String {
        "Wake \(positiveTotal)  Other \(negativeTotal)"
    }

    var debugSummary: String {
        """
        Wake samples: \(positiveTotal) (\(positiveTrain) train, \(positiveTest) test)
        Other samples: \(negativeTotal) (\(negativeTrain) train, \(negativeTest) test)
        """
    }
}

enum WakeWordTrainingResources {
    static let modelName = "hey_vaani"
    static let trainingRoot = AppPaths.appSupport.appendingPathComponent("WakeWordTraining")
    static let dataDir = trainingRoot.appendingPathComponent("data")
    static let outputDir = trainingRoot.appendingPathComponent("output")
    static let modelOutputDir = outputDir.appendingPathComponent(modelName)

    static func openDirectory() throws {
        try ensureDirectories()
        NSWorkspace.shared.open(modelOutputDir)
    }

    static func ensureDirectories() throws {
        for split in WakeWordSampleSplit.allCases {
            try FileManager.default.createDirectory(
                at: directory(for: split),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try WakeWordResources.ensureDirectory()
    }

    static func nextSampleURL(for kind: WakeWordSampleKind) throws -> (split: WakeWordSampleSplit, url: URL) {
        try ensureDirectories()
        let split = nextSplit(for: kind)
        let index = originalClipCount(in: directory(for: split))
        let fileName = String(format: "clip_%06d.wav", index)
        return (split, directory(for: split).appendingPathComponent(fileName))
    }

    static func saveSamples(_ samples: [Int16], kind: WakeWordSampleKind) throws -> URL {
        let sample = try nextSampleURL(for: kind)
        let wavData = makeWAVData(samples: samples, sampleRate: 16_000)
        try wavData.write(to: sample.url, options: .atomic)
        return sample.url
    }

    static func sampleCounts() -> WakeWordSampleCounts {
        WakeWordSampleCounts(
            positiveTrain: originalClipCount(in: directory(for: .positiveTrain)),
            positiveTest: originalClipCount(in: directory(for: .positiveTest)),
            negativeTrain: originalClipCount(in: directory(for: .negativeTrain)),
            negativeTest: originalClipCount(in: directory(for: .negativeTest))
        )
    }

    static func directory(for split: WakeWordSampleSplit) -> URL {
        modelOutputDir.appendingPathComponent(split.rawValue)
    }

    private static func nextSplit(for kind: WakeWordSampleKind) -> WakeWordSampleSplit {
        let counts = sampleCounts()
        switch kind {
        case .wake:
            return counts.positiveTotal % 5 == 4 ? .positiveTest : .positiveTrain
        case .negative:
            return counts.negativeTotal % 5 == 4 ? .negativeTest : .negativeTrain
        }
    }

    private static func originalClipCount(in directory: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        return files.filter { url in
            url.pathExtension == "wav"
                && url.deletingPathExtension().lastPathComponent.range(
                    of: #"^clip_\d{6}$"#,
                    options: .regularExpression
                ) != nil
        }.count
    }

    private static func makeWAVData(samples: [Int16], sampleRate: UInt32) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channelCount * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * Int(bytesPerSample))

        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32(36 + dataSize, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(channelCount, to: &data)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(byteRate, to: &data)
        appendUInt16(blockAlign, to: &data)
        appendUInt16(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(dataSize, to: &data)

        let littleEndianSamples = samples.map { $0.littleEndian }
        littleEndianSamples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
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
