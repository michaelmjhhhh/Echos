# Post-Transcription Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce p95 release-to-paste latency and recording-time main-thread work by caching processor regexes, moving history persistence off the critical path, and coalescing waveform updates to 30 Hz.

**Architecture:** Dictionary and snippet stores publish immutable compiled-rule snapshots consumed by sendable processors off the main actor. `TranscriptStore` keeps observable state on the main actor but submits revisioned snapshots to a serial persistence actor. A generation-aware coalescer limits waveform UI delivery independently of audio capture.

**Tech Stack:** Swift 5.9, macOS 14+, Swift concurrency/actors, Foundation `NSRegularExpression`, Combine, SQLite3, XCTest, XcodeGen/xcodebuild

## Global Constraints

- Preserve transcription, replacement, snippet, insertion, and visible history behavior.
- Preserve longest-match-first rules, capitalization behavior, and literal snippet expansion.
- Insert text without awaiting history encoding or disk I/O.
- Persist every history mutation in revision order; do not debounce.
- Limit waveform UI delivery to approximately 30 Hz without changing captured audio.
- Persist no transcript, dictionary, snippet, clipboard, audio, or microphone content in metrics.
- Metrics and persistence failures must remain non-fatal.
- Do not introduce streaming transcription, audio-buffer redesign, clipboard changes, or a generalized post-transcription pipeline.

## File map

- Create `Echo/Processing/CompiledTextRule.swift`: immutable sendable compiled replacement/snippet rule values.
- Modify `Echo/Processing/ReplacementProcessor.swift`: consume a rule snapshot instead of compiling regexes per call.
- Modify `Echo/Processing/SnippetProcessor.swift`: consume a rule snapshot instead of compiling regexes per call.
- Modify `Echo/Dictionary/DictionaryStore.swift`: rebuild and publish compiled replacement rules after processing-relevant mutations.
- Modify `Echo/Snippets/SnippetStore.swift`: rebuild and publish compiled snippet rules after every mutation.
- Create `Echo/History/HistoryPersistence.swift`: serial, revision-aware snapshot encoding and atomic writes.
- Modify `Echo/History/TranscriptStore.swift`: immediate observable mutation plus unawaited ordered persistence submission.
- Create `Echo/Audio/WaveformLevelCoalescer.swift`: generation-aware, clock-testable 30 Hz delivery.
- Modify `Echo/DictationController.swift`: snapshot/process off-main, insert before history submission, and use waveform coalescing.
- Modify `Echo/Usage/UsageStore.swift`: additive nullable processing/insertion/history timing columns.
- Modify focused files under `EchoTests/`: behavior, ordering, concurrency, migration, and controller integration tests.
- Modify `docs/benchmarks/transcription-capture-benchmark.md`: add the post-transcription comparison procedure and reporting fields.

---

### Task 1: Compile and cache text-processing rules

**Files:**
- Create: `Echo/Processing/CompiledTextRule.swift`
- Modify: `Echo/Processing/ReplacementProcessor.swift`
- Modify: `Echo/Processing/SnippetProcessor.swift`
- Modify: `Echo/Dictionary/DictionaryStore.swift`
- Modify: `Echo/Snippets/SnippetStore.swift`
- Test: `EchoTests/ReplacementProcessorTests.swift`
- Test: `EchoTests/SnippetProcessorTests.swift`
- Test: `EchoTests/DictionaryStoreTests.swift`
- Test: `EchoTests/SnippetStoreTests.swift`

**Interfaces:**
- Produces: `CompiledReplacementRule`, `CompiledSnippetRule`, `DictionaryStore.compiledReplacementRules`, and `SnippetStore.compiledRules`.
- Produces: `ReplacementProcessor(rules:)` and `SnippetProcessor(rules:)`, both safe to use from detached work with immutable snapshots.
- Consumes: Existing normalized store entries and longest-first ordering.

- [ ] **Step 1: Write failing processor tests for immutable precompiled snapshots**

Replace test helpers and add compatibility cases:

```swift
private func replacementProcessor(_ rules: [(String, String)]) -> ReplacementProcessor {
    ReplacementProcessor(rules: rules.compactMap {
        CompiledReplacementRule(misspelling: $0.0, word: $0.1)
    })
}

private func snippetProcessor(_ rules: [(String, String)]) -> SnippetProcessor {
    SnippetProcessor(rules: rules.compactMap {
        CompiledSnippetRule(trigger: $0.0, expansion: $0.1)
    })
}

func testInvalidPatternIsExcludedWithoutDroppingValidRules() {
    let rules = [
        CompiledReplacementRule(misspelling: "eric", word: "Erik"),
        CompiledReplacementRule(misspelling: "", word: "ignored"),
    ].compactMap { $0 }
    XCTAssertEqual(ReplacementProcessor(rules: rules).process("eric"), "Erik")
}

func testRuleSnapshotDoesNotChangeAfterSourceArrayMutation() {
    var source = [("male", "mail")]
    let snapshot = source.compactMap { CompiledReplacementRule(misspelling: $0.0, word: $0.1) }
    let processor = ReplacementProcessor(rules: snapshot)
    source[0] = ("male", "email")
    XCTAssertEqual(processor.process("male"), "Mail")
}
```

Retain every existing behavioral assertion, changing only construction.

- [ ] **Step 2: Run processor tests and verify the new API is missing**

Run:

```bash
xcodegen generate
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/ReplacementProcessorTests \
  -only-testing:EchoTests/SnippetProcessorTests
```

Expected: FAIL because `CompiledReplacementRule`, `CompiledSnippetRule`, and the `rules:` initializers do not exist.

- [ ] **Step 3: Add immutable compiled rule types**

Create `Echo/Processing/CompiledTextRule.swift`:

```swift
import Foundation

struct CompiledReplacementRule: @unchecked Sendable {
    let misspelling: String
    let word: String
    let regex: NSRegularExpression

    init?(misspelling: String, word: String) {
        guard !misspelling.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: misspelling) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.misspelling = misspelling
        self.word = word
        self.regex = regex
    }
}

struct CompiledSnippetRule: @unchecked Sendable {
    let trigger: String
    let expansion: String
    let regex: NSRegularExpression

    init?(trigger: String, expansion: String) {
        guard !trigger.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: trigger) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.trigger = trigger
        self.expansion = expansion
        self.regex = regex
    }
}
```

Document why `@unchecked Sendable` is safe: snapshots are immutable and Foundation documents `NSRegularExpression` as safe for concurrent matching after construction. Do not share mutable match state.

- [ ] **Step 4: Refactor processors to consume compiled rules**

Change the stored properties and loops:

```swift
struct ReplacementProcessor: TextProcessor, Sendable {
    let rules: [CompiledReplacementRule]

    func process(_ text: String) -> String {
        var result = text
        for rule in rules {
            let matches = rule.regex.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: replacement(for: rule.word, at: range, in: result))
            }
        }
        return result
    }
}

struct SnippetProcessor: TextProcessor, Sendable {
    let rules: [CompiledSnippetRule]

    func process(_ text: String) -> String {
        guard !rules.isEmpty else { return text }
        let standalone = standaloneCandidate(text)
        for rule in rules where standalone.caseInsensitiveCompare(rule.trigger) == .orderedSame {
            return rule.expansion
        }
        var result = text
        for rule in rules {
            let matches = rule.regex.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: rule.expansion)
            }
        }
        return result
    }
}
```

Keep the existing private capitalization and standalone-candidate helpers unchanged.

- [ ] **Step 5: Run processor tests and verify behavior passes**

Run the command from Step 2.

Expected: PASS for both processor test classes.

- [ ] **Step 6: Write failing store cache-rebuild tests**

Add tests that capture old and new snapshots around each mutation:

```swift
func testCompiledRulesRebuildAfterAddUpdateAndDelete() throws {
    let store = DictionaryStore(directory: directory, defaults: defaults)
    let added = try XCTUnwrap(try? store.add(word: "Kubernetes", misspelling: "cooper netties").get())
    XCTAssertEqual(ReplacementProcessor(rules: store.compiledReplacementRules).process("cooper netties"), "Kubernetes")

    var edited = added
    edited.misspelling = "cube or netties"
    _ = store.update(edited)
    XCTAssertEqual(ReplacementProcessor(rules: store.compiledReplacementRules).process("cube or netties"), "Kubernetes")

    store.delete(added.id)
    XCTAssertTrue(store.compiledReplacementRules.isEmpty)
}

func testCompiledSnippetRulesRebuildAfterMutations() throws {
    let store = SnippetStore(directory: directory)
    let added = try XCTUnwrap(try? store.add(trigger: "my site", expansion: "example.com").get())
    XCTAssertEqual(SnippetProcessor(rules: store.compiledRules).process("my site"), "example.com")

    var edited = added
    edited.trigger = "my website"
    _ = store.update(edited)
    XCTAssertEqual(SnippetProcessor(rules: store.compiledRules).process("my website"), "example.com")

    store.delete(added.id)
    XCTAssertTrue(store.compiledRules.isEmpty)
}
```

Also add load-time tests by writing entries, creating a new store, and asserting its compiled cache works.

- [ ] **Step 7: Run store tests and verify cache properties are missing**

Run:

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/DictionaryStoreTests \
  -only-testing:EchoTests/SnippetStoreTests
```

Expected: FAIL because the compiled cache properties do not exist.

- [ ] **Step 8: Implement store-owned cache rebuilding**

Add published-read-only internal snapshots and one rebuild method per store:

```swift
private(set) var compiledReplacementRules: [CompiledReplacementRule] = []

private func rebuildCompiledReplacementRules() {
    compiledReplacementRules = replacementRules.compactMap {
        CompiledReplacementRule(misspelling: $0.misspelling, word: $0.word)
    }
}
```

```swift
private(set) var compiledRules: [CompiledSnippetRule] = []

private func rebuildCompiledRules() {
    compiledRules = rules.compactMap {
        CompiledSnippetRule(trigger: $0.trigger, expansion: $0.expansion)
    }
}
```

Call the relevant rebuild method after `load()` in each initializer and immediately after every processing-relevant successful add, update, and delete. `toggleStar` does not rebuild replacement rules because it changes prompt ordering only. There are no import/clear APIs today; any future bulk mutation must call the same rebuild method.

- [ ] **Step 9: Run focused and full tests**

Run:

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/ReplacementProcessorTests \
  -only-testing:EchoTests/SnippetProcessorTests \
  -only-testing:EchoTests/DictionaryStoreTests \
  -only-testing:EchoTests/SnippetStoreTests
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS'
```

Expected: PASS.

- [ ] **Step 10: Commit compiled rule caching**

```bash
git add Echo/Processing/CompiledTextRule.swift \
  Echo/Processing/ReplacementProcessor.swift Echo/Processing/SnippetProcessor.swift \
  Echo/Dictionary/DictionaryStore.swift Echo/Snippets/SnippetStore.swift \
  EchoTests/ReplacementProcessorTests.swift EchoTests/SnippetProcessorTests.swift \
  EchoTests/DictionaryStoreTests.swift EchoTests/SnippetStoreTests.swift Echo.xcodeproj
git commit -m "perf: cache compiled text processing rules"
```

---

### Task 2: Persist history asynchronously in revision order

**Files:**
- Create: `Echo/History/HistoryPersistence.swift`
- Modify: `Echo/History/TranscriptStore.swift`
- Modify: `EchoTests/TranscriptStoreTests.swift`

**Interfaces:**
- Produces: `HistoryPersisting.submit(entries:revision:) async` and `HistoryPersisting.flush() async`.
- Produces: `TranscriptStore.flushPersistenceForTesting() async` for deterministic tests.
- Consumes: Existing `[TranscriptEntry]` snapshots and ISO-8601 JSON format.

- [ ] **Step 1: Write failing persistence-order and immediate-memory tests**

Introduce a spy and async tests:

```swift
actor SpyHistoryPersistence: HistoryPersisting {
    private(set) var submissions: [(Int, [TranscriptEntry])] = []
    var gate: CheckedContinuation<Void, Never>?

    func submit(entries: [TranscriptEntry], revision: Int) async {
        submissions.append((revision, entries))
    }

    func flush() async {}
}

func testAddUpdatesMemoryBeforePersistenceCompletes() async {
    let persistence = SpyHistoryPersistence()
    let store = TranscriptStore(directory: directory, persistence: persistence)
    store.add("hello")
    XCTAssertEqual(store.entries.map(\.text), ["hello"])
    await store.flushPersistenceForTesting()
    XCTAssertEqual(await persistence.submissions.last?.1.map(\.text), ["hello"])
}

func testRapidMutationsPersistNewestSnapshotLast() async {
    let persistence = SpyHistoryPersistence()
    let store = TranscriptStore(directory: directory, persistence: persistence)
    store.add("one")
    store.add("two")
    store.clear()
    await store.flushPersistenceForTesting()
    let revisions = await persistence.submissions.map(\.0)
    XCTAssertEqual(revisions, revisions.sorted())
    XCTAssertEqual(await persistence.submissions.last?.1, [])
}
```

Update existing reload tests to call `await store.flushPersistenceForTesting()` before creating the reloaded store.

- [ ] **Step 2: Run transcript tests and verify the persistence seam is missing**

Run:

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/TranscriptStoreTests
```

Expected: FAIL because `HistoryPersisting`, injection, and flush do not exist.

- [ ] **Step 3: Implement the serial revision-aware persistence actor**

Create `Echo/History/HistoryPersistence.swift`:

```swift
import Foundation

protocol HistoryPersisting: Sendable {
    func submit(entries: [TranscriptEntry], revision: Int) async
    func flush() async
}

actor HistoryPersistence: HistoryPersisting {
    private let fileURL: URL
    private var newestRevision = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func submit(entries: [TranscriptEntry], revision: Int) async {
        guard revision > newestRevision else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            newestRevision = revision
        } catch {
            // Persistence is best effort; a later complete snapshot may succeed.
        }
    }

    func flush() async {}
}
```

Actor serialization guarantees submission order once tasks enter the actor. The store-side task chain in Step 4 guarantees enqueue order; revision rejection is the second safety layer.

- [ ] **Step 4: Refactor `TranscriptStore` to submit snapshots without awaiting**

Add state and injection:

```swift
private let persistence: any HistoryPersisting
private var persistenceRevision = 0
private var persistenceTask: Task<Void, Never>?

init(
    directory: URL? = nil,
    maxEntries: Int = 500,
    persistence: (any HistoryPersisting)? = nil
) {
    // Resolve base and fileURL exactly as today.
    self.persistence = persistence ?? HistoryPersistence(fileURL: fileURL)
    load()
}

private func scheduleSave() {
    persistenceRevision += 1
    let revision = persistenceRevision
    let snapshot = entries
    let previous = persistenceTask
    let persistence = persistence
    persistenceTask = Task {
        await previous?.value
        await persistence.submit(entries: snapshot, revision: revision)
    }
}

func flushPersistenceForTesting() async {
    await persistenceTask?.value
    await persistence.flush()
}
```

Replace synchronous `save()` calls in `add()` and `clear()` with `scheduleSave()`. Remove the old synchronous `save()` method. Keep `load()` and all observable mutations on the main actor.

- [ ] **Step 5: Run transcript tests and verify all pass**

Run the command from Step 2.

Expected: PASS, including reload only after explicit flush.

- [ ] **Step 6: Add a real-writer clear-order regression test**

```swift
func testClearCannotBeOverwrittenByOlderPendingWrite() async {
    let store = TranscriptStore(directory: directory)
    for index in 0..<100 { store.add("entry \(index)") }
    store.clear()
    await store.flushPersistenceForTesting()
    let reloaded = TranscriptStore(directory: directory)
    XCTAssertTrue(reloaded.entries.isEmpty)
}
```

Run the focused test repeatedly:

```bash
for i in {1..10}; do
  xcodebuild test -quiet -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
    -only-testing:EchoTests/TranscriptStoreTests/testClearCannotBeOverwrittenByOlderPendingWrite || exit 1
done
```

Expected: ten PASS results.

- [ ] **Step 7: Commit asynchronous history persistence**

```bash
git add Echo/History/HistoryPersistence.swift Echo/History/TranscriptStore.swift \
  EchoTests/TranscriptStoreTests.swift Echo.xcodeproj
git commit -m "perf: move history persistence off main actor"
```

---

### Task 3: Coalesce waveform level delivery to 30 Hz

**Files:**
- Create: `Echo/Audio/WaveformLevelCoalescer.swift`
- Create: `EchoTests/WaveformLevelCoalescerTests.swift`
- Modify: `Echo/DictationController.swift`
- Modify: `EchoTests/DictationControllerTests.swift`

**Interfaces:**
- Produces: `WaveformLevelCoalescer.start()`, `submit(_:)`, and `stop()`.
- Consumes: Recorder `onLevel` values in `0...1` and a main-actor delivery closure.

- [ ] **Step 1: Write failing clock-independent coalescer tests**

Use an injected sleeper so tests do not depend on wall time:

```swift
actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func sleep() async { await withCheckedContinuation { continuations.append($0) } }
    func advance() { continuations.removeFirst().resume() }
}

@MainActor
func testBurstDeliversOnlyLatestLevel() async {
    let sleeper = ControlledSleeper()
    var delivered: [Float] = []
    let sut = WaveformLevelCoalescer(
        sleep: { await sleeper.sleep() },
        deliver: { delivered.append($0) }
    )
    sut.start()
    sut.submit(0.1)
    sut.submit(0.4)
    sut.submit(0.9)
    await sleeper.advance()
    await Task.yield()
    XCTAssertEqual(delivered, [0.9])
}

@MainActor
func testStoppedGenerationCannotDeliverIntoRestart() async {
    let sleeper = ControlledSleeper()
    var delivered: [Float] = []
    let sut = WaveformLevelCoalescer(sleep: { await sleeper.sleep() }, deliver: { delivered.append($0) })
    sut.start()
    sut.submit(0.8)
    sut.stop()
    sut.start()
    await sleeper.advance()
    await Task.yield()
    XCTAssertTrue(delivered.isEmpty)
}
```

- [ ] **Step 2: Run coalescer tests and verify the type is missing**

Run:

```bash
xcodegen generate
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/WaveformLevelCoalescerTests
```

Expected: FAIL because `WaveformLevelCoalescer` does not exist.

- [ ] **Step 3: Implement the generation-aware main-actor coalescer**

Create `Echo/Audio/WaveformLevelCoalescer.swift`:

```swift
import Foundation

@MainActor
final class WaveformLevelCoalescer {
    typealias Sleep = @Sendable () async -> Void

    private let sleep: Sleep
    private let deliver: (Float) -> Void
    private var generation = 0
    private var latest: Float?
    private var deliveryTask: Task<Void, Never>?
    private var active = false

    init(
        interval: Duration = .milliseconds(33),
        sleep: Sleep? = nil,
        deliver: @escaping (Float) -> Void
    ) {
        self.sleep = sleep ?? { try? await Task.sleep(for: interval) }
        self.deliver = deliver
    }

    func start() {
        generation += 1
        active = true
        latest = nil
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    nonisolated func submit(_ level: Float) {
        Task { @MainActor [weak self] in self?.accept(level) }
    }

    func stop() {
        generation += 1
        active = false
        latest = nil
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func accept(_ level: Float) {
        guard active else { return }
        latest = level
        guard deliveryTask == nil else { return }
        let scheduledGeneration = generation
        deliveryTask = Task { [weak self, sleep] in
            await sleep()
            guard let self, !Task.isCancelled,
                  self.active, self.generation == scheduledGeneration,
                  let level = self.latest else { return }
            self.latest = nil
            self.deliveryTask = nil
            self.deliver(level)
        }
    }
}
```

If Swift isolation diagnostics reject the default closure capture, move default sleeper construction into a nonisolated static helper while preserving this public interface.

- [ ] **Step 4: Run coalescer tests and verify pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Integrate the coalescer with controller lifecycle**

Add:

```swift
private lazy var waveformCoalescer = WaveformLevelCoalescer { [weak self] level in
    self?.audioLevel = level
}
```

Replace the recorder callback with:

```swift
self.recorder.onLevel = { [weak self] level in
    self?.waveformCoalescer.submit(level)
}
```

Call `waveformCoalescer.start()` and reset `audioLevel = 0` when a recording successfully starts. Call `waveformCoalescer.stop()` and reset `audioLevel = 0` on every recording completion, cancellation, quick-tap exit, and error path that leaves `.recording`.

- [ ] **Step 6: Add controller lifecycle regression tests**

Use the production 33 ms interval and wait 50 ms so a stale scheduled delivery has time to attempt execution:

```swift
func testStoppedRecordingRejectsLateWaveformLevel() async {
    let controller = makeController()
    controller.activateForTesting()
    controller.hotkeyPressed()
    recorder.onLevel?(0.9)
    controller.hotkeyReleased()
    await controller.transcriptionTask?.value
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.audioLevel, 0)
    XCTAssertEqual(transcriber.receivedSamples, recorder.samplesToReturn)
}
```

The sample assertion proves waveform delivery does not participate in capture accumulation.

- [ ] **Step 7: Run focused and full tests**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/WaveformLevelCoalescerTests \
  -only-testing:EchoTests/DictationControllerTests
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS'
```

Expected: PASS.

- [ ] **Step 8: Commit waveform coalescing**

```bash
git add Echo/Audio/WaveformLevelCoalescer.swift Echo/DictationController.swift \
  EchoTests/WaveformLevelCoalescerTests.swift EchoTests/DictationControllerTests.swift Echo.xcodeproj
git commit -m "perf: coalesce waveform updates"
```

---

### Task 4: Move processing off-main and insert before history submission

**Files:**
- Modify: `Echo/DictationController.swift`
- Modify: `EchoTests/DictationControllerTests.swift`

**Interfaces:**
- Consumes: `DictionaryStore.compiledReplacementRules`, `SnippetStore.compiledRules`, and asynchronous `TranscriptStore.add` persistence behavior.
- Produces: One immutable sendable processing pipeline snapshot per dictation.

- [ ] **Step 1: Write failing ordering and snapshot tests**

Add event recording to the mocks and assert the critical sequence:

```swift
func testInsertionOccursBeforeHistoryPersistenceCompletes() async {
    let persistence = BlockingHistoryPersistence()
    let transcripts = TranscriptStore(directory: directory, persistence: persistence)
    let controller = makeController(transcripts: transcripts)
    controller.activateForTesting()
    recorder.samplesToReturn = [Float](repeating: 0.1, count: 16_000)
    transcriber.result = .success("hello")

    controller.hotkeyPressed()
    controller.hotkeyReleased()
    await controller.transcriptionTask?.value

    XCTAssertEqual(inserter.insertedText, "hello")
    XCTAssertEqual(transcripts.entries.map(\.text), ["hello"])
    XCTAssertFalse(await persistence.didFinish)
}
```

Add a test that mutates a dictionary after the controller snapshots rules but before detached processing completes; the current dictation must use the original snapshot and the next dictation the new snapshot.

- [ ] **Step 2: Run controller tests and verify ordering/snapshot tests fail**

Run:

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/DictationControllerTests
```

Expected: FAIL because the controller still owns provider-based processors and adds history before insertion.

- [ ] **Step 3: Replace stored provider processors with snapshot assembly**

Keep caller-supplied generic processors on the main actor, but capture compiled store rules and run the expensive cached regex stages off-main:

```swift
private let baseProcessors: [TextProcessor]
private let snippets: SnippetStore?

private func processTranscript(_ input: String) async -> String {
    var cleaned = input
    for processor in baseProcessors {
        cleaned = processor.process(cleaned)
    }
    let replacementRules = dictionary?.compiledReplacementRules ?? []
    let snippetRules = snippets?.compiledRules ?? []
    return await Task.detached(priority: .userInitiated) {
        var result = ReplacementProcessor(rules: replacementRules).process(cleaned)
        result = SnippetProcessor(rules: snippetRules).process(result)
        return result
    }.value
}
```

In initialization, store `processors` as `baseProcessors`, store `snippets`, and remove provider-based processor construction. In the transcription path replace the processor loop with:

```swift
let processingStarted = ContinuousClock.now
text = await processTranscript(text)
let processingDuration = processingStarted.duration(to: .now).timeInterval
```

Use a small `Duration.timeInterval` helper if the project lacks one.

- [ ] **Step 4: Reorder insertion and history mutation**

After setting `lastTranscript`, perform insertion/copy fallback first. Once insertion has synchronously returned, call:

```swift
if settings.saveHistory {
    transcripts?.add(text)
}
```

Do not await history persistence. Preserve current copy fallback and state transitions exactly.

- [ ] **Step 5: Run controller and processor tests**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/DictationControllerTests \
  -only-testing:EchoTests/ReplacementProcessorTests \
  -only-testing:EchoTests/SnippetProcessorTests
```

Expected: PASS.

- [ ] **Step 6: Commit controller critical-path changes**

```bash
git add Echo/DictationController.swift EchoTests/DictationControllerTests.swift
git commit -m "perf: shorten post-transcription critical path"
```

---

### Task 5: Add privacy-safe stage metrics and benchmark protocol

**Files:**
- Modify: `Echo/Usage/UsageStore.swift`
- Modify: `Echo/DictationController.swift`
- Modify: `EchoTests/UsageStoreTests.swift`
- Modify: `EchoTests/DictationControllerTests.swift`
- Modify: `docs/benchmarks/transcription-capture-benchmark.md`

**Interfaces:**
- Extends: `DictationOperationalMetrics` with nullable `processingDuration`, `insertionDuration`, and `historyPersistenceDuration`.
- Extends: SQLite `dictations` with nullable `processing_seconds`, `insertion_seconds`, and `history_persistence_seconds`.
- Consumes: Controller stage timings; no content values.

- [ ] **Step 1: Write failing migration and round-trip tests**

Extend the test fixture:

```swift
let metrics = DictationOperationalMetrics(
    rawAudioDuration: 1.0,
    selectedAudioDuration: 0.8,
    finalizationDuration: 0.01,
    trimmingDuration: 0.002,
    transcriptionDuration: 0.45,
    processingDuration: 0.012,
    insertionDuration: 0.006,
    historyPersistenceDuration: nil,
    totalLatency: 0.49,
    trimmingApplied: true,
    droppedBufferCount: 0,
    finalizationTimedOut: false,
    modelVariant: "base",
    outcome: .success
)
```

Update the operational metrics query assertion to expect `0.012`, `0.006`, and `nil`. Add a legacy-schema migration test that creates the pre-change table, initializes `UsageStore`, and verifies the three columns with `PRAGMA table_info(dictations)`.

- [ ] **Step 2: Run usage tests and verify new fields are missing**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/UsageStoreTests
```

Expected: FAIL because the fields and columns do not exist.

- [ ] **Step 3: Add nullable schema columns and bindings**

Extend `DictationOperationalMetrics`:

```swift
let processingDuration: TimeInterval?
let insertionDuration: TimeInterval?
let historyPersistenceDuration: TimeInterval?
```

Add idempotent migration statements alongside existing operational columns:

```swift
addColumnIfNeeded("processing_seconds", definition: "REAL")
addColumnIfNeeded("insertion_seconds", definition: "REAL")
addColumnIfNeeded("history_persistence_seconds", definition: "REAL")
```

Extend INSERT column names, placeholders, and bind positions. Extend the internal operational metrics query/test helper in the same order. Bind `nil` as SQLite NULL. Do not persist text or rule identifiers.

- [ ] **Step 4: Run usage tests and verify migration/round-trip pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Measure processing and insertion in the controller**

Use `ContinuousClock` around `processTranscript` and `inserter.insert`. Pass those durations through every success/empty/failure `recordUsage` call where available. Use `nil` when a stage did not run.

History persistence is asynchronous. For this phase, record `historyPersistenceDuration: nil` in the dictation row rather than delaying insertion or introducing a second-row update. Measure actual persistence duration inside `HistoryPersistence` with privacy-safe logging/signposting; a later aggregate schema can associate it by revision if product reporting requires it. Document this intentional limitation in the benchmark file.

- [ ] **Step 6: Add controller metric assertions**

Update the usage spy to retain metrics and assert:

```swift
XCTAssertNotNil(usage.lastMetrics?.processingDuration)
XCTAssertNotNil(usage.lastMetrics?.insertionDuration)
XCTAssertNil(usage.lastMetrics?.historyPersistenceDuration)
XCTAssertGreaterThanOrEqual(usage.lastMetrics?.processingDuration ?? -1, 0)
XCTAssertGreaterThanOrEqual(usage.lastMetrics?.insertionDuration ?? -1, 0)
```

Retain assertions that no transcript content is stored in operational metrics.

- [ ] **Step 7: Extend the benchmark protocol**

Add a “Post-transcription latency variant” section to `docs/benchmarks/transcription-capture-benchmark.md` specifying:

```markdown
## Post-transcription latency comparison

Compare the commit before this optimization with the optimized build using:

- 0, 100, and 1,000 dictionary replacement rules
- 0, 100, and 1,000 snippet rules
- History files containing 0, 250, and 500 entries
- Identical short, normal, and pause-heavy utterances

Report p50 and p95 processing, insertion, history-persistence, and release-to-paste duration. Record waveform callbacks produced and UI updates delivered during 30-second captures. The optimized build passes only if p95 processor and release-to-paste duration improve at maximum rule/history size, waveform delivery stays at or below approximately 30 Hz, and output text remains identical.
```

- [ ] **Step 8: Run the complete verification suite**

```bash
xcodegen generate
git diff --check
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS'
xcodebuild build -project Echo.xcodeproj -scheme Echo -configuration Release -destination 'platform=macOS'
```

Expected: all commands exit 0. Benchmark claims remain pending until the local device corpus is actually run; do not claim measured improvement from unit tests alone.

- [ ] **Step 9: Commit metrics and benchmark documentation**

```bash
git add Echo/Usage/UsageStore.swift Echo/DictationController.swift \
  EchoTests/UsageStoreTests.swift EchoTests/DictationControllerTests.swift \
  docs/benchmarks/transcription-capture-benchmark.md Echo.xcodeproj
git commit -m "perf: measure post-transcription latency stages"
```

---

## Final verification and review

- [ ] **Step 1: Confirm the working tree contains only expected files**

```bash
git status --short
git log --oneline -6
```

Expected: no tracked modifications; unrelated `.pi-subagents/artifacts/` files may remain untracked and must not be committed.

- [ ] **Step 2: Run focused regression tests once more**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
  -only-testing:EchoTests/ReplacementProcessorTests \
  -only-testing:EchoTests/SnippetProcessorTests \
  -only-testing:EchoTests/DictionaryStoreTests \
  -only-testing:EchoTests/SnippetStoreTests \
  -only-testing:EchoTests/TranscriptStoreTests \
  -only-testing:EchoTests/WaveformLevelCoalescerTests \
  -only-testing:EchoTests/DictationControllerTests \
  -only-testing:EchoTests/UsageStoreTests
```

Expected: PASS.

- [ ] **Step 3: Perform an Instruments/manual validation pass**

On one fixed local corpus and the maximum synthetic rule/history fixture:

1. Capture Time Profiler and Main Thread Checker traces before and after.
2. Export p50/p95 processing and release-to-paste timings.
3. Verify history persistence occurs after insertion and outside the main actor.
4. Verify waveform main-actor deliveries stay at or below approximately 30 Hz.
5. Compare inserted outputs byte-for-byte.

Expected: acceptance criteria in the design are met. If p95 does not improve, retain correctness fixes but do not claim a performance gain; inspect signposts before further optimization.
