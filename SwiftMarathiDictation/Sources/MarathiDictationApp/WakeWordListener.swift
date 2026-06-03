@preconcurrency import AVFoundation
import Foundation
import Speech

enum WakeWordListenerError: Error, LocalizedError {
    case speechPermissionDenied
    case recognizerUnavailable
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech recognition permission is needed for hands-free mode."
        case .recognizerUnavailable:
            return "Speech recognition is not available right now."
        case .invalidAudioFormat:
            return "Could not read microphone audio for wake phrase detection."
        }
    }
}

@MainActor
final class WakeWordListener {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let phrases: [String]
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var didWake = false

    init(phrases: [String] = ["hey indic"]) {
        self.phrases = phrases.map(Self.normalize)
    }

    var isRunning: Bool {
        audioEngine?.isRunning == true
    }

    func start(onWake: @escaping @MainActor () -> Void) async throws {
        stop()

        guard await requestSpeechPermission() else {
            throw WakeWordListenerError.speechPermissionDenied
        }
        guard let recognizer, recognizer.isAvailable else {
            throw WakeWordListenerError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw WakeWordListenerError.invalidAudioFormat
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search

        didWake = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handle(transcript: result.bestTranscription.formattedString, onWake: onWake)
            }
            if error != nil {
                self.stop()
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine = engine
        recognitionRequest = request
        engine.prepare()
        try engine.start()
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        didWake = false
    }

    private func handle(transcript: String, onWake: @escaping @MainActor () -> Void) {
        guard !didWake else { return }
        let normalized = Self.normalize(transcript)
        guard phrases.contains(where: { normalized.contains($0) }) else { return }

        didWake = true
        stop()
        Task { @MainActor in
            onWake()
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
