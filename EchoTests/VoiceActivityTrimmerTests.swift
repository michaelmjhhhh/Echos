import XCTest
@testable import Echo

final class VoiceActivityTrimmerTests: XCTestCase {
    private let configuration = CaptureConfiguration.default

    private func frames(_ count: Int, amplitude: Float) -> [Float] {
        [Float](repeating: amplitude, count: count * configuration.analysisFrameSamples)
    }

    private func capture(_ samples: [Float]) -> CapturedAudio {
        CapturedAudio(
            generation: CaptureGeneration(rawValue: 1),
            samples: samples,
            convertedBufferCount: samples.isEmpty ? 0 : 1,
            droppedBufferCount: 0,
            finalizationTimedOut: false,
            finalizationDuration: 0.01,
            sampleRate: configuration.sampleRate
        )
    }

    func testTrimsLeadingAndTrailingSilenceWithPaddingAndHangover() {
        let silence = frames(30, amplitude: 0.0001)
        let speech = frames(25, amplitude: 0.2)
        let result = VoiceActivityTrimmer(configuration: configuration)
            .trim(capture(silence + speech + silence))

        XCTAssertTrue(result.trimmingApplied)
        XCTAssertNil(result.fallbackReason)
        XCTAssertEqual(result.leadingSamplesRemoved, silence.count - configuration.paddingSamples)
        XCTAssertEqual(
            result.trailingSamplesRemoved,
            silence.count
                - configuration.paddingSamples
                - configuration.hangoverFrames * configuration.analysisFrameSamples
        )
    }

    func testPreservesInternalPauseBetweenSpeechRegions() {
        let outerSilence = frames(30, amplitude: 0.0001)
        let first = frames(10, amplitude: 0.2)
        let pause = frames(20, amplitude: 0.0001)
        let second = frames(10, amplitude: 0.2)
        let original = outerSilence + first + pause + second + outerSilence

        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture(original))

        XCTAssertTrue(result.trimmingApplied)
        XCTAssertEqual(result.samples, Array(original[result.selectedRange]))
        XCTAssertGreaterThanOrEqual(result.samples.count, first.count + pause.count + second.count)
    }

    func testEmptyInputFallsBack() {
        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture([]))
        XCTAssertEqual(result.fallbackReason, .emptyInput)
        XCTAssertFalse(result.trimmingApplied)
    }

    func testAllSilenceFallsBackWithoutChangingSamples() {
        let original = frames(40, amplitude: 0.0001)
        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture(original))
        XCTAssertEqual(result.fallbackReason, .noReliableSpeech)
        XCTAssertEqual(result.samples, original)
    }

    func testQuietAmbiguousAudioFallsBack() {
        let original = frames(40, amplitude: 0.001)
        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture(original))
        XCTAssertEqual(result.fallbackReason, .noReliableSpeech)
        XCTAssertEqual(result.samples, original)
    }

    func testSpeechUnderMinimumDurationFallsBack() {
        let original = frames(20, amplitude: 0.0001)
            + frames(5, amplitude: 0.2)
            + frames(20, amplitude: 0.0001)
        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture(original))
        XCTAssertEqual(result.fallbackReason, .speechTooShort)
        XCTAssertEqual(result.samples, original)
    }

    func testExcessiveTrimFallsBack() {
        let original = frames(200, amplitude: 0.0001)
            + frames(6, amplitude: 0.2)
            + frames(200, amplitude: 0.0001)
        let result = VoiceActivityTrimmer(configuration: configuration).trim(capture(original))
        XCTAssertEqual(result.fallbackReason, .excessiveTrim)
        XCTAssertEqual(result.samples, original)
    }

    func testRepeatedInputProducesIdenticalOutput() {
        let original = frames(30, amplitude: 0.0001)
            + frames(25, amplitude: 0.2)
            + frames(30, amplitude: 0.0001)
        let trimmer = VoiceActivityTrimmer(configuration: configuration)
        XCTAssertEqual(trimmer.trim(capture(original)), trimmer.trim(capture(original)))
    }
}
