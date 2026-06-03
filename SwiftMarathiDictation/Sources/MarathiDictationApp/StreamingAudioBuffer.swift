import Foundation

final class StreamingAudioBuffer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pankajpadwal.MarathiDictation.StreamingAudioBuffer")
    private var pending: [Data] = []
    private var client: SarvamStreamingClient?
    private var pendingBytes = 0
    private let maxPendingBytes = 16_000 * 2 * 8

    var onFirstChunk: (() -> Void)?
    var onFirstSend: (() -> Void)?

    private var didReceiveFirstChunk = false
    private var didSendFirstChunk = false

    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.didReceiveFirstChunk {
                self.didReceiveFirstChunk = true
                self.onFirstChunk?()
            }

            if let client = self.client, client.isUsable {
                self.markFirstSendIfNeeded()
                client.sendAudio(data)
                return
            }

            self.pending.append(data)
            self.pendingBytes += data.count
            self.trimPendingAudio()
        }
    }

    func attach(_ client: SarvamStreamingClient) {
        queue.async { [weak self] in
            guard let self else { return }
            self.client = client
            for chunk in self.pending {
                self.markFirstSendIfNeeded()
                client.sendAudio(chunk)
            }
            self.pending.removeAll()
            self.pendingBytes = 0
        }
    }

    func clear() {
        queue.async { [weak self] in
            self?.pending.removeAll()
            self?.pendingBytes = 0
            self?.client = nil
            self?.didReceiveFirstChunk = false
            self?.didSendFirstChunk = false
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func trimPendingAudio() {
        while pendingBytes > maxPendingBytes, !pending.isEmpty {
            pendingBytes -= pending.removeFirst().count
        }
    }

    private func markFirstSendIfNeeded() {
        if !didSendFirstChunk {
            didSendFirstChunk = true
            onFirstSend?()
        }
    }
}
