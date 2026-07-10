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

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
    }

    @discardableResult
    func start() -> CaptureGeneration {
        condition.lock()
        defer { condition.unlock() }
        precondition(phase == .idle, "Capture already active")
        nextGeneration &+= 1
        generation = CaptureGeneration(rawValue: nextGeneration)
        samples.removeAll(keepingCapacity: true)
        inFlight = 0
        convertedBufferCount = 0
        droppedBufferCount = 0
        captureReadySignaled = false
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

        samples.append(contentsOf: buffer)
        convertedBufferCount += 1
        let signalReady = !captureReadySignaled && rms > 0.0001
        if signalReady {
            captureReadySignaled = true
        }
        return CaptureAppendResult(accepted: true, signalCaptureReady: signalReady)
    }

    func stop() async -> CapturedAudio {
        let started = Date()
        condition.lock()
        precondition(phase == .capturing, "No active capture")
        phase = .stopping
        let stoppingGeneration = generation
        condition.unlock()

        return await withCheckedContinuation { continuation in
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
                    finalizationDuration: Date().timeIntervalSince(started),
                    sampleRate: configuration.sampleRate
                )
                phase = .idle
                samples = []
                condition.unlock()
                continuation.resume(returning: captured)
            }
        }
    }
}
