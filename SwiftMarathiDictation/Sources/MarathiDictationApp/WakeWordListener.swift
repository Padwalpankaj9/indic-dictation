@preconcurrency import AVFoundation
import Foundation

enum WakeWordListenerError: Error, LocalizedError {
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            return "Could not read microphone audio for wake-word detection."
        }
    }
}

final class WakeWordListener: @unchecked Sendable {
    typealias ScoreHandler = @MainActor @Sendable (_ confidence: Float, _ streak: Int) -> Void
    typealias WakeHandler = @MainActor @Sendable (_ confidence: Float, _ samples: [Int16]) -> Void

    private let requiredConsecutiveDetections = 2
    private let meter: AudioLevelMeter
    private let processingQueue = DispatchQueue(label: "com.indic-dictation.wake-word-listener")
    private var wakeEngine: WakeWordEngine?
    private var rollingWindow: WakeWordRollingWindow?
    private var audioStreamer: LiveAudioStreamer?
    private var onScore: ScoreHandler?
    private var onWake: WakeHandler?
    private var isProcessingWindow = false
    private var didDetectWake = false
    private var consecutiveDetections = 0
    private var lastScoreEmitAt = Date.distantPast

    init(meter: AudioLevelMeter) {
        self.meter = meter
    }

    var isRunning: Bool {
        audioStreamer != nil
    }

    func start(
        threshold: Float,
        onScore: @escaping ScoreHandler,
        onWake: @escaping WakeHandler
    ) throws {
        stop()

        let engine = LiveKitWakeWordEngine(threshold: threshold)
        try engine.start()

        wakeEngine = engine
        rollingWindow = WakeWordRollingWindow(windowLength: engine.requiredWindowLength)
        self.onScore = onScore
        self.onWake = onWake
        didDetectWake = false
        isProcessingWindow = false
        consecutiveDetections = 0
        lastScoreEmitAt = .distantPast

        let streamer = LiveAudioStreamer(meter: meter) { [weak self] data in
            self?.processAudio(data)
        }
        do {
            try streamer.start()
        } catch {
            stop()
            throw error
        }
        audioStreamer = streamer
    }

    func stop() {
        audioStreamer?.stop()
        audioStreamer = nil

        processingQueue.sync {
            wakeEngine?.stop()
            wakeEngine = nil
            rollingWindow = nil
            onScore = nil
            onWake = nil
            isProcessingWindow = false
            didDetectWake = false
            consecutiveDetections = 0
            lastScoreEmitAt = .distantPast
        }
    }

    private func processAudio(_ data: Data) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            guard !didDetectWake else { return }
            guard let samples = rollingWindow?.append(data) else { return }
            guard !isProcessingWindow else { return }
            guard let wakeEngine else { return }

            isProcessingWindow = true
            let prediction = Result { try wakeEngine.process(samples) }
            isProcessingWindow = false

            switch prediction {
            case let .success(prediction):
                if prediction.isDetected {
                    consecutiveDetections += 1
                } else {
                    consecutiveDetections = 0
                }
                emitScoreIfNeeded(confidence: prediction.confidence)
                guard prediction.isDetected else { return }
                guard consecutiveDetections >= requiredConsecutiveDetections else { return }
                didDetectWake = true
                let handler = onWake
                let triggerSamples = samples
                Task { @MainActor in
                    handler?(prediction.confidence, triggerSamples)
                }
            case .failure:
                consecutiveDetections = 0
                emitScoreIfNeeded(confidence: 0)
            }
        }
    }

    private func emitScoreIfNeeded(confidence: Float) {
        let now = Date()
        guard confidence >= 0.3 || now.timeIntervalSince(lastScoreEmitAt) >= 0.5 else { return }
        lastScoreEmitAt = now
        let handler = onScore
        let streak = consecutiveDetections
        Task { @MainActor in
            handler?(confidence, streak)
        }
    }
}
