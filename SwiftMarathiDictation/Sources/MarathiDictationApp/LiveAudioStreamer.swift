@preconcurrency import AVFoundation
import Accelerate
import Foundation
import os

/// Thread-safe holder for the current mic loudness (0...1).
/// The audio thread writes it, the UI reads it once per frame. No locks held long.
final class AudioLevelMeter: Sendable {
    private let storage = OSAllocatedUnfairLock<Float>(initialState: 0)

    func set(_ value: Float) {
        storage.withLock { $0 = value }
    }

    var value: Float {
        storage.withLock { $0 }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }
}

final class LiveAudioStreamer {
    private let engine = AVAudioEngine()
    private let onAudio: @Sendable (Data) -> Void
    private let meter: AudioLevelMeter
    // Smoothed loudness, only ever touched on the audio thread.
    private var levelEnv: Float = 0

    init(meter: AudioLevelMeter, onAudio: @escaping @Sendable (Data) -> Void) {
        self.meter = meter
        self.onAudio = onAudio
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioStreamerError.invalidFormat
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Cheap loudness read first so the meter stays in lockstep with the audio.
            self.emitLevel(buffer)
            guard let data = self.convert(buffer) else { return }
            self.onAudio(data)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelEnv = 0
        meter.reset()
    }

    /// Computes RMS loudness with Accelerate (microseconds) and stores a smoothed,
    /// perceptual value. Runs on the audio thread, so it must stay tiny.
    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, frames)

        // Map raw RMS into a lively 0...1 range, then ease toward it.
        let mapped = min(1, powf(rms * 14, 0.7))
        // Fast attack so speech pops, slower release so it settles smoothly.
        let k: Float = mapped > levelEnv ? 0.5 : 0.18
        levelEnv += (mapped - levelEnv) * k
        meter.set(levelEnv)
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = inputBuffer.floatChannelData else {
            return nil
        }

        let inputFrames = Int(inputBuffer.frameLength)
        guard inputFrames > 0 else { return nil }

        let inputSampleRate = inputBuffer.format.sampleRate
        let channels = Int(inputBuffer.format.channelCount)
        let outputFrames = max(1, Int(Double(inputFrames) * 16_000 / inputSampleRate))
        var samples = [Int16]()
        samples.reserveCapacity(outputFrames)

        for outputIndex in 0..<outputFrames {
            let inputIndex = min(inputFrames - 1, Int(Double(outputIndex) * inputSampleRate / 16_000))
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += channelData[channel][inputIndex]
            }
            mixed /= Float(channels)
            let clamped = max(-1, min(1, mixed))
            samples.append(Int16(clamped * Float(Int16.max)))
        }

        return samples.withUnsafeBytes { Data($0) }
    }
}

enum AudioStreamerError: Error, LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "Could not create the 16 kHz microphone format."
    }
}
