import Foundation

/// Optional second pass: routes the finished Sarvam text through a fast
/// OpenRouter model that fixes grammar, drops filler words, and breaks the
/// text into short paragraphs. Any failure falls back to the raw text, so
/// a dictation can never be lost to this step.
final class PolishClient {
    // Benchmarked June 2026 on this exact task: 2.5-flash-lite 0.84s median,
    // 3.1-flash-lite 1.08s, 3-flash-preview 1.53s. Lite wins on speed and
    // consistency; the prompt pins it to the original wording for fidelity.
    static let model = "google/gemini-2.5-flash-lite"

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let systemPrompt = """
    You polish dictated text. Fix grammar and punctuation, remove filler words \
    and repetitions, and structure the result into short, clear paragraphs. \
    Stay close to the speaker's original wording; do not paraphrase more than \
    needed and never change who says or does what. Preserve the speaker's \
    meaning, tone, and language. Never add new information, never answer \
    questions that appear in the text, never add comments or headings. Do not \
    use em dashes; use periods or commas instead. Output only the polished text.
    """

    /// Texts shorter than this are pasted as-is; one-liners gain nothing
    /// from a polish round trip.
    private static let minimumLength = 40

    /// Returns the polished text, or the original on any failure or timeout.
    func polishOrOriginal(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumLength else { return text }
        do {
            let polished = try await polish(trimmed)
            return polished.isEmpty ? text : polished
        } catch {
            NSLog("Indic Dictation: polish failed, pasting raw text: \(error)")
            return text
        }
    }

    private func polish(_ text: String) async throws -> String {
        let apiKey = try Self.loadAPIKey()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // The user is staring at the screen waiting to paste; better to give
        // up and use the raw text than to hang here.
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PolishRequest(
                model: Self.model,
                messages: [
                    PolishMessage(role: "system", content: Self.systemPrompt),
                    PolishMessage(role: "user", content: text)
                ],
                temperature: 0.2,
                maxTokens: 4096
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PolishClientError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(PolishResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func loadAPIKey() throws -> String {
        // Dedicated key first so dictation has its own budget, then the
        // general OpenRouter key, then secrets.env on disk.
        let names = ["INDIC_DICTATION_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"]
        for name in names {
            if let key = ProcessInfo.processInfo.environment[name], !key.isEmpty {
                return key
            }
        }

        let secretsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shell/secrets.env")
        guard let content = try? String(contentsOf: secretsURL, encoding: .utf8) else {
            throw PolishClientError.missingAPIKey
        }
        for name in names {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("export \(name)=") else { continue }
                let raw = trimmed.replacingOccurrences(of: "export \(name)=", with: "")
                let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !key.isEmpty {
                    return key
                }
            }
        }
        throw PolishClientError.missingAPIKey
    }

    static func hasConfiguredAPIKey() -> Bool {
        (try? loadAPIKey()) != nil
    }
}

enum PolishClientError: Error, LocalizedError {
    case missingAPIKey
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenRouter API key found for polishing."
        case let .httpError(status, body):
            return "OpenRouter HTTP \(status): \(body)"
        }
    }
}

private struct PolishRequest: Encodable {
    let model: String
    let messages: [PolishMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct PolishMessage: Codable {
    let role: String
    let content: String
}

private struct PolishResponse: Decodable {
    let choices: [PolishChoice]
}

private struct PolishChoice: Decodable {
    let message: PolishMessage
}
