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
    // Swappable consumer so a running mic session can be handed from
    // wake-word listening straight to dictation without restarting audio.
    private let sink: OSAllocatedUnfairLock<@Sendable (Data) -> Void>
    private let meter: AudioLevelMeter
    // Smoothed loudness, only ever touched on the audio thread.
    private var levelEnv: Float = 0
    // Proper resampler with anti-aliasing, replacing the old sample-picking
    // loop that distorted the audio Sarvam heard. Only used on the audio thread.
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    init(meter: AudioLevelMeter, onAudio: @escaping @Sendable (Data) -> Void) {
        self.meter = meter
        self.sink = OSAllocatedUnfairLock(initialState: onAudio)
    }

    /// Atomically reroutes the converted audio to a new consumer. Used on
    /// wake-word trigger to flip the live mic from detection to dictation
    /// instantly, with no engine restart and no lost syllables.
    func setSink(_ newSink: @escaping @Sendable (Data) -> Void) {
        sink.withLock { $0 = newSink }
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioStreamerError.invalidFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioStreamerError.invalidFormat
        }
        converter.sampleRateConverterQuality = .max
        self.converter = converter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Cheap loudness read first so the meter stays in lockstep with the audio.
            self.emitLevel(buffer)
            guard let data = self.convert(buffer) else { return }
            let deliver = self.sink.withLock { $0 }
            deliver(data)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
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
        // Instant attack so each syllable pops, quick release so the wave
        // calms the moment speech stops. Release also feeds hands-free
        // silence detection, which only gets sharper with a faster settle.
        let k: Float = mapped > levelEnv ? 0.95 : 0.30
        levelEnv += (mapped - levelEnv) * k
        meter.set(levelEnv)
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, inputBuffer.frameLength > 0 else { return nil }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        // Feed this one buffer, then report "no more for now" so the converter
        // keeps its resampling state alive for the next mic callback.
        // The input block runs synchronously inside convert(), so this flag
        // never actually crosses threads.
        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else { return nil }
        let frames = Int(outputBuffer.frameLength)
        guard frames > 0, let samples = outputBuffer.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: frames * MemoryLayout<Int16>.size)
    }
}

enum AudioStreamerError: Error, LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "Could not create the 16 kHz microphone format."
    }
}
