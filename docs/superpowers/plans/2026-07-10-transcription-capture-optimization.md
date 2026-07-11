# Transcription Capture Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deterministically finalize microphone capture, conservatively trim low-confidence silence without clipping speech, and persist privacy-safe stage metrics so Echo improves transcription consistency and latency without accuracy regression.

**Architecture:** Keep AVAudioEngine capture, WhisperKit final-only decoding, and insertion unchanged. Add focused audio-domain value types, a pure energy-based trimmer, and a condition-backed `CaptureAccumulator` that owns generation and in-flight callback synchronization; `DictationController` asynchronously composes finalization, trimming, transcription, and metrics.

**Tech Stack:** Swift 5.9, macOS 14+, AVFoundation/CoreAudio, Swift structured concurrency, SQLite3, XCTest, WhisperKit.

## Global Constraints

- Output audio remains 16 kHz mono Float32.
- Tap size remains 1,024 native input frames and the 45-second warm-engine behavior remains unchanged.
- First release uses internal VAD parameters; no user-facing settings are added.
- Trimming is deterministic O(n), preserves internal pauses and sample values, and falls back to the original finalized audio whenever confidence is insufficient.
- Initial trimmer defaults: 20 ms frames, three-frame onset, 160 ms pre/post padding, 240 ms hangover, 120 ms minimum speech interval, and 85% maximum trim ratio.
- Thresholds are `max(-45 dBFS, noiseFloor + 12 dB)` for start and `max(-50 dBFS, noiseFloor + 6 dB)` for continuation; noise floor is the 20th-percentile frame RMS in dBFS.
- Capture finalization is bounded to 250 ms and must not block the main actor.
- No streaming, endpoint-triggered auto-stop, denoising, normalization, long-audio chunking, transcription cancellation, or provider timeout is added.
- Never persist audio samples, transcript text, vocabulary, microphone name, or device UID.
- Preserve existing text processors, history, insertion, copy fallback, model selection, and user-visible error behavior.
- Follow TDD: every behavior change starts with a failing focused test, then minimal implementation, focused verification, and a small commit.

---

## File Structure

### Create

- `Echo/Audio/CaptureConfiguration.swift` — immutable capture and trimmer constants.
- `Echo/Audio/CapturedAudio.swift` — finalized and trimmed audio values, generation token, and fallback classification.
- `Echo/Audio/VoiceActivityTrimmer.swift` — pure deterministic speech-region analysis.
- `Echo/Audio/CaptureAccumulator.swift` — generation state, in-flight callback registration, bounded asynchronous finalization, and sample diagnostics.
- `EchoTests/VoiceActivityTrimmerTests.swift` — synthetic signal and fallback tests.
- `EchoTests/CaptureAccumulatorTests.swift` — deterministic concurrency/generation tests without microphone hardware.
- `docs/benchmarks/transcription-capture-benchmark.md` — device benchmark procedure and release gates.

### Modify

- `Echo/Audio/AudioRecorder.swift` — adopt shared configuration and delegate lifecycle synchronization to `CaptureAccumulator`.
- `Echo/DictationController.swift` — asynchronously finalize and trim before the existing decode; collect stage metrics.
- `Echo/Usage/UsageStore.swift` — additive schema migration, operational event model, and success-filtered product queries.
- `EchoTests/DictationControllerTests.swift` — async recorder mock, trimmer injection, sample-selection and metrics tests.
- `EchoTests/UsageStoreTests.swift` — legacy schema migration, status filtering, and operational metric tests.

---

### Task 1: Audio Value Types and Conservative Trimmer

**Files:**
- Create: `Echo/Audio/CaptureConfiguration.swift`
- Create: `Echo/Audio/CapturedAudio.swift`
- Create: `Echo/Audio/VoiceActivityTrimmer.swift`
- Create: `EchoTests/VoiceActivityTrimmerTests.swift`

**Interfaces:**
- Produces: `CaptureConfiguration.default`, `CaptureGeneration`, `CapturedAudio`, `TrimmedAudio`, `TrimFallbackReason`, `AudioTrimming`, and `VoiceActivityTrimmer.trim(_:)`.
- Consumes: Foundation only; the trimmer has no AVFoundation, controller, database, or WhisperKit dependency.

- [ ] **Step 1: Add failing tests for confident trimming, padding, and preserved internal pauses**

Create `EchoTests/VoiceActivityTrimmerTests.swift` with deterministic constant-amplitude fixtures:

```swift
import XCTest
@testable import Echo

final class VoiceActivityTrimmerTests: XCTestCase {
    private let config = CaptureConfiguration.default

    private func frames(_ count: Int, amplitude: Float) -> [Float] {
        [Float](repeating: amplitude, count: count * config.analysisFrameSamples)
    }

    private func capture(_ samples: [Float]) -> CapturedAudio {
        CapturedAudio(
            generation: CaptureGeneration(rawValue: 1),
            samples: samples,
            convertedBufferCount: 1,
            droppedBufferCount: 0,
            finalizationTimedOut: false,
            finalizationDuration: 0.01,
            sampleRate: config.sampleRate
        )
    }

    func testTrimsLeadingAndTrailingSilenceWithPadding() {
        let silence = frames(30, amplitude: 0.0001)
        let speech = frames(25, amplitude: 0.2)
        let result = VoiceActivityTrimmer(configuration: config)
            .trim(capture(silence + speech + silence))

        XCTAssertTrue(result.trimmingApplied)
        XCTAssertNil(result.fallbackReason)
        XCTAssertEqual(result.leadingSamplesRemoved, silence.count - config.paddingSamples)
        XCTAssertEqual(
            result.trailingSamplesRemoved,
            silence.count - config.paddingSamples - config.hangoverFrames * config.analysisFrameSamples
        )
        XCTAssertEqual(result.samples.count, speech.count + 2 * config.paddingSamples)
    }

    func testPreservesInternalPauseBetweenSpeechRegions() {
        let outerSilence = frames(30, amplitude: 0.0001)
        let first = frames(10, amplitude: 0.2)
        let pause = frames(20, amplitude: 0.0001)
        let second = frames(10, amplitude: 0.2)
        let original = outerSilence + first + pause + second + outerSilence

        let result = VoiceActivityTrimmer(configuration: config).trim(capture(original))

        XCTAssertTrue(result.trimmingApplied)
        let selected = Array(original[result.selectedRange])
        XCTAssertEqual(result.samples, selected)
        XCTAssertTrue(result.samples.contains(0.0001))
        XCTAssertGreaterThanOrEqual(result.samples.count, first.count + pause.count + second.count)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the expected compile failure**

Run:

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/VoiceActivityTrimmerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `CaptureConfiguration`, `CapturedAudio`, and `VoiceActivityTrimmer` do not exist.

- [ ] **Step 3: Add the shared audio-domain values and exact defaults**

Create `Echo/Audio/CaptureConfiguration.swift`:

```swift
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
```

Create `Echo/Audio/CapturedAudio.swift`:

```swift
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
```

- [ ] **Step 4: Implement the minimal deterministic energy trimmer**

Create `Echo/Audio/VoiceActivityTrimmer.swift`. Implement these exact helpers and flow:

```swift
import Foundation

struct VoiceActivityTrimmer: AudioTrimming {
    let configuration: CaptureConfiguration

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
    }

    func trim(_ captured: CapturedAudio) -> TrimmedAudio {
        let samples = captured.samples
        let frameSize = configuration.analysisFrameSamples
        guard !samples.isEmpty, frameSize > 0 else {
            return .fallback(captured, reason: .emptyInput)
        }

        let energies = stride(from: 0, to: samples.count, by: frameSize).map { start -> Float in
            let end = min(start + frameSize, samples.count)
            var sum: Float = 0
            for sample in samples[start..<end] { sum += sample * sample }
            let rms = sqrt(sum / Float(end - start))
            return 20 * log10(max(rms, 0.000_000_1))
        }
        let sorted = energies.sorted()
        let noiseIndex = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.2))
        let noiseFloor = sorted[noiseIndex]
        let startThreshold = max(configuration.startFloorDBFS, noiseFloor + configuration.startMarginDB)
        let continuationThreshold = max(
            configuration.continuationFloorDBFS,
            noiseFloor + configuration.continuationMarginDB
        )

        guard let firstSpeechFrame = onsetFrame(in: energies, threshold: startThreshold) else {
            return .fallback(captured, reason: .noReliableSpeech)
        }
        let lastActiveFrame = finalActiveFrame(
            in: energies,
            startingAt: firstSpeechFrame,
            threshold: continuationThreshold
        )

        let speechStart = firstSpeechFrame * frameSize
        let activeSpeechEnd = min(samples.count, (lastActiveFrame + 1) * frameSize)
        guard activeSpeechEnd - speechStart >= configuration.minimumSpeechSamples else {
            return .fallback(captured, reason: .speechTooShort)
        }

        let selectedStart = max(0, speechStart - configuration.paddingSamples)
        let hangoverSamples = configuration.hangoverFrames * frameSize
        let selectedEnd = min(
            samples.count,
            activeSpeechEnd + hangoverSamples + configuration.paddingSamples
        )
        let removed = samples.count - (selectedEnd - selectedStart)
        guard Double(removed) / Double(samples.count) <= configuration.maximumTrimRatio else {
            return .fallback(captured, reason: .excessiveTrim)
        }
        guard selectedStart > 0 || selectedEnd < samples.count else {
            return .fallback(captured, reason: .noReliableSpeech)
        }

        let range = selectedStart..<selectedEnd
        return TrimmedAudio(
            samples: Array(samples[range]),
            selectedRange: range,
            leadingSamplesRemoved: selectedStart,
            trailingSamplesRemoved: samples.count - selectedEnd,
            trimmingApplied: true,
            fallbackReason: nil
        )
    }

    private func onsetFrame(in energies: [Float], threshold: Float) -> Int? {
        var run = 0
        for (index, energy) in energies.enumerated() {
            run = energy >= threshold ? run + 1 : 0
            if run == configuration.onsetFrameCount {
                return index - configuration.onsetFrameCount + 1
            }
        }
        return nil
    }

    private func finalActiveFrame(
        in energies: [Float],
        startingAt first: Int,
        threshold: Float
    ) -> Int {
        var lastActive = first
        for index in first..<energies.count where energies[index] >= threshold {
            lastActive = index
        }
        return lastActive
    }
}
```

- [ ] **Step 5: Run focused tests and verify they pass**

Run the Task 1 focused command again.

Expected: `VoiceActivityTrimmerTests` PASS.

- [ ] **Step 6: Add fallback and determinism tests**

Append these concrete tests:

```swift
func testEmptyInputFallsBack() {
    let result = VoiceActivityTrimmer(configuration: config).trim(capture([]))
    XCTAssertEqual(result.fallbackReason, .emptyInput)
    XCTAssertFalse(result.trimmingApplied)
}

func testAllSilenceFallsBackWithoutChangingSamples() {
    let original = frames(40, amplitude: 0.0001)
    let result = VoiceActivityTrimmer(configuration: config).trim(capture(original))
    XCTAssertEqual(result.fallbackReason, .noReliableSpeech)
    XCTAssertEqual(result.samples, original)
}

func testQuietAmbiguousAudioFallsBack() {
    let original = frames(40, amplitude: 0.001)
    let result = VoiceActivityTrimmer(configuration: config).trim(capture(original))
    XCTAssertEqual(result.fallbackReason, .noReliableSpeech)
    XCTAssertEqual(result.samples, original)
}

func testSpeechUnderMinimumDurationFallsBack() {
    let original = frames(20, amplitude: 0.0001) + frames(5, amplitude: 0.2) + frames(20, amplitude: 0.0001)
    let result = VoiceActivityTrimmer(configuration: config).trim(capture(original))
    XCTAssertEqual(result.fallbackReason, .speechTooShort)
    XCTAssertEqual(result.samples, original)
}

func testExcessiveTrimFallsBack() {
    let original = frames(200, amplitude: 0.0001) + frames(6, amplitude: 0.2) + frames(200, amplitude: 0.0001)
    let result = VoiceActivityTrimmer(configuration: config).trim(capture(original))
    XCTAssertEqual(result.fallbackReason, .excessiveTrim)
    XCTAssertEqual(result.samples, original)
}

func testRepeatedInputProducesIdenticalOutput() {
    let original = frames(30, amplitude: 0.0001) + frames(25, amplitude: 0.2) + frames(30, amplitude: 0.0001)
    let trimmer = VoiceActivityTrimmer(configuration: config)
    XCTAssertEqual(trimmer.trim(capture(original)), trimmer.trim(capture(original)))
}
```

- [ ] **Step 7: Run Task 1 tests and commit**

Run:

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/VoiceActivityTrimmerTests CODE_SIGNING_ALLOWED=NO
git add Echo/Audio/CaptureConfiguration.swift Echo/Audio/CapturedAudio.swift \
  Echo/Audio/VoiceActivityTrimmer.swift EchoTests/VoiceActivityTrimmerTests.swift
git commit -m "feat: add conservative voice activity trimming"
```

Expected: focused tests PASS and commit succeeds.

---

### Task 2: Capture Accumulator and Deterministic Finalization

**Files:**
- Create: `Echo/Audio/CaptureAccumulator.swift`
- Create: `EchoTests/CaptureAccumulatorTests.swift`

**Interfaces:**
- Consumes: `CaptureConfiguration`, `CaptureGeneration`, and `CapturedAudio` from Task 1.
- Produces: `CaptureAppendToken`, `CaptureAppendResult`, `CaptureAccumulator.start()`, `beginAppend()`, `completeAppend(...)`, and async `stop()` for `AudioRecorder` in Task 3.

- [ ] **Step 1: Write failing tests for before-stop inclusion and after-stop rejection**

Create `EchoTests/CaptureAccumulatorTests.swift`:

```swift
import XCTest
@testable import Echo

final class CaptureAccumulatorTests: XCTestCase {
    func testAppendRegisteredBeforeStopIsIncluded() async {
        let accumulator = CaptureAccumulator(configuration: .default)
        let generation = accumulator.start()
        let token = try! XCTUnwrap(accumulator.beginAppend())

        let stopTask = Task { await accumulator.stop() }
        await Task.yield()
        let values: [Float] = [0.1, 0.2, 0.3]
        values.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(token, samples: $0, rms: 0.2, conversionFailed: false)
        }
        let captured = await stopTask.value

        XCTAssertEqual(captured.generation, generation)
        XCTAssertEqual(captured.samples, values)
        XCTAssertFalse(captured.finalizationTimedOut)
    }

    func testAppendCannotRegisterAfterStopBegins() async {
        let accumulator = CaptureAccumulator(configuration: .default)
        accumulator.start()
        let existing = try! XCTUnwrap(accumulator.beginAppend())
        let stopTask = Task { await accumulator.stop() }
        await Task.yield()

        XCTAssertNil(accumulator.beginAppend())
        let empty: [Float] = []
        empty.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(existing, samples: $0, rms: 0, conversionFailed: false)
        }
        _ = await stopTask.value
    }
}
```

- [ ] **Step 2: Run focused tests and verify compile failure**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/CaptureAccumulatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `CaptureAccumulator` is undefined.

- [ ] **Step 3: Implement the synchronized accumulator state machine**

Create `Echo/Audio/CaptureAccumulator.swift` with these types and invariants:

```swift
import Foundation

struct CaptureAppendToken: Sendable, Equatable {
    let generation: CaptureGeneration
}

struct CaptureAppendResult: Sendable, Equatable {
    let accepted: Bool
    let signalCaptureReady: Bool
}

final class CaptureAccumulator: @unchecked Sendable {
    private enum Phase { case idle, capturing, stopping }

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
            if inFlight == 0 { condition.broadcast() }
            condition.unlock()
        }
        guard phase != .idle else {
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        if conversionFailed {
            droppedBufferCount += 1
            return CaptureAppendResult(accepted: false, signalCaptureReady: false)
        }
        self.samples.append(contentsOf: buffer)
        convertedBufferCount += 1
        let signalReady = !captureReadySignaled && rms > 0.0001
        if signalReady { captureReadySignaled = true }
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
```

`UnsafeBufferPointer` use remains synchronous inside `completeAppend`; only the immutable `CapturedAudio` value crosses the continuation boundary.

- [ ] **Step 4: Run focused tests and verify pass**

Run the Task 2 focused command again.

Expected: the two initial tests PASS.

- [ ] **Step 5: Add failure, timeout, and generation-isolation tests**

Append these concrete tests:

```swift
func testConversionFailureIsCounted() async throws {
    let accumulator = CaptureAccumulator(configuration: .default)
    accumulator.start()
    let token = try XCTUnwrap(accumulator.beginAppend())
    let empty: [Float] = []
    empty.withUnsafeBufferPointer {
        _ = accumulator.completeAppend(token, samples: $0, rms: 0, conversionFailed: true)
    }
    let captured = await accumulator.stop()
    XCTAssertEqual(captured.droppedBufferCount, 1)
    XCTAssertEqual(captured.convertedBufferCount, 0)
    XCTAssertTrue(captured.samples.isEmpty)
}

func testFinalizationTimeoutRejectsLateCompletion() async throws {
    let accumulator = CaptureAccumulator(configuration: .default)
    accumulator.start()
    let token = try XCTUnwrap(accumulator.beginAppend())
    let started = Date()
    let captured = await accumulator.stop()
    XCTAssertTrue(captured.finalizationTimedOut)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.20)
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.60)
    let late: [Float] = [0.9]
    let result = late.withUnsafeBufferPointer {
        accumulator.completeAppend(token, samples: $0, rms: 0.9, conversionFailed: false)
    }
    XCTAssertFalse(result.accepted)
}

func testTimedOutOldGenerationCannotContaminateNewGeneration() async throws {
    let accumulator = CaptureAccumulator(configuration: .default)
    accumulator.start()
    let oldToken = try XCTUnwrap(accumulator.beginAppend())
    _ = await accumulator.stop()

    let secondGeneration = accumulator.start()
    let newToken = try XCTUnwrap(accumulator.beginAppend())
    let old: [Float] = [0.9]
    let new: [Float] = [0.2]
    old.withUnsafeBufferPointer {
        _ = accumulator.completeAppend(oldToken, samples: $0, rms: 0.9, conversionFailed: false)
    }
    new.withUnsafeBufferPointer {
        _ = accumulator.completeAppend(newToken, samples: $0, rms: 0.2, conversionFailed: false)
    }
    let captured = await accumulator.stop()
    XCTAssertEqual(captured.generation, secondGeneration)
    XCTAssertEqual(captured.samples, new)
}

func testGenerationsIncreaseAcrossCaptures() async {
    let accumulator = CaptureAccumulator(configuration: .default)
    let first = accumulator.start()
    _ = await accumulator.stop()
    let second = accumulator.start()
    _ = await accumulator.stop()
    XCTAssertGreaterThan(second.rawValue, first.rawValue)
}
```

Do not use microphone hardware in these tests.

Do not use microphone hardware in these tests.

- [ ] **Step 6: Run focused tests and commit**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/CaptureAccumulatorTests CODE_SIGNING_ALLOWED=NO
git add Echo/Audio/CaptureAccumulator.swift EchoTests/CaptureAccumulatorTests.swift
git commit -m "feat: finalize capture generations deterministically"
```

Expected: focused tests PASS and commit succeeds.

---

### Task 3: Integrate Asynchronous Finalization into AudioRecorder

**Files:**
- Modify: `Echo/Audio/AudioRecorder.swift`
- Test: `EchoTests/CaptureAccumulatorTests.swift`

**Interfaces:**
- Consumes: `CaptureAccumulator`, `CaptureConfiguration`, and `CapturedAudio` from Tasks 1–2.
- Produces: `AudioRecording.stop() async -> CapturedAudio`, consumed by controller and test mocks in Task 5.

- [ ] **Step 1: Change the recorder protocol and observe dependent compile failures**

Change the protocol declaration to:

```swift
protocol AudioRecording: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onCaptureReady: (() -> Void)? { get set }
    func start(deviceUID: String?) throws
    func stop() async -> CapturedAudio
}
```

Run:

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL at `DictationController.finishRecording()` and `MockRecorder.stop()` because they still use the synchronous `[Float]` contract.

- [ ] **Step 2: Replace recorder-owned capture state with `CaptureAccumulator`**

In `AudioRecorder`:

```swift
private let configuration: CaptureConfiguration
private let accumulator: CaptureAccumulator

init(configuration: CaptureConfiguration = .default) {
    self.configuration = configuration
    self.accumulator = CaptureAccumulator(configuration: configuration)
}
```

Remove `lock`, `samples`, `isCapturing`, and `captureReadySignaled`. After engine setup succeeds in `start`, call `accumulator.start()`.

Use configuration in format and tap creation:

```swift
sampleRate: configuration.sampleRate
channels: AVAudioChannelCount(configuration.channelCount)

input.installTap(
    onBus: 0,
    bufferSize: AVAudioFrameCount(configuration.tapBufferFrames),
    format: inputFormat
) { [weak self] buffer, _ in
    self?.append(buffer, using: converter, targetFormat: targetFormat)
}
```

Keep `AudioRecorder.sampleRate` temporarily as a compatibility alias until Task 5 removes controller use:

```swift
static let sampleRate = CaptureConfiguration.default.sampleRate
```

- [ ] **Step 3: Route callback registration and completion through the accumulator**

At the start of `append`, register before conversion:

```swift
guard let token = accumulator.beginAppend() else { return }
```

On allocation/conversion/empty-frame failure, complete once with an empty pointer and `conversionFailed: true`. Add a local helper to guarantee balanced completion:

```swift
private func rejectAppend(_ token: CaptureAppendToken) {
    let empty: [Float] = []
    empty.withUnsafeBufferPointer {
        _ = accumulator.completeAppend(token, samples: $0, rms: 0, conversionFailed: true)
    }
}
```

After RMS calculation:

```swift
let result = UnsafeBufferPointer(start: channel[0], count: frameCount).withMemoryRebound(
    to: Float.self
) { pointer in
    accumulator.completeAppend(token, samples: pointer, rms: rms, conversionFailed: false)
}
if result.signalCaptureReady { onCaptureReady?() }
if result.accepted { onLevel?(min(1, rms * 6)) }
```

If `withMemoryRebound` is unnecessary for the compiler, pass the `UnsafeBufferPointer<Float>` directly. Every successful `beginAppend()` path must call `completeAppend` exactly once.

- [ ] **Step 4: Implement async stop while preserving warm-engine scheduling**

Replace synchronous stop with:

```swift
func stop() async -> CapturedAudio {
    let captured = await accumulator.stop()
    let workItem = DispatchWorkItem { [weak self] in self?.teardownEngine() }
    shutdownWorkItem = workItem
    DispatchQueue.main.asyncAfter(
        deadline: .now() + Self.keepWarmSeconds,
        execute: workItem
    )
    return captured
}
```

Do not stop or remove the tap at key release.

- [ ] **Step 5: Add a static source-contract test for the protocol transition**

Because AVAudioEngine device integration is not deterministic in unit tests, add one test to `CaptureAccumulatorTests` that instantiates `AudioRecorder(configuration: .default)` and verifies it conforms to `AudioRecording` at compile time:

```swift
func testAudioRecorderConformsToAsyncRecordingContract() {
    let recorder: any AudioRecording = AudioRecorder(configuration: .default)
    XCTAssertNotNil(recorder)
}
```

- [ ] **Step 6: Adapt the controller and mock to the async finalized-audio contract**

Update `MockRecorder.stop()`:

```swift
private(set) var stopCallCount = 0

func stop() async -> CapturedAudio {
    stopCallCount += 1
    return CapturedAudio(
        generation: CaptureGeneration(rawValue: UInt64(stopCallCount)),
        samples: samplesToReturn,
        convertedBufferCount: samplesToReturn.isEmpty ? 0 : 1,
        droppedBufferCount: 0,
        finalizationTimedOut: false,
        finalizationDuration: 0,
        sampleRate: CaptureConfiguration.default.sampleRate
    )
}
```

In `DictationController`, preserve the current pipeline but move it behind one async task. Replace the synchronous body of `finishRecording()` with:

```swift
private var isFinishingRecording = false

private func finishRecording() {
    guard case .recording = state, !isFinishingRecording else { return }
    isFinishingRecording = true
    maxDurationTask?.cancel()
    maxDurationTask = nil
    micWakeTask?.cancel()
    micWakeTask = nil
    let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let releasedAt = Date()
    recordingStartedAt = nil

    transcriptionTask = Task { [weak self] in
        guard let self else { return }
        defer { self.isFinishingRecording = false }
        let captured = await self.recorder.stop()
        await self.transcribeFinalizedCapture(
            captured,
            heldFor: heldFor,
            releasedAt: releasedAt
        )
    }
}
```

Extract the old post-`stop()` body into an async main-actor method and replace `[Float]` assumptions with `CapturedAudio`:

```swift
private func transcribeFinalizedCapture(
    _ captured: CapturedAudio,
    heldFor: TimeInterval,
    releasedAt: Date
) async {
    let samples = captured.samples
    guard micReady else {
        if heldFor >= 0.8 {
            state = .error("No audio from the microphone — try another input in the Echo menu")
            scheduleReturnToIdle()
        } else {
            state = .idle
        }
        return
    }
    guard samples.count >= CaptureConfiguration.default.minimumRecordingSamples else {
        state = .idle
        return
    }

    state = .transcribing
    let duration = captured.duration
    let vocabulary = dictionary?.promptWords ?? []
    do {
        var text = try await transcriber.transcribe(samples, vocabulary: vocabulary)
        for processor in processors { text = processor.process(text) }
        finishExistingTextDelivery(text: text, duration: duration, releasedAt: releasedAt)
    } catch {
        state = .error("Transcription failed: \(error.localizedDescription)")
        scheduleReturnToIdle()
    }
}

private func finishExistingTextDelivery(
    text: String,
    duration: TimeInterval,
    releasedAt: Date
) {
    guard !text.isEmpty else {
        state = .idle
        return
    }
    lastTranscript = text
    if settings.saveHistory { transcripts?.add(text) }

    let frontApp = NSWorkspace.shared.frontmostApplication
    let recordUsage = {
        self.usage?.record(
            words: text.split(whereSeparator: \.isWhitespace).count,
            duration: duration,
            latency: Date().timeIntervalSince(releasedAt),
            appBundleID: frontApp?.bundleIdentifier,
            appName: frontApp?.localizedName
        )
    }
    if inserter.hasInsertionTarget {
        let result = inserter.insert(text)
        recordUsage()
        if result == .copiedToClipboard {
            offerCopy(of: text)
        } else {
            state = .idle
        }
    } else {
        recordUsage()
        offerCopy(of: text)
    }
}
```

This helper is the exact existing delivery behavior extracted without semantic changes; Task 5 will expand its metrics input.

- [ ] **Step 7: Add duplicate-finish coverage, run the full suite, and commit**

Add:

```swift
func testRepeatedReleaseStopsRecorderOnlyOnce() async {
    let controller = makeController()
    controller.activateForTesting()
    recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
    transcriber.result = .success("hello")
    controller.hotkeyPressed()
    controller.hotkeyReleased()
    controller.hotkeyReleased()
    await controller.transcriptionTask?.value
    XCTAssertEqual(recorder.stopCallCount, 1)
}
```

Run and commit:

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git add Echo/Audio/AudioRecorder.swift Echo/DictationController.swift \
  EchoTests/DictationControllerTests.swift EchoTests/CaptureAccumulatorTests.swift
git commit -m "refactor: make audio capture finalization asynchronous"
```

Expected: the full suite PASSes, captured audio is still transcribed and delivered, duplicate release calls stop once, and the commit is independently buildable.

---

### Task 4: Operational Metrics and Backward-Compatible Usage Migration

**Files:**
- Modify: `Echo/Usage/UsageStore.swift`
- Modify: `EchoTests/UsageStoreTests.swift`

**Interfaces:**
- Produces: `DictationOutcome`, `DictationOperationalMetrics`, expanded `UsageStore.record(...)`, and internal additive migration.
- Consumes: no audio samples or transcript text; Task 5 supplies scalar stage values.

- [ ] **Step 1: Write a failing legacy migration test**

In `EchoTests/UsageStoreTests.swift`, create a SQLite database manually using the pre-feature schema, insert one row, then open `UsageStore` and assert existing totals remain unchanged. Use `sqlite3_open`, `sqlite3_exec`, and `sqlite3_close` in a private test helper. Add a new record with metrics and assert totals count both successful rows.

The new API used by the test is:

```swift
store.record(
    words: 3,
    duration: 2,
    latency: 0.5,
    appBundleID: nil,
    appName: nil,
    metrics: DictationOperationalMetrics(
        rawAudioDuration: 2,
        selectedAudioDuration: 1.5,
        finalizationDuration: 0.02,
        trimmingDuration: 0.001,
        transcriptionDuration: 0.45,
        totalLatency: 0.5,
        trimmingApplied: true,
        droppedBufferCount: 0,
        finalizationTimedOut: false,
        modelVariant: "test-model",
        outcome: .success
    )
)
```

- [ ] **Step 2: Run focused usage tests and verify compile failure**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/UsageStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `DictationOperationalMetrics` and the expanded `record` overload do not exist.

- [ ] **Step 3: Add the operational metric model**

At the top of `UsageStore.swift`, add:

```swift
enum DictationOutcome: String, Sendable, Equatable {
    case success
    case noAudio
    case emptyTranscript
    case transcriptionFailure
}

struct DictationOperationalMetrics: Sendable, Equatable {
    let rawAudioDuration: TimeInterval
    let selectedAudioDuration: TimeInterval
    let finalizationDuration: TimeInterval
    let trimmingDuration: TimeInterval
    let transcriptionDuration: TimeInterval?
    let totalLatency: TimeInterval
    let trimmingApplied: Bool
    let droppedBufferCount: Int
    let finalizationTimedOut: Bool
    let modelVariant: String
    let outcome: DictationOutcome
}
```

Keep the existing `latency` and `duration` columns for compatibility with Insights.

- [ ] **Step 4: Implement idempotent additive migration**

After the existing `CREATE TABLE`, call a helper for each missing column:

```swift
private func addColumnIfNeeded(_ definition: String) {
    exec("ALTER TABLE dictations ADD COLUMN \(definition)")
}
```

SQLite returns an error for duplicate columns; ignoring it is idempotent but noisy. Prefer `PRAGMA table_info(dictations)` to collect existing names, then add only these columns:

```text
raw_audio_seconds REAL
selected_audio_seconds REAL
finalization_seconds REAL
trimming_seconds REAL
transcription_seconds REAL
total_latency_seconds REAL
trimming_applied INTEGER
conversion_drop_count INTEGER
finalization_timed_out INTEGER
model_variant TEXT
outcome TEXT
```

Legacy rows have `outcome IS NULL` and are treated as successful.

- [ ] **Step 5: Expand record insertion and preserve old callers**

Add `metrics: DictationOperationalMetrics? = nil` to `record`. Expand the INSERT columns and bindings. Bind null for every new field when metrics is nil. Bind booleans as `0/1` and `outcome.rawValue` as text.

Use this success predicate in all product-facing aggregate queries:

```sql
(outcome IS NULL OR outcome = 'success')
```

Apply it to totals, current-month words, average WPM, per-app words, and daily words so failed operational rows do not inflate user statistics.

- [ ] **Step 6: Add failure-row filtering and privacy tests**

Add a record with `words: 0`, `.transcriptionFailure`, and scalar metrics. Assert:

- `totals().dictations` and words exclude it.
- `averageWPM`, per-app, and daily results remain based on successful/legacy rows.
- `PRAGMA table_info(dictations)` contains only the specified operational columns and no audio/transcript/vocabulary/device columns.

- [ ] **Step 7: Run focused tests and commit**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/UsageStoreTests CODE_SIGNING_ALLOWED=NO
git add Echo/Usage/UsageStore.swift EchoTests/UsageStoreTests.swift
git commit -m "feat: persist privacy-safe transcription metrics"
```

Expected: focused tests PASS and commit succeeds.

---

### Task 5: Controller Composition, Stage Timing, and Behavioral Tests

**Files:**
- Modify: `Echo/DictationController.swift`
- Modify: `EchoTests/DictationControllerTests.swift`

**Interfaces:**
- Consumes: async `AudioRecording.stop()`, `CapturedAudio`, `AudioTrimming`, `TrimmedAudio`, `CaptureConfiguration`, and `DictationOperationalMetrics`.
- Produces: the complete finalization → trimming → WhisperKit → processing/insertion pipeline with unchanged external user behavior.

- [ ] **Step 1: Add trimmer injection and a deterministic mock**

Extend the controller initializer:

```swift
private let captureConfiguration: CaptureConfiguration
private let trimmer: any AudioTrimming

init(
    // existing parameters...
    captureConfiguration: CaptureConfiguration = .default,
    trimmer: any AudioTrimming = VoiceActivityTrimmer(),
    autostart: Bool = true
) {
    self.captureConfiguration = captureConfiguration
    self.trimmer = trimmer
    // existing initialization...
}
```

In tests, add:

```swift
private struct MockTrimmer: AudioTrimming {
    let transform: @Sendable (CapturedAudio) -> TrimmedAudio
    func trim(_ captured: CapturedAudio) -> TrimmedAudio { transform(captured) }
}
```

Change `makeController` to accept a trimmer and pass it through.

- [ ] **Step 2: Write a failing test that proves finalization precedes transcription and selected samples reach the transcriber**

Enhance `MockRecorder` with a continuation gate:

```swift
var suspendsStop = false
private var stopContinuation: CheckedContinuation<CapturedAudio, Never>?

func stop() async -> CapturedAudio {
    stopCallCount += 1
    let captured = makeCapturedAudio()
    guard suspendsStop else { return captured }
    return await withCheckedContinuation { stopContinuation = $0 }
}

func resumeStop() {
    stopContinuation?.resume(returning: makeCapturedAudio())
    stopContinuation = nil
}

private func makeCapturedAudio() -> CapturedAudio {
    CapturedAudio(
        generation: CaptureGeneration(rawValue: UInt64(max(1, stopCallCount))),
        samples: samplesToReturn,
        convertedBufferCount: samplesToReturn.isEmpty ? 0 : 1,
        droppedBufferCount: 0,
        finalizationTimedOut: false,
        finalizationDuration: 0.01,
        sampleRate: CaptureConfiguration.default.sampleRate
    )
}
```

Have `MockTranscriber.transcribe` save `receivedSamples = samples`, then add:

```swift
func testFinalizationCompletesBeforeTrimmedSamplesReachTranscriber() async {
    let selected: [Float] = [0.4, 0.5]
    let trimmer = MockTrimmer { captured in
        TrimmedAudio(
            samples: selected,
            selectedRange: 10..<12,
            leadingSamplesRemoved: 10,
            trailingSamplesRemoved: captured.samples.count - 12,
            trimmingApplied: true,
            fallbackReason: nil
        )
    }
    let controller = makeController(trimmer: trimmer)
    controller.activateForTesting()
    recorder.samplesToReturn = [Float](repeating: 0.1, count: 16_000)
    recorder.suspendsStop = true
    transcriber.result = .success("hello")

    controller.hotkeyPressed()
    controller.hotkeyReleased()
    await Task.yield()
    XCTAssertNil(transcriber.receivedSamples)
    XCTAssertEqual(controller.state, .recording)

    recorder.resumeStop()
    await controller.transcriptionTask?.value
    XCTAssertEqual(transcriber.receivedSamples, selected)
}
```

Run the controller test class and expect FAIL because trimming is not yet composed into the pipeline.

- [ ] **Step 3: Compose trimming into the existing async finalized-capture method**

Keep the single `transcriptionTask` introduced by Task 3. In `transcribeFinalizedCapture`, after validating `micReady` and `captured.samples.count`, set `.transcribing`, then add:

```swift
let trimmer = self.trimmer
let trimmingStarted = Date()
let trimmed = await Task.detached(priority: .userInitiated) {
    trimmer.trim(captured)
}.value
let trimmingDuration = Date().timeIntervalSince(trimmingStarted)
let samples = trimmed.samples
```

Continue with the existing vocabulary and transcription code using `samples`. Do not add a second lifecycle task. The existing `guard case .recording = state, !isFinishingRecording` remains the duplicate-stop guard.

- [ ] **Step 4: Verify trimming stays off the main actor and fallback semantics are preserved**

Add `XCTAssertFalse(Thread.isMainThread)` inside a test trimmer closure and run one dictation. Use `captureConfiguration.minimumRecordingSamples` instead of `AudioRecorder.sampleRate` to validate duration. A fallback already contains original samples, so the controller has no branch that can accidentally submit an empty candidate after a low-confidence result.

- [ ] **Step 5: Time the existing transcription call and record one terminal event**

Capture the model variant before launching work:

```swift
let modelVariant = settings.modelVariant
let transcriptionStarted = Date()
var text = try await transcriber.transcribe(samples, vocabulary: vocabulary)
let transcriptionDuration = Date().timeIntervalSince(transcriptionStarted)
```

Create a private helper that records exactly one terminal event:

```swift
private func recordUsage(
    words: Int,
    captured: CapturedAudio,
    trimmed: TrimmedAudio,
    trimmingDuration: TimeInterval,
    transcriptionDuration: TimeInterval?,
    releasedAt: Date,
    modelVariant: String,
    outcome: DictationOutcome,
    app: NSRunningApplication?
) {
    usage?.record(
        words: words,
        duration: captured.duration,
        latency: Date().timeIntervalSince(releasedAt),
        appBundleID: app?.bundleIdentifier,
        appName: app?.localizedName,
        metrics: DictationOperationalMetrics(
            rawAudioDuration: captured.duration,
            selectedAudioDuration: Double(trimmed.samples.count) / captured.sampleRate,
            finalizationDuration: captured.finalizationDuration,
            trimmingDuration: trimmingDuration,
            transcriptionDuration: transcriptionDuration,
            totalLatency: Date().timeIntervalSince(releasedAt),
            trimmingApplied: trimmed.trimmingApplied,
            droppedBufferCount: captured.droppedBufferCount,
            finalizationTimedOut: captured.finalizationTimedOut,
            modelVariant: modelVariant,
            outcome: outcome
        )
    )
}
```

Call it for `.success`, `.emptyTranscript`, and `.transcriptionFailure`. For sustained no-audio after finalized capture, construct `TrimmedAudio.fallback(captured, reason: .noReliableSpeech)` and record `.noAudio`. Preserve quick-tap behavior but still record no operational row for accidental taps under 0.8 seconds.

Metrics write errors remain internal to `UsageStore` and never change state.

- [ ] **Step 6: Add controller tests for fallback, metrics, and unchanged behavior**

Add focused tests that assert:

- Low-confidence mock trimming sends original samples.
- Confident trimming sends selected samples.
- Empty transcript records `.emptyTranscript` but inserts nothing.
- Transcriber failure records `.transcriptionFailure` and preserves the current error state.
- Successful dictation records raw/selected duration, trimming flag, dropped count, model variant, and timing values.
- Releasing twice or maximum-duration plus release starts only one recorder stop.
- Existing dictionary, snippets, copy fallback, model-switching, and short-recording tests still pass.

Add this internal test query to `UsageStore` under `#if DEBUG` and reconstruct the latest row from the scalar columns only:

```swift
func latestOperationalMetricsForTesting() -> DictationOperationalMetrics? {
    guard let statement = prepare("""
        SELECT raw_audio_seconds, selected_audio_seconds, finalization_seconds,
               trimming_seconds, transcription_seconds, total_latency_seconds,
               trimming_applied, conversion_drop_count, finalization_timed_out,
               model_variant, outcome
        FROM dictations ORDER BY id DESC LIMIT 1
        """) else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let model = columnText(statement, 9),
          let outcomeText = columnText(statement, 10),
          let outcome = DictationOutcome(rawValue: outcomeText) else { return nil }
    return DictationOperationalMetrics(
        rawAudioDuration: sqlite3_column_double(statement, 0),
        selectedAudioDuration: sqlite3_column_double(statement, 1),
        finalizationDuration: sqlite3_column_double(statement, 2),
        trimmingDuration: sqlite3_column_double(statement, 3),
        transcriptionDuration: sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 4),
        totalLatency: sqlite3_column_double(statement, 5),
        trimmingApplied: sqlite3_column_int(statement, 6) != 0,
        droppedBufferCount: Int(sqlite3_column_int64(statement, 7)),
        finalizationTimedOut: sqlite3_column_int(statement, 8) != 0,
        modelVariant: model,
        outcome: outcome
    )
}
```

Do not expose persisted content.

- [ ] **Step 7: Run controller and usage tests**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' \
  -only-testing:EchoTests/DictationControllerTests \
  -only-testing:EchoTests/UsageStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: both test classes PASS.

- [ ] **Step 8: Run the complete suite and commit**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git add Echo/DictationController.swift EchoTests/DictationControllerTests.swift
git commit -m "feat: finalize and trim audio before transcription"
```

Expected: all tests PASS with no source changes left unstaged for this task.

---

### Task 6: Benchmark Protocol and Final Verification

**Files:**
- Create: `docs/benchmarks/transcription-capture-benchmark.md`
- Modify only if verification reveals a defect: files owned by Tasks 1–5

**Interfaces:**
- Consumes: persisted stage metrics and the three benchmark variants defined by the design.
- Produces: a repeatable device validation protocol; no automated upload or audio persistence.

- [ ] **Step 1: Write the benchmark protocol**

Create `docs/benchmarks/transcription-capture-benchmark.md` with:

```markdown
# Transcription Capture Benchmark

## Variants
1. Baseline commit immediately before capture optimization.
2. Deterministic finalization with trimming disabled by injected identity trimmer.
3. Deterministic finalization with `VoiceActivityTrimmer` defaults.

## Devices
- Built-in microphone
- One Bluetooth microphone
- One USB microphone

## Corpus
Use the same locally held, labeled utterances for every variant/device pair:
- 20 short utterances (0.5–2 s)
- 20 normal utterances (3–8 s)
- 20 pause-heavy utterances
- 20 quiet utterances
- 20 noisy utterances
- 10 utterances emphasizing first/last plosives

The corpus and transcripts remain local and are never committed.

## Measurements
Export only aggregate values: WER, CER, first-word omission, last-word omission,
p50/p90/p95/p99 finalization duration, transcription duration, release-to-result
latency, selected/raw duration ratio, conversion-drop count, and finalization timeout count.

## Release gates
- Overall WER and CER do not exceed baseline.
- First-word and last-word omission rates do not exceed baseline.
- Silence-heavy p95 release-to-result latency is lower than baseline.
- No cross-generation contamination occurs in automated tests.
- Normal finalization completes within one conversion cycle; no unexplained timeout remains.
```

- [ ] **Step 2: Run formatting and repository checks**

```bash
git diff --check
rg -n "PLACEHOLDER|INCOMPLETE" Echo EchoTests docs/benchmarks/transcription-capture-benchmark.md
```

Expected: `git diff --check` exits 0; the placeholder scan finds no newly introduced placeholder.

- [ ] **Step 3: Run the complete automated suite twice**

```bash
xcodebuild -scheme Echo test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme Echo test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: both runs PASS. Running twice helps expose generation and timeout ordering flakes.

- [ ] **Step 4: Build the release configuration**

```bash
xcodebuild -scheme Echo -configuration Release build CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Review privacy and scope by source search**

```bash
rg -n "audio|transcript|vocabulary|device" Echo/Usage/UsageStore.swift
rg -n "stream|normalize|denoise|chunk" Echo/Audio Echo/DictationController.swift
```

Expected: usage matches are schema/type descriptions or forbidden-field comments, never persisted content columns; no streaming, normalization, denoising, or chunking implementation was introduced.

- [ ] **Step 6: Commit the benchmark protocol**

```bash
git add docs/benchmarks/transcription-capture-benchmark.md
git commit -m "docs: add transcription capture benchmark protocol"
```

- [ ] **Step 7: Report residual manual validation explicitly**

In the implementation handoff, report:

- Changed files and commit sequence
- Exact test/build commands and exit status
- Automated test count
- Whether any finalization timeout test is timing-sensitive
- Device benchmark status for built-in, Bluetooth, and USB microphones
- WER/CER and p95 results if run
- Any unrun device benchmark as a release risk, not as a passing criterion

Do not claim accuracy or real-device latency improvements until the benchmark corpus has been run.
