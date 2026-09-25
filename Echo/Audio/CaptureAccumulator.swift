import Foundation

struct CaptureAppendToken: Sendable, Equatable {
    let generation: CaptureGeneration
}

struct CaptureAppendResult: Sendable, Equatable {
    let accepted: Bool
    let signalCaptureReady: Bool
}

final class CaptureAccumulator: @unchecked Sendable {
    private enum Phase {
        case idle
        case capturing
        case stopping
    }

    private let condition = NSCondition()
    private let configuration: CaptureConfiguration
    private let finalizationQueue = DispatchQueue(label: "com.michael.echo.capture-finalization")
    private var phase: Phase = .idle
    private var nextGeneration: UInt64 = 0
    private var generation = CaptureGeneration(rawValue: 0)
    private var samples: [Float] = []
    private var inFlight = 0
    private var convertedBufferCount = 0
    private var droppedBufferCount = 0
    private var captureReadySignaled = false
    private var speechObserved = false
    private var startUptime: TimeInterval = 0
    private var readyDuration: TimeInterval?
    private var actualDeviceUID: String?
    private var actualDeviceName: String?
    private var usedFallbackDevice = false
    private var interruptionReason: String?
    private var inputGapCount = 0
    private var tailDuration: TimeInterval = 0

    var currentGeneration: CaptureGeneration? {
        condition.lock()
        defer { condition.unlock() }
        return phase == .idle ? nil : generation
    }

    func setDevice(uid: String?, name: String?, usedFallback: Bool) {
        condition.lock()
        defer { condition.unlock() }
        actualDeviceUID = uid
        actualDeviceName = name
        usedFallbackDevice = usedFallback
    }

    func markInterruption(_ reason: String) -> CaptureGeneration? {
        condition.lock()
        defer { condition.unlock() }
        guard phase != .idle else { return nil }
        interruptionReason = reason
        return generation
    }

    func noteInputGap() {
        condition.lock()
        if phase != .idle { inputGapCount += 1 }
        condition.unlock()
    }

    func setTailDuration(_ duration: TimeInterval) {
        condition.lock()
        tailDuration = duration
        condition.unlock()
    }

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
    }

    @discardableResult
    func start(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CaptureGeneration {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .idle else { return generation }
        nextGeneration &+= 1
        generation = CaptureGeneration(rawValue: nextGeneration)
        samples.removeAll(keepingCapacity: true)
        inFlight = 0
        convertedBufferCount = 0
        droppedBufferCount = 0
        captureReadySignaled = false
        speechObserved = false
        startUptime = startedAt
        readyDuration = nil
        interruptionReason = nil
        inputGapCount = 0
        tailDuration = 0
        phase = .capturing
        return generation
    }

    func beginAppend() -> CaptureAppendToken? {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .capturing else { return nil }
        inFlight += 1
        return CaptureAppendToken(generation: generation)
    }

    func completeAppend(
        _ token: CaptureAppendToken,
        samples buffer: UnsafeBufferPointer<Float>,
        rms: Float,
        conversionFailed: Bool
    ) -> CaptureAppendResult {
        condition.lock()
        guard token.generation == generation else {
            condition.unlock()
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        defer {
            inFlight = max(0, inFlight - 1)
            if inFlight == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }
        guard phase != .idle else {
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        if conversionFailed {
            droppedBufferCount += 1
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }

        guard !buffer.isEmpty else {
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        guard buffer.allSatisfy(\.isFinite) else {
            droppedBufferCount += 1
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        samples.append(contentsOf: buffer)
        convertedBufferCount += 1
        speechObserved = speechObserved || rms > 0.0001
        // Transport readiness is independent of acoustic energy. A silent mic
        // is working; speech presence is separate metadata, never a validity gate.
        let signalReady = !captureReadySignaled
        if signalReady {
            captureReadySignaled = true
            readyDuration = ProcessInfo.processInfo.systemUptime - startUptime
        }
        return CaptureAppendResult(accepted: true, signalCaptureReady: signalReady)
    }

    func stop() async -> CapturedAudio {
        let started = ProcessInfo.processInfo.systemUptime
        return await withCheckedContinuation { continuation in
            condition.lock()
            guard phase == .capturing else {
                let empty = CapturedAudio(
                    generation: generation, samples: [], convertedBufferCount: 0,
                    droppedBufferCount: 0, finalizationTimedOut: false,
                    finalizationDuration: ProcessInfo.processInfo.systemUptime - started,
                    sampleRate: configuration.sampleRate
                )
                condition.unlock()
                continuation.resume(returning: empty)
                return
            }
            phase = .stopping
            let stoppingGeneration = generation
            condition.unlock()
            finalizationQueue.async { [self] in
                condition.lock()
                let deadline = Date().addingTimeInterval(configuration.finalizationTimeout)
                while inFlight > 0 && condition.wait(until: deadline) {}
                let timedOut = inFlight > 0
                let captured = CapturedAudio(
                    generation: stoppingGeneration,
                    samples: samples,
                    convertedBufferCount: convertedBufferCount,
                    droppedBufferCount: droppedBufferCount,
                    finalizationTimedOut: timedOut,
                    finalizationDuration: ProcessInfo.processInfo.systemUptime - started + tailDuration,
                    sampleRate: configuration.sampleRate,
                    transportReady: captureReadySignaled,
                    speechObserved: speechObserved,
                    actualDeviceUID: actualDeviceUID,
                    actualDeviceName: actualDeviceName,
                    usedFallbackDevice: usedFallbackDevice,
                    interrupted: interruptionReason != nil,
                    interruptionReason: interruptionReason,
                    inputGapCount: inputGapCount,
                    readyDuration: readyDuration,
                    tailDuration: tailDuration
                )
                phase = .idle
                samples = []
                condition.unlock()
                continuation.resume(returning: captured)
            }
        }
    }
}
