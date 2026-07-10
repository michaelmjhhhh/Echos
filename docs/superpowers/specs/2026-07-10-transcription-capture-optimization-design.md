# Transcription Capture Optimization Design

**Date:** 2026-07-10
**Status:** Approved
**Scope:** Deterministic capture finalization, conservative silence trimming, and privacy-safe stage metrics

## 1. Objective

Improve Echo's voice-to-text consistency, accuracy, and release-to-result latency without introducing streaming transcription or changing final text insertion behavior.

The first release prioritizes accuracy safety over maximum latency reduction:

1. Do not increase overall WER/CER.
2. Do not increase first-word or last-word omission rates.
3. Eliminate capture-generation contamination and nondeterministic loss of callbacks that started before recording stopped.
4. Reduce p95 release-to-final-text latency for recordings with leading, trailing, or pause-heavy silence.

## 2. Current behavior and problem

`AudioRecorder` converts microphone buffers to 16 kHz mono Float32 and appends them under an `NSLock`. `stop()` immediately marks capture inactive and snapshots the accumulated samples. A tap callback already processing when `stop()` runs can reach the capture check afterward and be discarded. The outcome depends on callback timing near key release and may omit the final portion of an utterance.

The complete recording, including leading and trailing silence, is then passed to one final WhisperKit decode. Echo has no speech-region trimming or stage-specific timings, so avoidable input duration and boundary failures cannot be measured independently.

## 3. Scope

### Included

- Explicit capture generations
- Asynchronous deterministic recorder finalization
- Bounded handling of in-flight audio callbacks
- Immutable finalized capture output and diagnostics
- Conservative, deterministic voice-activity-based trimming
- Original-audio fallback whenever trimming confidence is insufficient
- Stage-specific, privacy-safe operational metrics
- Unit and integration test seams for recorder, trimmer, controller, and usage migration
- A device benchmark protocol for recognition and latency comparison

### Excluded

- Streaming or provisional transcription
- Automatic end-of-utterance recording control
- Audio normalization, denoising, or enhancement
- Long-recording chunking
- User-adjustable VAD settings
- Transcription cancellation, provider timeout, or stale-result generation IDs outside the capture layer
- Changes to text processing, insertion, clipboard handling, or model selection

## 4. Architecture

### 4.1 `CaptureConfiguration`

A shared internal configuration defines the capture and trimming contract:

- Output sample rate: 16 kHz
- Channel count: mono
- Tap buffer size: 1,024 native input frames
- Minimum usable recording duration: 300 ms
- Analysis frame duration: 20 ms
- Speech onset: three consecutive frames above the start threshold
- Speech-start threshold: the greater of -45 dBFS or 12 dB above the estimated noise floor
- Speech-end threshold: the greater of -50 dBFS or 6 dB above the estimated noise floor
- Pre-roll and post-roll padding: 160 ms each
- Speech-end hangover: 240 ms
- Minimum detected speech interval: 120 ms
- Maximum destructive-trim ratio: 85%
- Finalization time bound: 250 ms

The first release uses internal defaults rather than adding user-facing settings. Recorder and controller logic must consume this configuration instead of duplicating sample-rate or duration assumptions.

### 4.2 `CapturedAudio`

`AudioRecording.stop()` becomes asynchronous and returns an immutable `CapturedAudio` value containing:

- Finalized 16 kHz mono samples
- Capture generation identifier
- Raw sample count and duration
- Converted-buffer count
- Conversion-failure or dropped-buffer count
- Whether bounded finalization elapsed before all registered work completed
- Finalization duration

`CapturedAudio` represents the recorder's complete output. The trimmer must not be embedded into `AudioRecorder`; capture synchronization and speech-region selection remain independently testable.

### 4.3 `VoiceActivityTrimmer`

A pure component accepts finalized samples plus `CaptureConfiguration` and returns a `TrimmedAudio` result containing:

- Samples selected for transcription
- Raw and selected sample counts
- Leading and trailing samples removed
- Whether trimming was applied
- Confidence/fallback classification
- Processing duration recorded by the caller

The algorithm performs linear-time energy analysis over fixed-size frames. It uses distinct speech-start and speech-end thresholds, conservative hangover, and pre/post padding. Where practical, thresholds are interpreted relative to an estimated noise floor rather than relying only on one absolute amplitude.

The same input and configuration must always produce the same result.

### 4.4 Controller responsibility

`DictationController` remains the lifecycle coordinator:

1. Start a capture generation on hotkey press.
2. On release or maximum duration, initiate asynchronous finalization.
3. Await `CapturedAudio` without blocking the main thread.
4. Run trimming outside the main actor.
5. Apply existing minimum-audio rules to usable finalized/selected audio.
6. Invoke the existing final-only WhisperKit decode.
7. Run existing processors and insertion behavior unchanged.
8. Record operational metrics without affecting dictation success.

The state remains `.recording` while the recorder is being finalized, then moves to `.transcribing` before trimming and model inference. No new user-visible state is required in this phase.

## 5. Capture synchronization contract

Each `start()` creates a monotonically distinct capture generation.

An audio callback belongs to the active generation only if it registers before that generation enters the stopping state. The recorder guarantees:

- Work registered before stopping is allowed to finish and is included in finalization.
- Work registering after stopping is rejected.
- A callback for an older generation cannot append to a newer generation.
- Finalization returns exactly once per started generation.
- Repeated `stop()` or invalid lifecycle calls fail safely rather than merging data.
- Waiting is bounded to 250 ms; an overrun snapshots all safely accumulated samples, permanently rejects later output for that generation, and records a diagnostic instead of hanging.

The implementation will use a dedicated serial coordination primitive selected in the implementation plan, and it must not perform an unbounded wait on the main actor. Audio callback work should remain limited to conversion, level calculation, and accumulation. The synchronization design must avoid holding a state lock during expensive conversion or callback delivery.

The existing 45-second warm-engine behavior remains unchanged.

## 6. Trimming policy

The trimmer identifies one bounded region from the first reliable speech onset through the last reliable speech frame. Internal pauses remain intact.

The initial deterministic policy uses the `CaptureConfiguration` defaults: 20 ms frames, three-frame speech onset, 160 ms pre/post padding, and 240 ms speech-end hangover. The noise floor is the 20th-percentile frame RMS expressed in dBFS. Speech starts above the greater of -45 dBFS or noise floor +12 dB and continues above the greater of -50 dBFS or noise floor +6 dB. These values are testable initial hypotheses; changing them before release requires benchmark evidence and an update to the configuration tests.

The original finalized audio is used whenever:

- No reliable speech region is found.
- Speech energy is too quiet or ambiguous.
- The candidate speech interval is implausibly short.
- Trimming would remove an excessive fraction of the recording.
- Input is invalid or internal analysis cannot produce a safe result.

All-silence input is classified as low confidence, retains the original samples, and flows through existing no-audio/empty-transcript behavior. The trimmer must never invent samples, normalize amplitude, remove internal pauses, or alter selected sample values.

## 7. Metrics and persistence

Extend usage persistence through additive nullable columns so existing databases remain valid. Store operational data only:

- Raw audio duration
- Selected audio duration
- Finalization duration
- Trimming duration
- WhisperKit transcription duration
- Total release-to-result latency
- Whether trimming was applied
- Conversion/drop count
- Model variant
- Success/failure classification

Do not persist:

- Audio samples
- Transcript text
- Vocabulary or dictionary entries
- Microphone names or device UIDs

Existing aggregate usage queries must continue to work. New metrics are diagnostic inputs; a metrics calculation or SQLite write failure must never cause an otherwise successful dictation to fail.

## 8. Error handling

- **Low trim confidence:** use the original finalized audio.
- **Trimmer error or invalid result:** use the original finalized audio and record a fallback classification.
- **Individual conversion failure:** increment diagnostics and continue if sufficient audio remains.
- **Finalization bound exceeded:** return safely accumulated audio, mark the overrun, and continue if sufficient audio remains.
- **No usable audio:** preserve the current quick-tap idle behavior and sustained no-microphone error behavior.
- **WhisperKit failure:** preserve the current transcription error behavior.
- **Metrics persistence failure:** ignore it after best-effort logging; do not change the user-visible result.

## 9. Performance constraints

- Finalization must be asynchronous from the controller's perspective.
- Trimming runs outside the main actor.
- Trimming is O(n) in sample count.
- Avoid additional full-buffer copies beyond the immutable final capture and selected transcription payload where possible.
- No additional model inference is introduced.
- Normal finalization overhead should stay near one tap/conversion cycle.

## 10. Testing strategy

### 10.1 Recorder tests

Use controllable callback/conversion seams to verify:

- A callback registered before stopping is included.
- A callback registered after stopping is excluded.
- A delayed old-generation callback cannot contaminate a new generation.
- Repeated start/stop cycles remain isolated.
- Conversion failures and dropped buffers are counted.
- A finalization overrun returns safely accumulated audio.
- Warm-engine behavior still discards samples between generations.

### 10.2 Trimmer tests

Use deterministic synthetic 16 kHz fixtures for:

- Leading and trailing silence with retained padding
- Internal pauses that must remain
- Quiet and ambiguous speech that falls back to original audio
- All-silence input
- Invalid and empty input
- Very short speech bursts and boundary plosives
- Maximum destructive-trim ratio
- Deterministic output for repeated identical inputs

### 10.3 Controller tests

Verify:

- Transcription begins only after capture finalization.
- Confident trimming sends selected samples to the transcriber.
- Fallback sends original samples.
- Existing short-recording and no-audio behavior is preserved.
- Existing processing, history, insertion, copy fallback, and model switching behavior remains unchanged.
- Metrics represent the correct stages and do not persist content.

### 10.4 Usage migration tests

Verify:

- A database created with the old schema opens and migrates without losing rows.
- Existing totals, WPM, per-app, and daily queries still work.
- New nullable fields accept legacy and new records.
- Metrics failures are non-fatal.

### 10.5 Device benchmarks

Compare:

1. Current implementation
2. Deterministic finalization only
3. Deterministic finalization plus conservative trimming

Use identical labeled utterances across built-in, Bluetooth, and USB microphones. Cover short, normal, pause-heavy, quiet, noisy, and long recordings. Record p50/p90/p95/p99 stage latency, WER/CER, first/last-word omission, selected/raw duration ratio, conversion failures, and finalization overruns.

## 11. Acceptance criteria

The implementation is acceptable only when:

- The complete automated test suite passes.
- No callback registered before stop is nondeterministically discarded in recorder tests.
- No old-generation samples appear in a later generation.
- Trimming falls back rather than destructively clipping ambiguous speech.
- Overall WER/CER does not regress on the fixed benchmark corpus.
- First-word and last-word omission rates do not increase.
- p95 release-to-final-text latency decreases for silence-heavy recordings.
- Normal finalization overhead remains bounded near one callback/conversion cycle.
- Existing usage data survives schema migration.
- No audio, transcript, vocabulary, or microphone identity is stored by the new metrics.

## 12. Expected files

Likely implementation locations:

- `Echo/Audio/AudioRecorder.swift`
- `Echo/Audio/CaptureConfiguration.swift`
- `Echo/Audio/CapturedAudio.swift`
- `Echo/Audio/VoiceActivityTrimmer.swift`
- `Echo/DictationController.swift`
- `Echo/Usage/UsageStore.swift`
- `EchoTests/AudioRecorderTests.swift`
- `EchoTests/VoiceActivityTrimmerTests.swift`
- `EchoTests/DictationControllerTests.swift`
- `EchoTests/UsageStoreTests.swift`

`TranscriptionService` remains unchanged; the controller measures duration around its existing async `transcribe` call. Overlay, insertion, dictionary, snippets, and model-selection interfaces are outside this change.
