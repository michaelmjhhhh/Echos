import AVFoundation
import CoreAudio

protocol AudioRecording: AnyObject {
    /// Called from the audio thread with the current input level (0...1).
    var onLevel: ((Float) -> Void)? { get set }
    /// Called once per recording when real (non-silent) audio first arrives —
    /// Bluetooth mics can take seconds to wake up, so this is the "speak now" signal.
    var onCaptureReady: (() -> Void)? { get set }
    /// Starts capturing from the given device UID, or the system default if nil.
    func start(deviceUID: String?) throws
    func stop() async -> CapturedAudio
}

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples,
/// the input format Whisper models expect.
///
/// The engine is kept running for a grace period after each dictation: tearing
/// it down would drop a Bluetooth mic's HFP link, which takes 1–3 s to
/// re-establish and swallows the start of the next dictation. While warm, the
/// tap keeps firing but samples are discarded until the next `start`.
final class AudioRecorder: AudioRecording {
    static let sampleRate = CaptureConfiguration.default.sampleRate
    /// How long the engine (and a Bluetooth mic's link) stays alive after a dictation.
    static let keepWarmSeconds: TimeInterval = 45
    var onLevel: ((Float) -> Void)?
    var onCaptureReady: (() -> Void)?

    private var engine: AVAudioEngine?
    private var engineDeviceID: AudioDeviceID = 0
    private var shutdownWorkItem: DispatchWorkItem?
    private let configuration: CaptureConfiguration
    private let accumulator: CaptureAccumulator

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
        self.accumulator = CaptureAccumulator(configuration: configuration)
    }

    func start(deviceUID: String?) throws {
        shutdownWorkItem?.cancel()
        shutdownWorkItem = nil

        let requestedID = deviceUID.flatMap(AudioInputDevices.deviceID(forUID:))
        guard let deviceID = requestedID ?? Self.defaultInputDeviceID() else {
            throw AudioRecorderError.noInputDevice
        }
        if engine == nil || engineDeviceID != deviceID || engine?.isRunning != true {
            teardownEngine()
            do {
                try buildEngine(deviceID: deviceID)
            } catch {
                // The chosen mic wouldn't engage (stale UID, half-dropped
                // Bluetooth link, HAL hiccup). Dictating on the system default
                // beats failing outright — the selection stays saved for when
                // the device comes back.
                guard requestedID != nil,
                      let fallback = Self.defaultInputDeviceID(),
                      fallback != deviceID else { throw error }
                try buildEngine(deviceID: fallback)
            }
        }

        accumulator.start()
    }

    func stop() async -> CapturedAudio {
        let captured = await accumulator.stop()
        let workItem = DispatchWorkItem { [weak self] in self?.teardownEngine() }
        shutdownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepWarmSeconds, execute: workItem)
        return captured
    }

    private func buildEngine(deviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var mutableID = deviceID
        guard let audioUnit = input.audioUnit, AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            throw AudioRecorderError.deviceSelectionFailed
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: configuration.sampleRate,
            channels: AVAudioChannelCount(configuration.channelCount),
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.formatConversionUnavailable
        }

        // Small buffers: the final partial buffer on key-release arrives ~64 ms
        // sooner and at most ~21 ms of trailing speech stays undelivered
        // (vs ~85 ms at 4096), and the waveform level updates ~4× as often.
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(configuration.tapBufferFrames),
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.append(buffer, using: converter, targetFormat: targetFormat)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.engineDeviceID = deviceID
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        engineDeviceID = 0
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        guard let token = accumulator.beginAppend() else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            rejectAppend(token)
            return
        }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData else {
            rejectAppend(token)
            return
        }
        let frameCount = Int(converted.frameLength)
        guard frameCount > 0 else {
            rejectAppend(token)
            return
        }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[0][index]
            sum += sample * sample
        }
        let rms = (sum / Float(frameCount)).squareRoot()
        let pointer = UnsafeBufferPointer(start: channel[0], count: frameCount)
        let result = accumulator.completeAppend(
            token,
            samples: pointer,
            rms: rms,
            conversionFailed: false
        )

        if result.signalCaptureReady { onCaptureReady?() }
        if result.accepted { onLevel?(min(1, rms * 6)) }
    }

    private func rejectAppend(_ token: CaptureAppendToken) {
        let empty: [Float] = []
        empty.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(token, samples: $0, rms: 0, conversionFailed: true)
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case formatConversionUnavailable
    case deviceSelectionFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found."
        case .formatConversionUnavailable: return "Could not convert microphone audio to 16 kHz."
        case .deviceSelectionFailed: return "Could not switch to the selected microphone."
        }
    }
}
