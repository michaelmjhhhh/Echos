import Foundation

struct CaptureConfiguration: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let tapBufferFrames: UInt32
    let minimumRecordingDuration: TimeInterval
    let analysisFrameDuration: TimeInterval
    let onsetFrameCount: Int
    let startFloorDBFS: Float
    let continuationFloorDBFS: Float
    let startMarginDB: Float
    let continuationMarginDB: Float
    let paddingDuration: TimeInterval
    let hangoverDuration: TimeInterval
    let minimumSpeechDuration: TimeInterval
    let maximumTrimRatio: Double
    let finalizationTimeout: TimeInterval

    var analysisFrameSamples: Int { Int(sampleRate * analysisFrameDuration) }
    var paddingSamples: Int { Int(sampleRate * paddingDuration) }
    var hangoverFrames: Int { Int(hangoverDuration / analysisFrameDuration) }
    var minimumSpeechSamples: Int { Int(sampleRate * minimumSpeechDuration) }
    var minimumRecordingSamples: Int { Int(sampleRate * minimumRecordingDuration) }

    static let `default` = CaptureConfiguration(
        sampleRate: 16_000,
        channelCount: 1,
        tapBufferFrames: 1_024,
        minimumRecordingDuration: 0.3,
        analysisFrameDuration: 0.02,
        onsetFrameCount: 3,
        startFloorDBFS: -45,
        continuationFloorDBFS: -50,
        startMarginDB: 12,
        continuationMarginDB: 6,
        paddingDuration: 0.16,
        hangoverDuration: 0.24,
        minimumSpeechDuration: 0.12,
        maximumTrimRatio: 0.85,
        finalizationTimeout: 0.25
    )
}
