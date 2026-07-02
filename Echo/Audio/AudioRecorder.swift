import AVFoundation
import CoreAudio

protocol AudioRecording: AnyObject {
    /// Called from the audio thread with the current input level (0...1).
    var onLevel: ((Float) -> Void)? { get set }
    /// Starts capturing from the given device UID, or the system default if nil.
    func start(deviceUID: String?) throws
    func stop() -> [Float]
}

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples,
/// the input format Whisper models expect.
///
/// A fresh AVAudioEngine is created for every recording: engines latch onto the
/// input device that was current when they were built, so reusing one breaks
/// capture after the default input changes (e.g. AirPods connecting).
final class AudioRecorder: AudioRecording {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()

    func start(deviceUID: String?) throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Pin the capture device before querying the format; falls back to the
        // system default if the chosen device has disconnected.
        if let deviceUID,
           var deviceID = AudioInputDevices.deviceID(forUID: deviceUID),
           let audioUnit = input.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioRecorderError.deviceSelectionFailed }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.formatConversionUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter, targetFormat: targetFormat)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

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
        guard error == nil, let channel = converted.floatChannelData else { return }

        let frameCount = Int(converted.frameLength)
        guard frameCount > 0 else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frameCount))
        lock.unlock()

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[0][index]
            sum += sample * sample
        }
        let rms = (sum / Float(frameCount)).squareRoot()
        onLevel?(min(1, rms * 6))
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
