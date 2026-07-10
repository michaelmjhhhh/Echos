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

    var duration: TimeInterval { Double(samples.count) / sampleRate }
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
