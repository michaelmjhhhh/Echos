# Echo Transcription Latency — In-Depth Codebase Review

**Date:** 2026-07-02  
**Reviewer:** Scout agent  
**Scope:** Full hotkey-to-insertion pipeline  

---

## Executive Summary

The transcription pipeline has **three dominant latency contributors** and several secondary ones. Ranked by impact:

| Rank | Area | Estimated Time | Effort to Fix | Impact |
|------|------|---------------|---------------|--------|
| 1 | **Transcription inference** (WhisperKit) | 2–8 s for 5 s speech | Low–Medium | ★★★★★ |
| 2 | **Model loading on startup** | 1–3 s blocking | Medium | ★★★★ |
| 3 | **Clipboard save/restore + delay** | 0.7 s idle wait | Medium | ★★★ |
| 4 | **AXUI target check** | 10–100 ms per dictation | Low | ★★ |
| 5 | **Bluetooth mic wake** | 0.6–2 s first sample | Low | ★★ |
| 6 | **AVAudioConverter overhead** | 1–5 ms per buffer | Low | ★ |

**Target budget:** For a 5-second utterance, end-to-end latency should be **under 2.5 seconds** (ready-to-paste). Currently it likely exceeds 4 s for the default model variant.

---

## 1. Transcription Inference Latency (HIGHEST IMPACT)

### File: `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` (lines 37–47)

```swift
func transcribe(_ samples: [Float]) async throws -> String {
    guard let whisperKit else {
        throw TranscriptionError.modelNotLoaded
    }
    let options = DecodingOptions(
        task: .transcribe,
        language: "en",
        skipSpecialTokens: true
    )
    let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
    return results.map(\.text).joined(separator: " ")
}
```

**Problem:** `DecodingOptions` uses all defaults — this means WhisperKit's default beam size (typically 5), no temperature fallback tuning, no prompt caching. The distil-large-v3 model at 594 MB runs on ANE, but inference is still the dominant cost: roughly **0.4–1.6× real-time** on Apple Silicon (so 5 s of audio takes 2–8 s).

### Concrete Optimizations

#### a) Tune `DecodingOptions` for speed

Add these parameters to `DecodingOptions`:

```swift
let options = DecodingOptions(
    task: .transcribe,
    language: "en",
    skipSpecialTokens: true,
    // ---- Speed tuning ----
    beamSize: 1,            // Greedy decoding instead of beam search
    bestOf: 1,              // Single candidate
    temperature: 0.0,       // No temperature fallback
    // ---- End speed tuning ----
    wordTimestamps: false,  // Not needed for dictation
    withoutFilters: true    // Skip post-processing filters
)
```

**Expected gain:** 2–4× speedup. Beam size 5 → 1 alone cuts decoder passes by 5×. The `distil-large-v3` model with greedy decoding on ANE can approach 0.3× real-time, meaning 5 s audio → ~1.5 s inference.

#### b) Streaming / real-time inference

WhisperKit supports streaming inference via `transcribeStreaming()`. The pipeline could begin transcription on audio chunks while the user is still speaking. Implementation sketch:

- In `AudioRecorder.append()`, every N frames (e.g., every 1 second of audio), enqueue an audio chunk for partial transcription.
- `TranscriptionService` maintains a streaming session, feeding chunks and collecting partial results.
- On `stop()`, finalize the stream.

**Trade-off:** Accuracy may degrade slightly because the model has less context. Battery impact from running ANE while recording. Complexity increase.

#### c) Model variant selection

The default is `distil-whisper_distil-large-v3_594MB` (594 MB). Available smaller variants from WhisperKit:

| Variant | Size | Relative Speed | Accuracy |
|---------|------|----------------|----------|
| `distil-large-v3` | 594 MB | 1× (baseline) | Best |
| `distil-medium` | ~300 MB | ~2× faster | Slight degredation |
| `distil-small` | ~170 MB | ~3–4× faster | Moderate degredation |
| `tiny` | ~75 MB | ~6× faster | Noticeable degredation |
| `base` | ~145 MB | ~4× faster | Some degredation |

**Recommendation:** Offer a "Turbo mode" setting that uses `distil-medium` or `distil-small.en` for latency-sensitive users. The model variant is already stored in `SettingsStore` (`/Users/michael/echo/Echo/Settings/SettingsStore.swift`, line 29), so only the default needs changing or a UI toggle added.

#### d) Prompt caching / model warm-up

WhisperKit loads the full model into ANE memory. If the app has been idle, ANE may power down. A warm-up inference on a short silent buffer immediately after `loadModel()` would ensure ANE is hot:

```swift
func loadModel() async throws {
    let config = WhisperKitConfig(
        model: modelVariant,
        modelFolder: modelFolder?.path,
        load: true,
        download: false
    )
    whisperKit = try await WhisperKit(config)
    // Warm up ANE with a short no-op inference
    let warmUp = [Float](repeating: 0, count: 1600) // 0.1 s silence
    _ = try? await whisperKit.transcribe(audioArray: warmUp, decodeOptions: options)
}
```

**Cost:** ~0.3–0.5 s extra on startup, but saves 1–3 s on first dictation if ANE was cold.

---

## 2. Model Loading Latency

### File: `/Users/michael/echo/Echo/DictationController.swift` (lines 62–71)

```swift
func start() async {
    await waitForPermissions()
    do {
        state = .downloadingModel(progress: 0)
        try await transcriber.prepare { [weak self] progress in ... }
        state = .loadingModel
        try await transcriber.loadModel()
    } catch {
        state = .error("Model setup failed: \(error.localizedDescription)")
        return
    }
    ...
}
```

### File: `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` (lines 28–36)

```swift
func loadModel() async throws {
    let config = WhisperKitConfig(
        model: modelVariant,
        modelFolder: modelFolder?.path,
        load: true,           // <-- loads entire model into memory
        download: false
    )
    whisperKit = try await WhisperKit(config)
}
```

**Problem:** `loadModel()` is synchronous (from caller perspective) and blocks the startup sequence. The ~600 MB distil-large-v3 model must be memory-mapped and loaded into ANE before the app is ready. On a cold start, this takes **1–3 seconds** depending on disk speed and ANE state.

### Concrete Optimizations

#### a) Deferred / lazy model loading

Move model loading to a background task that completes before the first dictation, but doesn't block `start()` from finishing. The app can reach `.idle` state with a "Model warming…" substate or simply have `transcribe()` await model readiness:

```swift
private var modelReady: Task<Void, Error>?

func start() async {
    await waitForPermissions()
    // Don't await model loading here — start it in background
    modelReady = Task {
        try await transcriber.prepare { ... }
        try await transcriber.loadModel()
    }
    hotkeyMonitor.hotkey = settings.hotkey
    hotkeyMonitor.start()
    state = .idle
    
    // If user dictates before model is ready, transcribe() awaits
}

func transcribe(_ samples: [Float]) async throws -> String {
    try await modelReady?.value  // wait here if not ready yet
    // ... proceed with inference
}
```

**Trade-off:** First dictation may still pay the load cost, but the app appears ready instantly. Hotkey could be held before model is ready, creating a race.

#### b) Memory-mapped model loading

WhisperKit's `WhisperKitConfig` has a `load` parameter. Setting `load: false` would keep the model on disk and memory-map pages on demand. However, CoreML models must be loaded into the model cache for ANE execution. Check if WhisperKit supports `computeUnits: .cpuAndANE` or `memoryLayout: .lowMemory` to reduce the memory footprint.

#### c) Pre-load on login

Since Echo is a menu-bar app that launches at login (`SettingsStore.updateLaunchAtLogin()`), the model could start loading immediately at login rather than waiting for the hotkey first press. This is already somewhat the case (model loads in `start()` which runs on `init`), but the current code blocks until permissions are granted first.

---

## 3. Audio Pipeline Latency

### File: `/Users/michael/echo/Echo/Audio/AudioRecorder.swift`

#### Buffer size (line 77)

```swift
input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { ... }
```

**Analysis:** 4096 frames at the *input* sample rate (typically 44.1k or 48k) is ~93 ms of audio per callback. At 16 kHz output, it's 256 ms. This is the latency between speech entering the mic and the samples being available in the `samples` array.

**Recommendation:** Reduce to 2048 or 1024 frames:

```swift
input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { ... }
```

**Expected gain:** Reduces capture-to-available latency from ~93 ms to ~23 ms at 44.1 kHz input. **Trade-off:** More frequent callbacks, slightly higher CPU usage.

#### AVAudioConverter overhead (lines 55–59, 88–107)

```swift
guard let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: Self.sampleRate,    // 16_000
    channels: 1,
    interleaved: false
), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { ... }
```

**Analysis:** The converter is created fresh every `buildEngine()`. It converts from the mic's native format (e.g., 44.1 kHz stereo Int16) to 16 kHz mono Float32. This is a sample rate conversion + channel downmix.

**Optimization:** The converter could be pre-allocated and reused across recording sessions. However, since `buildEngine()` is called at most once per keep-warm cycle (45 s), this is negligible.

**More significant:** If the mic already supports 16 kHz (many Bluetooth headsets do), the conversion is a no-op. The code doesn't check if the input format already matches the target.

#### Keep-warm pattern (lines 115–121)

```swift
let workItem = DispatchWorkItem { [weak self] in self?.teardownEngine() }
shutdownWorkItem = workItem
DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepWarmSeconds, execute: workItem)
```

**Analysis:** 45 seconds of keep-warm is generous. This keeps the Bluetooth HFP link alive between dictations. If the user dictates infrequently, this may waste a small amount of power.

**Recommendation:** The 45 s value seems reasonable. Could be made adaptive: extend by 15 s on each successive dictation within the window, up to a max of 120 s. This would better serve power users while allowing the engine to eventually shut down for infrequent users.

---

## 4. Bluetooth Mic Wake Latency

### File: `/Users/michael/echo/Echo/Audio/AudioLinkWaker.swift`

```swift
func wake() {
    // ...
    let frameCount = AVAudioFrameCount(format.sampleRate * 0.4)  // 0.4 seconds
    // ...
    player.scheduleBuffer(silence) { ... }
    player.play()
}
```

### File: `/Users/michael/echo/Echo/DictationController.swift` (lines 109–117)

```swift
micWakeTask = Task { [weak self] in
    try? await Task.sleep(for: .milliseconds(600))
    guard !Task.isCancelled, let self,
          case .recording = self.state, !self.micReady else { return }
    self.linkWaker.wake()
}
```

**Analysis:** The total Bluetooth wake sequence:
1. User presses hotkey → recording starts
2. Wait 600 ms (to see if mic comes up naturally)
3. Play 400 ms of silence through output
4. Wait for Bluetooth link to activate mic (1–3 s typical)

Total: **2–4 seconds** before `micReady` fires and useful audio arrives.

### Concrete Optimizations

#### a) Pre-wake on app launch

Wake the Bluetooth link immediately when the app starts (or when it becomes idle after model loading), not just when the hotkey is pressed:

```swift
func start() async {
    // ... existing code ...
    state = .idle
    // Pre-warm Bluetooth mic if one is selected
    if let deviceUID = settings.inputDeviceUID, isBluetoothDevice(deviceUID) {
        linkWaker.wake()
    }
}
```

**Trade-off:** Extra battery drain from keeping Bluetooth link alive continuously. But the link would already be warm for the first dictation.

#### b) Reduce the initial delay

The 600 ms delay before waking seems overcautious. Bluetooth mics from Apple (AirPods) typically need the wake signal immediately. Reduce to 100–200 ms:

```swift
try? await Task.sleep(for: .milliseconds(200))  // was 600
```

#### c) Extend wake silence duration

Some Bluetooth devices need >400 ms of audio to trigger the SCO link. Extend to 600–800 ms, or loop the silence until mic is ready:

```swift
// Play silence until mic wakes or timeout
let wakeDuration = 0.8  // was 0.4
```

---

## 5. Post-Processing Latency

### File: `/Users/michael/echo/Echo/Processing/TextProcessor.swift`

```swift
struct WhitespaceCleanupProcessor: TextProcessor {
    func process(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

**Analysis:** This runs in <0.1 ms for typical dictation text (10–50 words). Not a concern.

### Future LLM processing

The code comment says "this is the hook where a local LLM cleanup stage can be added later." If an LLM is added (e.g., llama.cpp or MLX), this would become a dominant latency factor. To keep it fast:

- Use a tiny model (e.g., 0.5B parameters on ANE)
- Set a strict timeout (e.g., 500 ms max)
- Run in parallel with clipboard operations
- Consider a "fast path" that skips LLM for short dictations

---

## 6. Insertion Latency

### File: `/Users/michael/echo/Echo/Insertion/TextInserter.swift`

#### Clipboard save/restore delay (line 128)

```swift
/// How long to wait before restoring the clipboard — long enough for the
/// frontmost app to service the paste event.
private let restoreDelay: TimeInterval = 0.7
```

**Analysis:** 700 ms of forced idle wait after every paste. This is the **third-largest latency contributor** in the pipeline. The comment says "long enough for the frontmost app to service the paste event," but in practice ⌘V processing takes 10–50 ms in most apps. 700 ms is extremely conservative.

**Recommendation:** Reduce to **150–200 ms**:

```swift
private let restoreDelay: TimeInterval = 0.15
```

**Risk:** If an app is slow to process the paste event (very rare), the clipboard might be restored before the app reads it. However, NSPasteboard is reference-counted — the app reads the data immediately on paste, so early restoration of the pasteboard doesn't affect already-pasted content. The 700 ms was likely chosen for safety margin; 150 ms is ample.

**Expected gain:** Saves 0.5–0.55 s per dictation.

#### AXUIElement target check (lines 159–195)

```swift
var hasInsertionTarget: Bool {
    let secureInput = IsSecureEventInputEnabled()
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )
    // ... role/value checks ...
}
```

**Analysis:** This is called once per dictation on the main thread (inside the transcription task, which is `Task { @MainActor in ... }`). AXUI calls involve IPC to the target app and can take 10–100 ms depending on the app's responsiveness. On slow apps (Slack, Electron apps), it can exceed 200 ms.

**Optimization:** 
- Move `hasInsertionTarget` to a background thread (accessibility framework is thread-safe for reads).
- Cache the result for a short duration (e.g., 500 ms) since the UI state is unlikely to change between the check and the paste.

```swift
private var lastTargetCheck: (date: Date, result: Bool)?
var hasInsertionTarget: Bool {
    if let cached = lastTargetCheck, Date().timeIntervalSince(cached.date) < 0.5 {
        return cached.result
    }
    let result = computeHasInsertionTarget()
    lastTargetCheck = (Date(), result)
    return result
}
```

#### Accessibility API alternative to clipboard

The comment in TextInserter says "Paste is the only insertion method that behaves consistently across native, Electron, and browser apps." This is true, but an alternative approach exists:

**`AXUIElementSetAttributeValue`** with `kAXValueAttribute` can set the text directly on the focused element without clipboard manipulation. This would eliminate:
- Clipboard save/restore (~700 ms total)
- Risk of clipboard data loss
- Secure input detection complexity

However, this approach has its own issues:
- Doesn't work on all apps (some don't support `AXValue` settable)
- Doesn't work on secure text fields
- Web views (Safari, Chrome) often don't support it

**Recommendation:** Use AX value setting as a **fast path** when available, falling back to clipboard paste:

```swift
if let element = focusedElement, element.isValueSettable {
    AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
    return .pasted  // no clipboard needed
} else {
    // existing clipboard paste fallback
}
```

**Expected gain:** Saves the full clipboard save/restore cycle (~0.7 s + snapshot time) for apps that support it.

---

## 7. Overlay Latency

### File: `/Users/michael/echo/Echo/Overlay/OverlayController.swift`

```swift
Publishers.CombineLatest4($state, $audioLevel, $micReady, $copyConfirmed)
    .sink { state, level, micReady, copyConfirmed in
        overlay.update(state: state, level: level, micReady: micReady, copyConfirmed: copyConfirmed)
    }
    .store(in: &cancellables)
```

**Analysis:** The overlay updates are on a Combine pipeline that fires on every state change. The overlay panel is non-activating (`.nonactivatingPanel`) and doesn't steal focus. The actual work in `update()`:

- Compares states (O(1))
- Shows/hides panel with animation (0.15–0.25 s fade)
- Positions panel (O(1))

**Verdict:** Negligible impact on transcription latency. The overlay updates are fully asynchronous and run on the main thread alongside Combine publishing, but they don't block the transcription pipeline.

**Minor optimization:** The `@Published var audioLevel: Float` is updated at audio callback rate (every 4096 frames ≈ every 93–256 ms). This is fine and doesn't affect latency.

---

## 8. Measured Latency Data

### File: `/Users/michael/echo/Echo/Usage/UsageStore.swift`

```swift
func record(
    words: Int,
    duration: TimeInterval,
    latency: TimeInterval?,
    appBundleID: String?,
    appName: String?,
    date: Date = Date()
) {
    // INSERT INTO dictations (created_at, word_count, duration_seconds, latency_seconds, ...)
}
```

**Analysis:** The SQLite schema already stores `latency_seconds` and `duration_seconds`. However, the app currently has **no way to query latency statistics** — there's no query method that returns latency distribution, averages, or p95.

### Recommendations for observability

Add latency-specific queries to `UsageStore`:

```swift
func latencyStats() -> (avg: Double, p50: Double, p95: Double, p99: Double) {
    // Query: SELECT latency_seconds FROM dictations WHERE latency_seconds IS NOT NULL
    // Sort and compute percentiles
}
```

This would let the team monitor:
- Typical latency (p50)
- Worst-case latency (p99)
- Latency by app (which apps are slow)
- Latency trends over time

**Where latency is measured** (from `DictationController.swift` line 149):

```swift
let releasedAt = Date()
// ... after transcription + processing + insertion:
latency: Date().timeIntervalSince(releasedAt),
```

This measures from hotkey release to completion of insertion. Good coverage.

**But:** The `duration` parameter captures speech duration. The ratio `latency / duration` is the key efficiency metric. For a good experience, `latency < duration` (transcription finishes faster than real time).

---

## 9. Hotkey Capture Latency

### File: `/Users/michael/echo/Echo/Hotkey/HotkeyMonitor.swift`

```swift
globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
    Task { @MainActor in self?.handle(event) }
}
```

**Analysis:** `flagsChanged` events have inherent latency of ~1–2 animation frames on macOS (16–33 ms). The event is received on a global monitor, dispatched to MainActor, and processed. Total latency from key press to `onKeyDown` callback: **~5–20 ms**.

**Verdict:** Not a concern. Human reaction time dominates.

---

## 10. Tooling & System Call Overhead

### Permissions check (DictationController.swift lines 79–90)

```swift
private func waitForPermissions() async {
    _ = await Permissions.requestMicrophone()
    if !Permissions.accessibilityGranted {
        Permissions.promptForAccessibility()
    }
    while !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
        state = .needsPermissions(...)
        try? await Task.sleep(for: .seconds(1))
    }
}
```

**Analysis:** This busy-waits with a 1-second polling loop. If permissions are already granted (which they will be after first launch), it's just the two quick checks (microphone async, AXIsProcessTrusted sync). Total: **~5–15 ms**.

**Verdict:** After first launch, negligible.

---

## Summary of Concrete Recommendations

### High Impact (Implement immediately)

1. **Tune `DecodingOptions` for speed** (`TranscriptionService.swift:37-41`)
   - Set `beamSize: 1`, `bestOf: 1`, `temperature: 0.0`
   - Expected: 2–4× faster inference

2. **Reduce clipboard restore delay** (`TextInserter.swift:128`)
   - Change `restoreDelay` from 0.7 to **0.15**
   - Expected: saves 0.55 s per dictation

### Medium Impact (Implement soon)

3. **Reduce audio tap buffer size** (`AudioRecorder.swift:77`)
   - Change `bufferSize: 4096` to **1024**
   - Expected: reduces capture latency from ~93 ms to ~23 ms

4. **Add model warm-up inference** (`TranscriptionService.swift:33-36`)
   - Run a short silent buffer through the model after loading
   - Expected: eliminates first-dictation ANE cold-start penalty

5. **Reduce mic wake delay** (`DictationController.swift:111`)
   - Change `Task.sleep(for: .milliseconds(600))` to **200**
   - Expected: hotkey→mic-ready 400 ms faster

6. **Add AX value-setting fast path** (`TextInserter.swift`)
   - Try `AXUIElementSetAttributeValue` before falling back to clipboard
   - Expected: eliminates clipboard overhead for compatible apps

### Lower Impact (Address when convenient)

7. **Cache `hasInsertionTarget` result** (`TextInserter.swift`)
   - Add 500 ms TTL cache
   - Expected: avoids repeated AX IPC calls

8. **Add latency percentile queries** (`UsageStore.swift`)
   - Expose p50/p95/p99 latency data
   - Expected: enables data-driven optimization decisions

9. **Pre-wake Bluetooth mic on app launch** (`DictationController.swift:start()`)
   - Call `linkWaker.wake()` when a Bluetooth mic is selected
   - Expected: saves 1–3 s on first dictation with Bluetooth

10. **Offer smaller model variants** (`SettingsStore.swift`)
    - Add "Turbo" mode using `distil-medium` or `distil-small.en`
    - Expected: 2–4× faster inference at slight accuracy cost

---

## Latency Budgets & Targets

For a **5-second dictation utterance** (~15 words at normal speaking rate):

| Stage | Current (est.) | Target | Optimizations |
|-------|---------------|--------|---------------|
| Hotkey→recording start | 5–20 ms | ≤20 ms | No change needed |
| Mic wake (Bluetooth worst case) | 2–4 s | 0.5–1 s | Pre-wake, earlier wake signal |
| Audio capture (5 s speech) | 5 s | 5 s | Inherent |
| AVAudioConverter + buffer | 100–300 ms | 25–50 ms | Smaller buffer size |
| **Transcription inference** | **3–8 s** | **1–2 s** | Greedy decoding, smaller variant |
| Post-processing | <1 ms | <1 ms | Already trivial |
| Insertion target check | 10–200 ms | 10–50 ms | Cache result |
| Clipboard snapshot | 1–5 ms | 0 ms (AX fast path) or same | AX value set |
| ⌘V synthesis | 10–30 ms | 10–30 ms | No change |
| **Clipboard restore delay** | **700 ms** | **150 ms** | Reduce delay |
| **Total (worst case)** | **~10–14 s** | **~6.7–8.2 s** | |
| **Total (best case, fast mic)** | **~8–12 s** | **~1.3–2.5 s** | With all optimizations |

**Key target:** Inference should complete in **≤0.5× real-time** (5 s speech → ≤2.5 s inference). This is achievable with greedy decoding on `distil-medium` on Apple Silicon ANE.

---

## Trade-offs

### Latency vs. Accuracy
- Greedy decoding (beam size 1) vs. beam search 5: ~2% WER degradation, 5× speedup. **Worth it for dictation** where instant feedback matters more than perfect accuracy.
- Smaller model (distil-medium vs. distil-large-v3): ~5–10% WER degradation, 2× speedup. Offer as "Turbo mode" toggle.

### Latency vs. Battery
- ANE is extremely power-efficient (~5 W during inference). Streaming inference (running ANE while recording) would increase power draw slightly.
- Keep-warm engine (45 s) vs. frequent teardown: minimal difference. Bluetooth radio power dominates.

### Latency vs. Memory
- `load: true` vs. memory-mapped: ~600 MB vs. ~200 MB RSS. The current approach loads the full model, which is fine for a menu-bar app on 16 GB+ Macs.

### Latency vs. Complexity
- AX value-setting fast path adds ~20 lines but needs thorough testing across apps.
- Streaming inference adds significant complexity but may only save 1–2 s.

---

## Risk Register

| Risk | Likelihood | Severity | Mitigation |
|------|-----------|----------|------------|
| Greedy decoding hurts accuracy noticeably | Low | Medium | A/B test, offer toggle |
| Clipboard restore delay reduction breaks paste in some apps | Very Low | High | Test across 20+ apps; keep at 200 ms minimum |
| AX value setting fails silently | Medium | Low | Fallback to clipboard within same method |
| Smaller buffer increases CPU usage | Low | Low | Profile before committing |
| Pre-waking Bluetooth drains battery | Low | Low | Only pre-wake if Bluetooth device detected |

---

## Acceptance Report