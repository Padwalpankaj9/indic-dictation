import AVFoundation
import Foundation

enum WakeWordSampleRecorderError: Error, LocalizedError {
    case alreadyRecording
    case missingOutputURL

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A wake-word sample is already being recorded."
        case .missingOutputURL:
            return "The wake-word sample output file was not available."
        }
    }
}

@MainActor
final class WakeWordSampleRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var completion: ((Result<URL, Error>) -> Void)?

    var isRecording: Bool {
        recorder != nil
    }

    func record(
        kind: WakeWordSampleKind,
        duration: TimeInterval = 2.0,
        completion: @escaping (Result<URL, Error>) -> Void
    ) throws -> WakeWordSampleSplit {
        guard recorder == nil else {
            throw WakeWordSampleRecorderError.alreadyRecording
        }

        let sample = try WakeWordTrainingResources.nextSampleURL(for: kind)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: sample.url, settings: settings)
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        self.currentURL = sample.url
        self.completion = completion

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finishRecording(success: true)
        }

        return sample.split
    }

    func cancel() {
        finishRecording(success: false)
    }

    private func finishRecording(success: Bool) {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil

        guard let currentURL else {
            completion?(.failure(WakeWordSampleRecorderError.missingOutputURL))
            completion = nil
            return
        }

        self.currentURL = nil
        let completion = self.completion
        self.completion = nil

        if success {
            completion?(.success(currentURL))
        } else {
            try? FileManager.default.removeItem(at: currentURL)
            completion?(.failure(WakeWordSampleRecorderError.missingOutputURL))
        }
    }
}
