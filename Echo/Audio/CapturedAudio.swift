import Foundation

struct CaptureGeneration: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

struct CapturedAudio: Sendable, Equatable {
    let generation: CaptureGeneration
    let samples: [Float]
    let convertedBufferCount: Int
    let droppedBufferCount: Int
    let finalizationTimedOut: Bool
    let finalizationDuration: TimeInterval
    let sampleRate: Double
    let transportReady: Bool
    let speechObserved: Bool
    let actualDeviceUID: String?
    let actualDeviceName: String?
    let usedFallbackDevice: Bool
    let interrupted: Bool
    let interruptionReason: String?
    let inputGapCount: Int
    let readyDuration: TimeInterval?
    let tailDuration: TimeInterval

    init(generation: CaptureGeneration, samples: [Float], convertedBufferCount: Int, droppedBufferCount: Int,
         finalizationTimedOut: Bool, finalizationDuration: TimeInterval, sampleRate: Double,
         transportReady: Bool? = nil, speechObserved: Bool = false, actualDeviceUID: String? = nil,
         actualDeviceName: String? = nil, usedFallbackDevice: Bool = false, interrupted: Bool = false,
         interruptionReason: String? = nil, inputGapCount: Int = 0, readyDuration: TimeInterval? = nil,
         tailDuration: TimeInterval = 0) {
        self.generation = generation
        self.samples = samples
        self.convertedBufferCount = convertedBufferCount
        self.droppedBufferCount = droppedBufferCount
        self.finalizationTimedOut = finalizationTimedOut
        self.finalizationDuration = finalizationDuration
        self.sampleRate = sampleRate
        self.transportReady = transportReady ?? (convertedBufferCount > 0)
        self.speechObserved = speechObserved
        self.actualDeviceUID = actualDeviceUID
        self.actualDeviceName = actualDeviceName
        self.usedFallbackDevice = usedFallbackDevice
        self.interrupted = interrupted
        self.interruptionReason = interruptionReason
        self.inputGapCount = inputGapCount
        self.readyDuration = readyDuration
        self.tailDuration = tailDuration
    }

    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

enum TrimFallbackReason: String, Sendable, Equatable {
    case emptyInput
    case invalidInput
    case noReliableSpeech
    case speechTooShort
    case excessiveTrim
}

struct TrimmedAudio: Sendable, Equatable {
    let samples: [Float]
    let selectedRange: Range<Int>
    let leadingSamplesRemoved: Int
    let trailingSamplesRemoved: Int
    let trimmingApplied: Bool
    let fallbackReason: TrimFallbackReason?

    static func fallback(_ captured: CapturedAudio, reason: TrimFallbackReason) -> TrimmedAudio {
        TrimmedAudio(
            samples: captured.samples,
            selectedRange: captured.samples.indices,
            leadingSamplesRemoved: 0,
            trailingSamplesRemoved: 0,
            trimmingApplied: false,
            fallbackReason: reason
        )
    }
}

protocol AudioTrimming: Sendable {
    func trim(_ captured: CapturedAudio) -> TrimmedAudio
}
