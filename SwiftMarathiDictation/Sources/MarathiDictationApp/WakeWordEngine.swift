import Foundation
import LiveKitWakeWord

struct WakeWordPrediction: Equatable {
    let phrase: String
    let confidence: Float
    let isDetected: Bool
}

enum WakeWordEngineError: Error, LocalizedError {
    case setupIncomplete(String)
    case invalidFrameLength(expected: Int, actual: Int)
    case engineNotStarted

    var errorDescription: String? {
        switch self {
        case let .setupIncomplete(message):
            return message
        case let .invalidFrameLength(expected, actual):
            return "Wake-word audio window mismatch. Expected \(expected), got \(actual)."
        case .engineNotStarted:
            return "Wake-word engine is not started."
        }
    }
}

protocol WakeWordEngine: AnyObject {
    var phrase: String { get }
    var requiredSampleRate: Int { get }
    var requiredWindowLength: Int { get }

    func start() throws
    func process(_ samples: [Int16]) throws -> WakeWordPrediction
    func stop()
}

/// Open-source wake-word backend using LiveKit WakeWord and ONNX Runtime.
///
/// The app owns microphone capture. This class only receives 16 kHz mono PCM
/// windows, which keeps it compatible with the existing low-latency audio path.
final class LiveKitWakeWordEngine: WakeWordEngine {
    let phrase = WakeWordResources.phrase
    let requiredSampleRate = 16_000
    let requiredWindowLength = 32_000

    private let threshold: Float
    private var model: WakeWordModel?

    init(threshold: Float = 0.35) {
        self.threshold = threshold
    }

    func start() throws {
        guard model == nil else { return }

        let status = WakeWordResources.setupStatus()
        guard status.isReady else {
            throw WakeWordEngineError.setupIncomplete(status.detailedSummary)
        }

        model = try WakeWordModel(
            models: [WakeWordResources.classifierURL],
            sampleRate: UInt32(requiredSampleRate),
            executionProvider: .coreML
        )
    }

    func process(_ samples: [Int16]) throws -> WakeWordPrediction {
        guard let model else {
            throw WakeWordEngineError.engineNotStarted
        }
        guard samples.count == requiredWindowLength else {
            throw WakeWordEngineError.invalidFrameLength(expected: requiredWindowLength, actual: samples.count)
        }

        let scores = try model.predict(samples)
        let modelName = WakeWordResources.classifierURL.deletingPathExtension().lastPathComponent
        let confidence = scores[modelName] ?? scores.values.max() ?? 0
        return WakeWordPrediction(
            phrase: phrase,
            confidence: confidence,
            isDetected: confidence >= threshold
        )
    }

    func stop() {
        model = nil
    }
}

final class WakeWordRollingWindow {
    private let windowLength: Int
    private var samples: [Int16] = []

    init(windowLength: Int) {
        self.windowLength = windowLength
        samples.reserveCapacity(windowLength)
    }

    func append(_ data: Data) -> [Int16]? {
        let newSamples = data.withUnsafeBytes { rawBuffer -> [Int16] in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count / MemoryLayout<Int16>.size))
        }
        samples.append(contentsOf: newSamples)
        if samples.count > windowLength {
            samples.removeFirst(samples.count - windowLength)
        }
        return samples.count == windowLength ? samples : nil
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
