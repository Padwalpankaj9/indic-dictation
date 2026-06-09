import Foundation

struct StreamingTranslationResult {
    let text: String
    let chunkCount: Int
}

final class SarvamStreamingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let qualityMode: DictationQualityMode
    let prompt: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var chunks: [String] = []
    private var currentText = ""
    private var isClosed = false
    // How many utterances the server has started (START_SPEECH) but not yet
    // finalized with a data message. Zero means every word already arrived.
    private var pendingUtterances = 0

    var onText: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onTiming: ((String) -> Void)?

    var isUsable: Bool {
        !isClosed && task != nil
    }

    init(qualityMode: DictationQualityMode = .balanced, prompt: String = "") {
        self.qualityMode = qualityMode
        self.prompt = prompt
        super.init()
    }

    func connect() async throws {
        let apiKey = try SarvamClient.loadAPIKey()
        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text/ws")!
        components.queryItems = qualityMode.streamingQueryItems
        guard let url = components.url else {
            throw SarvamClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        self.isClosed = false
        self.chunks = []
        self.currentText = ""
        self.pendingUtterances = 0
        task.resume()
        onTiming?("websocket resumed")
        onTiming?("mode \(qualityMode.name.lowercased())")
        receiveNext()
        sendPromptIfNeeded()
    }

    // Tells the speech model which names and jargon to expect, so it stops
    // guessing wrong on words like "Utkarsha" or "Piramal".
    private func sendPromptIfNeeded() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(StreamingConfigMessage(type: "config", prompt: trimmed))
        onTiming?("vocabulary prompt sent")
    }

    /// Checks that the socket is still alive on the wire, not just locally.
    func ping(completion: @escaping @Sendable (Bool) -> Void) {
        guard !isClosed, let task else {
            completion(false)
            return
        }
        task.sendPing { error in
            completion(error == nil)
        }
    }

    func sendAudio(_ data: Data) {
        guard !isClosed, task != nil else { return }
        let payload = StreamingAudioMessage(
            audio: StreamingAudioData(
                data: data.base64EncodedString(),
                sampleRate: 16_000,
                // Sarvam's message schema expects this literal even when the connection codec is raw PCM.
                encoding: "audio/wav"
            )
        )
        send(payload)
    }

    func finish() async -> StreamingTranslationResult {
        if !isClosed {
            send(StreamingFlushMessage(type: "flush"))
            onTiming?("flush sent")

            let hasText = !cleanedText().isEmpty
            if pendingUtterances <= 0, hasText {
                // Every utterance the server started has already produced its
                // final text, so there is nothing left to wait for.
                onTiming?("flush wait skipped, nothing pending")
            } else {
                let timeoutSeconds = qualityMode.flushTimeoutSeconds
                let waitLimit = hasText ? timeoutSeconds : max(timeoutSeconds, 0.95)
                let deadline = Date().addingTimeInterval(waitLimit)
                while Date() < deadline {
                    // Done once every open utterance has its final text in hand.
                    if pendingUtterances <= 0, !cleanedText().isEmpty {
                        onTiming?("pending speech finalized")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        close()
        return StreamingTranslationResult(text: cleanedText(), chunkCount: chunks.count)
    }

    func close() {
        isClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func send<T: Encodable>(_ payload: T) {
        guard let task, let data = try? JSONEncoder.streaming.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.onEvent?("Streaming send error: \(error.localizedDescription)")
            }
        }
    }

    private func receiveNext() {
        guard !isClosed, let task else { return }
        task.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                self.receiveNext()
            case let .failure(error):
                self.isClosed = true
                self.onEvent?("Streaming receive error: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(text):
            data = text.data(using: .utf8)
        case let .data(rawData):
            data = rawData
        @unknown default:
            data = nil
        }
        guard let data else { return }

        if let response = try? JSONDecoder.streaming.decode(StreamingResponse.self, from: data) {
            if response.type == "events", let signal = response.data?.signalType {
                if signal == "START_SPEECH" {
                    pendingUtterances += 1
                }
                onEvent?(signal)
            }
            if response.type == "data" {
                // Every data message closes one started utterance, even when
                // its transcript comes back empty.
                pendingUtterances = max(0, pendingUtterances - 1)
                if let transcript = response.data?.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                    appendTranscript(transcript)
                    onText?(currentText)
                }
            }
            if response.type == "error" {
                let message = response.data?.error ?? "unknown server error"
                onEvent?("SERVER_ERROR: \(message)")
            }
        } else if let raw = String(data: data, encoding: .utf8) {
            onEvent?(raw)
        }
    }

    private func appendTranscript(_ transcript: String) {
        let compact = transcript
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return }
        chunks.append(compact)
        if currentText.isEmpty {
            currentText = compact
        } else {
            currentText += " " + compact
        }
    }

    private func cleanedText() -> String {
        currentText
    }
}

private struct StreamingAudioMessage: Encodable {
    let audio: StreamingAudioData
}

private struct StreamingAudioData: Encodable {
    let data: String
    let sampleRate: Int
    let encoding: String

    enum CodingKeys: String, CodingKey {
        case data
        case sampleRate = "sample_rate"
        case encoding
    }
}

private struct StreamingFlushMessage: Encodable {
    let type: String
}

private struct StreamingConfigMessage: Encodable {
    let type: String
    let prompt: String
}

private struct StreamingResponse: Decodable {
    let type: String?
    let data: StreamingResponseData?
}

private struct StreamingResponseData: Decodable {
    let transcript: String?
    let signalType: String?
    let error: String?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case transcript
        case signalType = "signal_type"
        case error
        case code
    }
}

private extension JSONEncoder {
    static var streaming: JSONEncoder {
        JSONEncoder()
    }
}

private extension JSONDecoder {
    static var streaming: JSONDecoder {
        JSONDecoder()
    }
}
