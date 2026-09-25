import AVFoundation
import CoreAudio

protocol AudioRecording: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    /// Transport readiness: valid samples arrived, including silent samples.
    var onCaptureReady: (() -> Void)? { get set }
    var onCaptureReadyForGeneration: ((CaptureGeneration) -> Void)? { get set }
    var onInterruption: ((CaptureGeneration, String) -> Void)? { get set }
    var captureGeneration: CaptureGeneration? { get }
    var needsBluetoothWake: Bool { get }
    func start(deviceUID: String?) throws
    func stop() async -> CapturedAudio
}

extension AudioRecording {
    var onCaptureReadyForGeneration: ((CaptureGeneration) -> Void)? { get { nil } set {} }
    var onInterruption: ((CaptureGeneration, String) -> Void)? { get { nil } set {} }
    var captureGeneration: CaptureGeneration? { nil }
    var needsBluetoothWake: Bool { false }
}

/// The converter and capture timestamps are accessed only on conversionQueue.
/// The warm engine discards idle audio; each new generation resets the converter.
// Engine lifecycle is controlled by the main-actor controller; conversion
// state stays on conversionQueue and accumulated state is lock protected.
final class AudioRecorder: AudioRecording, @unchecked Sendable {
    static let sampleRate = CaptureConfiguration.default.sampleRate
    static let keepWarmSeconds: TimeInterval = 45
    var onLevel: ((Float) -> Void)? {
        get { callbackSnapshot().level }
        set { updateCallbacks { $0.level = newValue } }
    }
    var onCaptureReady: (() -> Void)? {
        get { callbackSnapshot().ready }
        set { updateCallbacks { $0.ready = newValue } }
    }
    var onCaptureReadyForGeneration: ((CaptureGeneration) -> Void)? {
        get { callbackSnapshot().readyForGeneration }
        set { updateCallbacks { $0.readyForGeneration = newValue } }
    }
    var onInterruption: ((CaptureGeneration, String) -> Void)? {
        get { callbackSnapshot().interruption }
        set { updateCallbacks { $0.interruption = newValue } }
    }
    var captureGeneration: CaptureGeneration? { accumulator.currentGeneration }
    var needsBluetoothWake: Bool { AudioInputDevices.isBluetooth(deviceID: engineDeviceID) }

    /// The controller replaces callbacks on the main actor while conversion
    /// reads them on its queue. Copy under the lock, then invoke after unlocking.
    private struct Callbacks {
        var level: ((Float) -> Void)?
        var ready: (() -> Void)?
        var readyForGeneration: ((CaptureGeneration) -> Void)?
        var interruption: ((CaptureGeneration, String) -> Void)?
    }
    private let callbackLock = NSLock()
    private var callbacks = Callbacks()

    private func callbackSnapshot() -> Callbacks {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callbacks
    }

    private func updateCallbacks(_ update: (inout Callbacks) -> Void) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        update(&callbacks)
    }

    private var engine: AVAudioEngine?
    private var engineDeviceID: AudioDeviceID = 0
    private var engineUsesDefaultRoute = false
    private var shutdownWorkItem: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?
    private let deviceMonitor = AudioInputDeviceMonitor()
    private var deviceObserver: NSObjectProtocol?
    private let configuration: CaptureConfiguration
    private let accumulator: CaptureAccumulator
    private let conversionQueue = DispatchQueue(label: "com.michael.echo.audio-conversion", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var inputSampleRate: Double = 0
    private var captureStart: TimeInterval?
    private var captureEnd: TimeInterval?
    private var previousInputEnd: TimeInterval?

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
        self.accumulator = CaptureAccumulator(configuration: configuration)
        deviceObserver = NotificationCenter.default.addObserver(forName: AudioInputDevices.changedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.engineDeviceID != 0 else { return }
            if !AudioInputDevices.exists(deviceID: self.engineDeviceID) {
                self.interrupt("The microphone was disconnected. Reconnect it or select another input in Settings.")
            } else if self.engineUsesDefaultRoute,
                      AudioInputDevices.defaultInputDeviceID() != self.engineDeviceID {
                self.interrupt("The system microphone changed. Record again after checking the input in Settings.")
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        shutdownWorkItem?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    func start(deviceUID: String?) throws {
        guard accumulator.currentGeneration == nil else { return }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let requestedHostTime = Self.hostSeconds()
        shutdownWorkItem?.cancel()
        shutdownWorkItem = nil
        let requestedID = deviceUID.flatMap(AudioInputDevices.deviceID(forUID:))
        guard let deviceID = requestedID ?? AudioInputDevices.defaultInputDeviceID() else { throw AudioRecorderError.noInputDevice }
        if engine == nil || engineDeviceID != deviceID || engine?.isRunning != true {
            teardownEngine()
            do { try buildEngine(deviceID: deviceID) }
            catch {
                teardownEngine()
                guard requestedID != nil, let fallback = AudioInputDevices.defaultInputDeviceID(), fallback != deviceID else { throw error }
                try buildEngine(deviceID: fallback)
            }
        }
        let actual = AudioInputDevices.device(forID: engineDeviceID)
        conversionQueue.sync {
            converter?.reset()
            previousInputEnd = nil
            captureEnd = nil
            captureStart = requestedHostTime
            accumulator.start(startedAt: requestedAt)
            accumulator.setDevice(uid: actual?.uid, name: actual?.name, usedFallback: deviceUID != nil && actual?.uid != deviceUID)
        }
    }

    func stop() async -> CapturedAudio {
        let released = Self.hostSeconds()
        let tailWait: TimeInterval = conversionQueue.sync {
            guard captureStart != nil else { return 0 }
            captureEnd = released
            return min(0.1, Double(configuration.tapBufferFrames) / max(1, inputSampleRate) + 0.015)
        }
        // Admit the tap covering key release, but crop its samples to the
        // hardware timestamp. Never append speech recorded after release.
        if tailWait > 0 { try? await Task.sleep(for: .seconds(tailWait)) }
        await withCheckedContinuation { continuation in
            conversionQueue.async { [self] in
                drainConverter()
                captureStart = nil
                captureEnd = nil
                accumulator.setTailDuration(Self.hostSeconds() - released)
                continuation.resume()
            }
        }
        let captured = await accumulator.stop()
        await MainActor.run {
            let workItem = DispatchWorkItem { [weak self] in self?.teardownEngine() }
            shutdownWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepWarmSeconds, execute: workItem)
        }
        return captured
    }

    private func buildEngine(deviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // AVAudioEngine already combines the default input and output in its
        // own private aggregate. Rebinding that unit to the same physical input
        // causes a delayed configuration notification during the first capture.
        let usesDefaultRoute = deviceID == AudioInputDevices.defaultInputDeviceID()
        if !usesDefaultRoute {
            var mutableID = deviceID
            guard let audioUnit = input.audioUnit, AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ) == noErr else { throw AudioRecorderError.deviceSelectionFailed }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate,
                                         channels: AVAudioChannelCount(configuration.channelCount), interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else { throw AudioRecorderError.formatConversionUnavailable }
        conversionQueue.sync {
            self.converter = converter
            self.targetFormat = target
            self.inputSampleRate = inputFormat.sampleRate
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(configuration.tapBufferFrames), format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.conversionQueue.sync { self.append(buffer, at: time) }
        }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); engine.stop(); throw error }
        self.engine = engine
        self.engineDeviceID = deviceID
        self.engineUsesDefaultRoute = usesDefaultRoute
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            guard let self, let engine, self.engine === engine else { return }
            // A notification alone is not a failure. Ignore harmless startup
            // notifications only while this engine and both formats are valid.
            let routeUnchanged = !self.engineUsesDefaultRoute ||
                AudioInputDevices.defaultInputDeviceID() == self.engineDeviceID
            if engine.isRunning, routeUnchanged,
               engine.inputNode.inputFormat(forBus: 0) == hardwareFormat,
               engine.inputNode.outputFormat(forBus: 0) == inputFormat { return }
            self.interrupt("The microphone format or route changed. Record again after checking the input in Settings.")
        }
    }

    private func interrupt(_ reason: String) {
        if let generation = accumulator.markInterruption(reason) {
            let callback = callbackSnapshot().interruption
            callback?(generation, reason)
        }
        // A changed engine must be rebuilt before the next recording. Keep it
        // alive during finalization so already delivered samples can be drained.
        engineDeviceID = 0
    }

    private func teardownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        engineDeviceID = 0
        engineUsesDefaultRoute = false
        conversionQueue.sync { converter = nil; targetFormat = nil }
    }

    private func append(_ input: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let start = captureStart, let converter, let targetFormat else { return }
        let duration = Double(input.frameLength) / input.format.sampleRate
        let bufferStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : Self.hostSeconds() - duration
        let bufferEnd = bufferStart + duration
        if let previousInputEnd, bufferStart - previousInputEnd > 0.02 { accumulator.noteInputGap() }
        previousInputEnd = bufferEnd
        let first = max(0, Int(ceil((start - bufferStart) * input.format.sampleRate)))
        let last = min(Int(input.frameLength), captureEnd.map { max(0, Int(floor(($0 - bufferStart) * input.format.sampleRate))) } ?? Int(input.frameLength))
        guard first < last else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(last - first)) else {
            if let token = accumulator.beginAppend() { rejectAppend(token) }
            return
        }
        buffer.frameLength = AVAudioFrameCount(last - first)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let frameBytes = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        guard frameBytes > 0, source.count == destination.count else {
            if let token = accumulator.beginAppend() { rejectAppend(token) }
            return
        }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else {
                if let token = accumulator.beginAppend() { rejectAppend(token) }
                return
            }
            memcpy(to, from.advanced(by: first * frameBytes), (last - first) * frameBytes)
        }
        guard let token = accumulator.beginAppend() else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)) + 256
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { rejectAppend(token); return }
        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { rejectAppend(token); return }
        accept(converted, token: token)
    }

    private func drainConverter() {
        guard captureStart != nil, let converter, let targetFormat else { return }
        // Bound the flush even if an unexpected converter never reports EOF.
        for _ in 0..<4 {
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 2_048),
                  let token = accumulator.beginAppend() else { break }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if error != nil { rejectAppend(token); break }
            accept(converted, token: token)
            if status == .endOfStream || converted.frameLength == 0 { break }
        }
        converter.reset()
    }

    private func accept(_ buffer: AVAudioPCMBuffer, token: CaptureAppendToken) {
        guard let channel = buffer.floatChannelData else { rejectAppend(token); return }
        let count = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: count)
        // A converter can buffer input without producing output. This is not a
        // transport failure, and must still balance the in-flight append token.
        guard count > 0 else {
            _ = accumulator.completeAppend(token, samples: samples, rms: 0, conversionFailed: false)
            return
        }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        let result = accumulator.completeAppend(token, samples: samples, rms: rms, conversionFailed: false)
        let callbacks = callbackSnapshot()
        if result.signalCaptureReady {
            callbacks.readyForGeneration?(token.generation)
            callbacks.ready?()
        }
        if result.accepted { callbacks.level?(min(1, rms * 6)) }
    }

    private func rejectAppend(_ token: CaptureAppendToken) {
        let empty: [Float] = []
        empty.withUnsafeBufferPointer { _ = accumulator.completeAppend(token, samples: $0, rms: 0, conversionFailed: true) }
    }

    private static func hostSeconds() -> TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

}

enum AudioRecorderError: LocalizedError {
    case noInputDevice, formatConversionUnavailable, deviceSelectionFailed
    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found."
        case .formatConversionUnavailable: return "Could not convert microphone audio to 16 kHz."
        case .deviceSelectionFailed: return "Could not switch to the selected microphone."
        }
    }
}
