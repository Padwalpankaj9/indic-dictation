import AVFoundation
import Foundation

struct SarvamTranslation: Codable {
    let transcript: String
    let chunkCount: Int?

    enum CodingKeys: String, CodingKey {
        case transcript
        case chunkCount = "chunk_count"
    }
}

enum SarvamClientError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "SARVAM_API_KEY is not available."
        case .invalidResponse:
            return "Sarvam returned an invalid response."
        case let .httpError(status, body):
            return "Sarvam HTTP \(status): \(body)"
        }
    }
}

final class SarvamClient {
    private let endpoint = URL(string: "https://api.sarvam.ai/speech-to-text")!
    private let maxChunkSeconds: TimeInterval = 25

    func translate(audioURL: URL) async throws -> SarvamTranslation {
        let duration = try audioDuration(audioURL)
        if duration <= maxChunkSeconds {
            return try await translateShortAudio(audioURL)
        }

        let chunks = try splitWAV(audioURL: audioURL, chunkSeconds: maxChunkSeconds)
        var transcripts: [String] = []
        for chunk in chunks {
            let result = try await translateShortAudio(chunk)
            if !result.transcript.isEmpty {
                transcripts.append(result.transcript)
            }
        }
        return SarvamTranslation(transcript: transcripts.joined(separator: " "), chunkCount: chunks.count)
    }

    private func translateShortAudio(_ audioURL: URL) async throws -> SarvamTranslation {
        let apiKey = try loadAPIKey()
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(audioURL: audioURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SarvamClientError.invalidResponse
        }
        guard http.statusCode >= 200 && http.statusCode < 300 else {
            throw SarvamClientError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(SarvamTranslation.self, from: data)
    }

    private func multipartBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        appendField("model", "saaras:v3", boundary: boundary, to: &body)
        appendField("mode", "translate", boundary: boundary, to: &body)
        appendField("language_code", "mr-IN", boundary: boundary, to: &body)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func appendField(_ name: String, _ value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func loadAPIKey() throws -> String {
        if let key = ProcessInfo.processInfo.environment["SARVAM_API_KEY"], !key.isEmpty {
            return key
        }

        let secretsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shell/secrets.env")
        guard let content = try? String(contentsOf: secretsURL, encoding: .utf8) else {
            throw SarvamClientError.missingAPIKey
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export SARVAM_API_KEY=") else { continue }
            let raw = trimmed.replacingOccurrences(of: "export SARVAM_API_KEY=", with: "")
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        throw SarvamClientError.missingAPIKey
    }

    private func audioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return TimeInterval(file.length) / file.processingFormat.sampleRate
    }

    private func splitWAV(audioURL: URL, chunkSeconds: TimeInterval) throws -> [URL] {
        let sourceFile = try AVAudioFile(forReading: audioURL)
        let format = sourceFile.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)
        var outputURLs: [URL] = []
        var part = 1

        while sourceFile.framePosition < sourceFile.length {
            let remaining = AVAudioFrameCount(sourceFile.length - sourceFile.framePosition)
            let framesToRead = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                break
            }
            try sourceFile.read(into: buffer, frameCount: framesToRead)
            let chunkURL = try AppPaths.dataURL(
                folder: "chunks",
                fileName: "\(audioURL.deletingPathExtension().lastPathComponent)-part\(String(format: "%02d", part)).wav"
            )
            let outputFile = try AVAudioFile(forWriting: chunkURL, settings: sourceFile.fileFormat.settings)
            try outputFile.write(from: buffer)
            outputURLs.append(chunkURL)
            part += 1
        }
        return outputURLs
    }
}
