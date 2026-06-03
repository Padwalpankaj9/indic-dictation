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

    func start(onWake: @escaping @MainActor @Sendable () -> Void) async throws {
        stop()

        guard await Self.requestSpeechPermission() else {
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
        audioEngine = engine
        recognitionRequest = request

        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            Task { @MainActor in
                guard let self else { return }
                if let transcript {
                    self.handle(transcript: transcript, onWake: onWake)
                }
                if error != nil {
                    self.stop()
                }
            }
        }
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: resultHandler)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let task = recognitionTask
        let request = recognitionRequest
        let engine = audioEngine

        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        didWake = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
    }

    private func handle(transcript: String, onWake: @escaping @MainActor @Sendable () -> Void) {
        guard !didWake else { return }
        let normalized = Self.normalize(transcript)
        guard phrases.contains(where: { normalized.contains($0) }) else { return }

        didWake = true
        stop()
        onWake()
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            let handler: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { status in
                continuation.resume(returning: status == .authorized)
            }
            SFSpeechRecognizer.requestAuthorization(handler)
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
