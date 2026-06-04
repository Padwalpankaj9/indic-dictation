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
    typealias WakeHandler = @MainActor @Sendable (_ confidence: Float) -> Void

    private let requiredConsecutiveDetections = 2
    private let meter: AudioLevelMeter
    private let processingQueue = DispatchQueue(label: "com.indic-dictation.wake-word-listener")
    private var wakeEngine: WakeWordEngine?
    private var rollingWindow: WakeWordRollingWindow?
    private var audioStreamer: LiveAudioStreamer?
    private var onWake: WakeHandler?
    private var isProcessingWindow = false
    private var didDetectWake = false
    private var consecutiveDetections = 0

    init(meter: AudioLevelMeter) {
        self.meter = meter
    }

    var isRunning: Bool {
        audioStreamer != nil
    }

    func start(onWake: @escaping WakeHandler) throws {
        stop()

        let engine = LiveKitWakeWordEngine()
        try engine.start()

        wakeEngine = engine
        rollingWindow = WakeWordRollingWindow(windowLength: engine.requiredWindowLength)
        self.onWake = onWake
        didDetectWake = false
        isProcessingWindow = false
        consecutiveDetections = 0

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
            onWake = nil
            isProcessingWindow = false
            didDetectWake = false
            consecutiveDetections = 0
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
            let detection = Result { try wakeEngine.process(samples) }
            isProcessingWindow = false

            switch detection {
            case let .success(.detected(_, confidence)):
                consecutiveDetections += 1
                guard consecutiveDetections >= requiredConsecutiveDetections else { return }
                didDetectWake = true
                let handler = onWake
                Task { @MainActor in
                    handler?(confidence)
                }
            case .success(.none):
                consecutiveDetections = 0
            case .failure:
                consecutiveDetections = 0
            }
        }
    }
}
