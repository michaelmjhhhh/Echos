# Post-Transcription Latency Optimization Design

**Date:** 2026-07-12
**Status:** Approved design
**Scope:** Cached text-processing rules, non-blocking history persistence, and coalesced waveform updates

## 1. Objective

Reduce Echo's user-visible release-to-paste latency and recording-time main-thread work without changing transcription, replacement, snippet, insertion, or visible history behavior.

The change targets three verified sources of avoidable work:

1. Dictionary and snippet regular expressions are compiled and applied on the main actor for every dictation.
2. The entire retained history is encoded and atomically written before text insertion.
3. Every audio callback can schedule a waveform update on the main actor.

Success is measured rather than inferred. Echo must show lower p95 release-to-paste latency, lower processor latency under large rule sets, and fewer waveform UI deliveries without behavior regressions.

## 2. Scope

### Included

- Immutable, precompiled dictionary and snippet rule caches
- Cache rebuilding when the owning store mutates
- Text processing outside the main actor
- Immediate in-memory history updates
- Immediate, ordered background history persistence after each mutation
- Text insertion without awaiting history disk I/O
- Waveform update coalescing to approximately 30 Hz
- Privacy-safe timings for processing, insertion, and history persistence
- Unit, integration, and synthetic performance tests

### Excluded

- Changes to WhisperKit inference or model selection
- Vocabulary prompt tuning
- Streaming or chunked transcription
- Audio capture-buffer redesign
- Clipboard transaction changes
- History schema or retention-policy changes
- A new generalized post-transcription pipeline abstraction
- User-facing performance settings

## 3. Architecture and data flow

`DictationController` remains the lifecycle coordinator. The successful result path becomes:

1. WhisperKit returns a transcript.
2. The controller captures immutable snapshots of the current compiled replacement and snippet rules.
3. Text processing runs outside the main actor and returns the final string.
4. The controller inserts the text immediately.
5. The history store updates its in-memory entries and submits an immutable snapshot to a serial persistence actor without blocking insertion.
6. Usage metrics record processing, insertion, and persistence stages independently.

Waveform delivery remains separate from this result path. Audio callbacks calculate levels as they do today, but a coalescer forwards only the latest pending level to the main actor at most once per approximately 33 milliseconds.

The design uses three focused components instead of introducing a broad pipeline abstraction:

- Store-owned compiled processor-rule snapshots
- A serial history persistence actor
- A waveform-level coalescer

## 4. Cached text-processing rules

### 4.1 Ownership and interface

Dictionary and snippet stores own their respective compiled caches. Each cache is an immutable value snapshot whose entries contain:

- The source misspelling or trigger
- The destination word or expansion
- A precompiled case-insensitive whole-word `NSRegularExpression`

The store rebuilds the complete cache after any mutation that can change processing behavior, including add, edit, delete, import, and clear. Snapshots preserve the existing longest-match-first ordering.

Processors accept immutable rule snapshots rather than closures that read main-actor store state during processing. This makes processing safe to execute outside the main actor and ensures one dictation uses one internally consistent rule revision.

### 4.2 Behavioral compatibility

The optimized processors must preserve:

- Case-insensitive whole-word matching
- Longest-match-first rule ordering
- Existing sentence-start capitalization for lowercase dictionary replacements
- Verbatim mixed-case dictionary words
- Standalone snippet matching with trailing punctuation handling
- Literal snippet expansion, including `$` and `\`
- Back-to-front replacement so ranges remain valid

If one rule fails to compile, the cache excludes that rule while retaining all valid rules. The failure should be diagnosable but must not prevent dictation or cache publication.

### 4.3 Concurrency

`DictationController` captures both immutable snapshots on the main actor, then performs processing in user-initiated non-main work. It awaits the transformed text before insertion. Cache mutation cannot change the snapshots used by an in-flight dictation.

## 5. Asynchronous history persistence

### 5.1 Store behavior

`TranscriptStore` remains main-actor isolated for observable UI state. `add()` and `clear()` update `entries` synchronously so history views reflect changes immediately.

After each mutation, the store sends an immutable entries snapshot to a dedicated serial persistence actor. The actor encodes and atomically writes that snapshot outside the main actor. The controller does not await this work before insertion or returning to idle.

This design intentionally saves after every mutation rather than debouncing. It removes disk work from the user-visible critical path while minimizing the crash-loss window.

### 5.2 Ordering

Persistence submissions carry a monotonically increasing revision. The serial actor processes submissions in order and must never allow an older snapshot to overwrite a newer one.

`clear()` uses the same ordered mechanism. A pending pre-clear write therefore cannot restore deleted entries after the cleared snapshot is persisted.

### 5.3 Failure handling

Encoding or disk-write failure does not make insertion fail and does not roll back visible in-memory history. Failures are logged or recorded through privacy-safe diagnostics. A later successful mutation may persist the current complete snapshot.

Initial history loading remains synchronous during store initialization unless measurement identifies startup impact; startup redesign is outside this scope.

## 6. Waveform update coalescing

Audio capture continues to calculate RMS levels in the callback path. A coalescer accepts these values and maintains only the latest pending level.

While recording, it delivers at most one main-actor update every approximately 33 milliseconds, targeting a maximum display rate near 30 Hz. Intermediate values are discarded because they cannot be displayed meaningfully.

Starting a recording creates or resets the delivery generation. Stopping cancels pending delivery and resets the displayed level according to existing UI behavior. A delayed update from an older generation must not appear during a later recording.

Coalescing is observational only. Cancellation, scheduling delay, or update failure must not alter sample capture, recorder finalization, or transcription.

## 7. Metrics

Extend Echo's privacy-safe operational measurements with:

- Text-processing duration
- Text-insertion duration
- History-persistence duration
- Optional waveform levels produced and UI updates delivered

Report p50 and p95 measurements by existing recording-duration buckets where practical. Metrics must not persist transcript text, dictionary rules, snippet content, clipboard content, audio, or microphone identity.

History persistence duration completes asynchronously and therefore must be associated with an operation or revision without delaying the original dictation. A metrics write failure remains non-fatal.

## 8. Error handling

- **Invalid compiled rule:** exclude only that rule, publish the valid cache, and diagnose the failure.
- **Detached processing failure:** preserve the current safe failure behavior; do not insert partially processed text.
- **History encoding/write failure:** preserve in-memory state, do not fail insertion, and diagnose the failure.
- **Out-of-order history submission:** ignore any revision older than the newest accepted revision.
- **Waveform task cancellation:** discard the pending UI update without affecting capture.
- **Stale waveform generation:** reject the update.
- **Metrics failure:** ignore after best-effort diagnosis; do not alter dictation success.

## 9. Testing strategy

### 9.1 Processor tests

Verify:

- Cached processing matches current replacement and snippet output.
- Longest-match ordering remains unchanged.
- Sentence-start capitalization and mixed-case insertion remain correct.
- `$` and `\` remain literal in snippet expansions.
- Standalone snippets retain punctuation behavior.
- Cache rebuilding occurs after add, edit, delete, import, and clear.
- An invalid rule does not suppress valid rules.
- An in-flight snapshot remains internally consistent while a store mutates.
- A synthetic 1,000-rule dictionary and 1,000-rule snippet set provides a repeatable processor-duration baseline.

### 9.2 History tests

Verify:

- `add()` changes visible entries immediately.
- Encoding and writing occur outside the main actor.
- Rapid additions persist the newest complete snapshot.
- A queued older write cannot overwrite a newer write.
- `clear()` cannot be undone by a pending pre-clear write.
- Relaunch loads the expected entries.
- Write failure does not affect insertion success or in-memory entries.

### 9.3 Waveform tests

With a controllable clock or scheduler, verify:

- Frequent level callbacks produce no more than the configured UI delivery rate.
- The latest pending value is eventually delivered while recording.
- Intermediate values are safely discarded.
- Stop and restart cannot leak a stale generation's value.
- Captured samples and finalization output are identical with and without coalescing.

### 9.4 Controller tests

Verify:

- Processing completes before insertion.
- Insertion does not await history disk persistence.
- The inserted value and history value are the same fully processed text.
- Existing empty-transcript, copy fallback, insertion failure, usage, and transcription-error behavior remains intact.

### 9.5 Performance validation

Use fixed inputs and compare the pre-change baseline against the optimized implementation:

- Processor p50 and p95 with small, medium, and maximum-sized rule sets
- Release-to-paste p50 and p95 across short, normal, and pause-heavy recordings
- Main-thread hitch duration during recording and post-transcription processing
- Waveform callbacks produced versus UI updates delivered
- History persistence duration at the 500-entry retention cap

Performance tests should use repeated runs and report distributions rather than one-off timings.

## 10. Acceptance criteria

The implementation is acceptable only when:

- The complete automated test suite passes.
- Replacement and snippet output remains behaviorally identical.
- Visible history updates immediately after successful dictation.
- Insertion does not await history encoding or disk I/O.
- History snapshots remain ordered under rapid add and clear operations.
- Waveform UI delivery remains at or below approximately 30 Hz.
- Waveform coalescing does not change captured audio.
- p95 processor duration improves under the maximum synthetic rule workload.
- p95 release-to-paste latency improves against a fixed local corpus.
- No new persisted user content is introduced.
- Metrics and persistence failures remain non-fatal.

## 11. Expected files

Likely implementation locations include:

- `Echo/DictationController.swift`
- `Echo/Processing/ReplacementProcessor.swift`
- `Echo/Processing/SnippetProcessor.swift`
- `Echo/Dictionary/DictionaryStore.swift`
- `Echo/Snippets/SnippetStore.swift`
- `Echo/History/TranscriptStore.swift`
- `Echo/Audio/AudioRecorder.swift`
- `Echo/Usage/UsageStore.swift`
- Focused new files for compiled rule snapshots, history persistence, or waveform coalescing if those boundaries improve testability
- Corresponding files under `EchoTests/`

Implementation should follow existing project naming and actor-isolation patterns. Unrelated refactoring is explicitly excluded.
