import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    private var startedAt: Date?

    func start() throws {
        let timestamp = Self.timestamp()
        let url = try AppPaths.dataURL(folder: "samples", fileName: "\(timestamp).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        recorder.record()
        self.recorder = recorder
        self.currentURL = url
        self.startedAt = Date()
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let currentURL else {
            return nil
        }
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        self.startedAt = nil
        return (currentURL, duration)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
