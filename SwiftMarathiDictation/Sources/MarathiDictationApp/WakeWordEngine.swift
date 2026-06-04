import Darwin
import Foundation

enum WakeWordDetection: Equatable {
    case none
    case detected(phrase: String)
}

enum WakeWordEngineError: Error, LocalizedError {
    case setupIncomplete(String)
    case libraryOpenFailed(String)
    case symbolMissing(String)
    case initFailed(String)
    case processFailed(String)
    case invalidFrameLength(expected: Int, actual: Int)
    case engineNotStarted

    var errorDescription: String? {
        switch self {
        case let .setupIncomplete(message):
            return message
        case let .libraryOpenFailed(path):
            return "Could not open Porcupine library at \(path)."
        case let .symbolMissing(name):
            return "Porcupine symbol missing: \(name)."
        case let .initFailed(message):
            return "Porcupine setup failed: \(message)"
        case let .processFailed(message):
            return "Porcupine processing failed: \(message)"
        case let .invalidFrameLength(expected, actual):
            return "Wake-word frame length mismatch. Expected \(expected), got \(actual)."
        case .engineNotStarted:
            return "Wake-word engine is not started."
        }
    }
}

protocol WakeWordEngine: AnyObject {
    var phrase: String { get }
    var requiredSampleRate: Int { get }
    var requiredFrameLength: Int { get }

    func start() throws
    func process(_ samples: [Int16]) throws -> WakeWordDetection
    func stop()
}

/// Runtime loader for Porcupine on macOS. We load the C library from the user's
/// Application Support folder so the public repo never contains keys or binaries.
final class DynamicPorcupineWakeWordEngine: WakeWordEngine {
    private typealias PvStatus = Int32
    private typealias PvObject = OpaquePointer
    private typealias PvSampleRateFunction = @convention(c) () -> Int32
    private typealias PvFrameLengthFunction = @convention(c) () -> Int32
    private typealias PvStatusToStringFunction = @convention(c) (PvStatus) -> UnsafePointer<CChar>?
    private typealias PvInitFunction = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>,
        UnsafePointer<Float>,
        UnsafeMutablePointer<PvObject?>
    ) -> PvStatus
    private typealias PvProcessFunction = @convention(c) (
        PvObject,
        UnsafePointer<Int16>,
        UnsafeMutablePointer<Int32>
    ) -> PvStatus
    private typealias PvDeleteFunction = @convention(c) (PvObject) -> Void

    let phrase = WakeWordResources.phrase

    private var libraryHandle: UnsafeMutableRawPointer?
    private var porcupine: PvObject?
    private var sampleRateFunction: PvSampleRateFunction?
    private var frameLengthFunction: PvFrameLengthFunction?
    private var statusToStringFunction: PvStatusToStringFunction?
    private var initFunction: PvInitFunction?
    private var processFunction: PvProcessFunction?
    private var deleteFunction: PvDeleteFunction?

    var requiredSampleRate: Int {
        Int(sampleRateFunction?() ?? 16_000)
    }

    var requiredFrameLength: Int {
        Int(frameLengthFunction?() ?? 512)
    }

    deinit {
        stop()
    }

    func start() throws {
        guard porcupine == nil else { return }

        let status = WakeWordResources.setupStatus()
        guard status.isReady, let accessKey = WakeWordResources.loadAccessKey() else {
            throw WakeWordEngineError.setupIncomplete(status.detailedSummary)
        }

        try loadLibraryIfNeeded()
        guard let initFunction else {
            throw WakeWordEngineError.symbolMissing("pv_porcupine_init")
        }

        var createdObject: PvObject?
        let sensitivities: [Float] = [0.55]
        let device = "cpu"

        let initStatus = accessKey.withCString { accessKeyPointer in
            WakeWordResources.modelURL.path.withCString { modelPathPointer in
                device.withCString { devicePointer in
                    WakeWordResources.keywordURL.path.withCString { keywordPathPointer in
                        let keywordPointers: [UnsafePointer<CChar>?] = [keywordPathPointer]
                        return keywordPointers.withUnsafeBufferPointer { keywordBuffer in
                            sensitivities.withUnsafeBufferPointer { sensitivityBuffer in
                                initFunction(
                                    accessKeyPointer,
                                    modelPathPointer,
                                    devicePointer,
                                    Int32(keywordPointers.count),
                                    keywordBuffer.baseAddress!,
                                    sensitivityBuffer.baseAddress!,
                                    &createdObject
                                )
                            }
                        }
                    }
                }
            }
        }

        guard initStatus == 0, let createdObject else {
            throw WakeWordEngineError.initFailed(statusMessage(initStatus))
        }

        porcupine = createdObject
    }

    func process(_ samples: [Int16]) throws -> WakeWordDetection {
        guard let porcupine, let processFunction else {
            throw WakeWordEngineError.engineNotStarted
        }

        let expectedFrameLength = requiredFrameLength
        guard samples.count == expectedFrameLength else {
            throw WakeWordEngineError.invalidFrameLength(expected: expectedFrameLength, actual: samples.count)
        }

        var keywordIndex: Int32 = -1
        let processStatus = samples.withUnsafeBufferPointer { buffer in
            processFunction(porcupine, buffer.baseAddress!, &keywordIndex)
        }

        guard processStatus == 0 else {
            throw WakeWordEngineError.processFailed(statusMessage(processStatus))
        }

        return keywordIndex >= 0 ? .detected(phrase: phrase) : .none
    }

    func stop() {
        if let porcupine {
            deleteFunction?(porcupine)
            self.porcupine = nil
        }
        if let libraryHandle {
            dlclose(libraryHandle)
            self.libraryHandle = nil
        }
        sampleRateFunction = nil
        frameLengthFunction = nil
        statusToStringFunction = nil
        initFunction = nil
        processFunction = nil
        deleteFunction = nil
    }

    private func loadLibraryIfNeeded() throws {
        guard libraryHandle == nil else { return }

        let path = WakeWordResources.libraryURL.path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw WakeWordEngineError.libraryOpenFailed(path)
        }

        libraryHandle = handle
        sampleRateFunction = try loadSymbol("pv_sample_rate")
        frameLengthFunction = try loadSymbol("pv_porcupine_frame_length")
        statusToStringFunction = try loadSymbol("pv_status_to_string")
        initFunction = try loadSymbol("pv_porcupine_init")
        processFunction = try loadSymbol("pv_porcupine_process")
        deleteFunction = try loadSymbol("pv_porcupine_delete")
    }

    private func loadSymbol<T>(_ name: String) throws -> T {
        guard let libraryHandle, let rawSymbol = dlsym(libraryHandle, name) else {
            throw WakeWordEngineError.symbolMissing(name)
        }
        return unsafeBitCast(rawSymbol, to: T.self)
    }

    private func statusMessage(_ status: PvStatus) -> String {
        if let statusToStringFunction, let raw = statusToStringFunction(status) {
            return String(cString: raw)
        }
        return "status \(status)"
    }
}

final class WakeWordFrameBuffer {
    private var pendingSamples: [Int16] = []

    func append(_ data: Data, frameLength: Int, process: ([Int16]) throws -> Void) rethrows {
        let newSamples = data.withUnsafeBytes { rawBuffer -> [Int16] in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count / MemoryLayout<Int16>.size))
        }
        pendingSamples.append(contentsOf: newSamples)

        while pendingSamples.count >= frameLength {
            let frame = Array(pendingSamples.prefix(frameLength))
            pendingSamples.removeFirst(frameLength)
            try process(frame)
        }
    }

    func reset() {
        pendingSamples.removeAll()
    }
}
