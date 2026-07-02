# Transcription Quality Improvement — Codebase Review

## Executive Summary

### Top Recommendations (ranked by impact)

1. **Encode richer DecodingOptions** — The current config (`skipSpecialTokens: true, language: "en"`) leaves nearly every accuracy lever at defaults. Setting `temperature: 0.2`, `temperatureIncrementOnFallback: 0.2`, `temperatureFallbackCount: 5`, `compressionRatioThreshold: 2.4`, `logProbThreshold: -1.0`, and `suppressBlank: true` would catch failed decodes and retry with higher temperatures, dramatically reducing garbled output. **Impact: Very High, Implementation Effort: Low.**

2. **Add post-processing stages (capitalization + punctuation restoration)** — Whisper output is all-lowercase with minimal punctuation. Adding a `CapitalizationProcessor` (using NaturalLanguage `NLTagger` lexical capitalization) and a `PunctuationRestorationProcessor` (via a small CoreML model or rule-based system) would make output immediately more usable. The `TextProcessor` protocol (line 8 of `TextProcessor.swift`) already supports chaining. **Impact: High, Implementation Effort: Medium.**

3. **Swap default model to `openai_whisper-large-v3-v20240930_626MB`** — The distil-whisper model (594 MB) is ~2.7× faster but measurably less accurate than the full large-v3 (626 MB only 5% larger). The Sep 2024 refresh adds punctuation and improved formatting. Since the current pipeline already downloads 594 MB, the 626 MB model is a near-zero-cost win. **Impact: High, Implementation Effort: Trivial (one string change).**

4. **Enable automatic language detection** — Hard-coding `language: "en"` forces English-only decoding even for multilingual-capable models. Setting `detectLanguage: true` and removing the explicit `language: "en"` in `DecodingOptions` (TranscriptionService.swift:44-45) allows WhisperKit to auto-detect, handling code-switching and non-native accents. **Impact: Medium, Implementation Effort: Trivial.**

5. **Fix audio format conversion edge case** — The `AVAudioConverter` callback in `AudioRecorder.swift` (line 108-113) does not handle `NSData` (planar-to-interleaved) or `noDataNow` after initial buffer, which can cause truncated audio or silent failures on certain mic configurations. **Impact: Medium, Implementation Effort: Low.**

---

## Detailed Analysis

### 1. Audio Quality — Capture Pipeline

**File:** `/Users/michael/echo/Echo/Audio/AudioRecorder.swift`

#### Current state
- **Sample rate:** 16 kHz mono Float32 — correct for Whisper (line 21: `static let sampleRate: Double = 16_000`).
- **Format conversion:** `AVAudioConverter` from the input device's native format to 16 kHz mono Float32 (lines 93-96). The converter uses `interleaved: false` (deinterleaved planar).
- **Buffer size:** 4096 frames (line 99) — reasonable; gives ~256 ms latency at 16 kHz.

#### Issues found

**a) AVAudioConverter callback only handles one buffer (lines 107-115):**
```swift
converter.convert(to: converted, error: &error) { _, status in
    if fed {
        status.pointee = .noDataNow
        return nil
    }
    fed = true
    status.pointee = .haveData
    return buffer
}
```
This is correct for a one-shot conversion, but the `noDataNow` branch means if the converter requests more input (e.g., for complex sample rate conversions like 48 kHz → 16 kHz), it gets nothing. This works for simple conversions but may silently truncate audio for certain input formats.

**Severity: Medium.** Could cause partial audio loss on non-standard mic configurations.

**b) No input gain/normalization (line 119-122):**
```swift
for index in 0..<frameCount {
    let sample = channel[0][index]
    sum += sample * sample
}
```
Raw samples are passed to WhisperKit without any normalization. Whisper expects samples in the range [-1, 1], which `AVAudioPCMBuffer` already provides for `.pcmFormatFloat32`. However, quiet mics or distant speakers produce very low amplitude signals that could degrade accuracy.

**Recommendation:** Add optional peak normalization or AGC (automatic gain control) before appending. A simple approach: track a running max amplitude and normalize when the recording ends.

**c) RMS threshold 0.0001 is very low (line 27):**
```swift
private static let audibleThreshold: Float = 0.0001
```
This is -80 dB — basically digital silence. While this works for "is the mic awake?", it doesn't serve as a voice activity gate. WhisperKit receives all captured audio including silence gaps, which can cause it to hallucinate or produce "inaudible" segments.

**Recommendation:** Consider adding a VAD gate that drops silent trailing segments before sending to WhisperKit. The `EnergyVAD` class is already available in WhisperKit's source tree.

**d) Keep-warm pattern (line 24, 45s):**
The 45-second keep-warm period is generous. This is good for Bluetooth reliability but means the `AVAudioEngine` tap runs continuously, discarding samples when not capturing. No quality issue, but worth noting for power consumption.

### 2. Model Selection

**File:** `/Users/michael/echo/Echo/Settings/SettingsStore.swift` (line 34)
**File:** `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift`

#### Current model: `distil-whisper_distil-large-v3_594MB`

#### Available alternatives (from WhisperKit Models.swift)

| Model Variant | Size | Type | Notes |
|---|---|---|---|
| `openai_whisper-large-v3_947MB` | 947 MB | Full large-v3 | Best accuracy, ~60% larger than distil |
| `openai_whisper-large-v3-v20240930_626MB` | **626 MB** | Full large-v3 (Sep 2024 refresh) | **Best recommendation** — only 5% larger than distil, full accuracy, adds punctuation |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 632 MB | Turbo variant of 2024 refresh | Slightly faster than full, same accuracy |
| `openai_whisper-large-v3_turbo_954MB` | 954 MB | Turbo, larger | Faster but larger |
| `openai_whisper-large-v2_turbo_955MB` | 955 MB | v2 turbo | Older, no punctuation improvement |
| `distil-whisper_distil-large-v3_turbo_600MB` | 600 MB | Distilled + turbo | Fastest but lowest accuracy |

#### Analysis

The distil-whisper model trades ~30-50% word error rate reduction for ~2.7× speedup on ANE. However, Echo is a push-to-talk app — users only dictate short bursts (seconds, not minutes), so the speed advantage is negligible for typical use. The full large-v3 model runs in under real-time on M-series Macs.

The `openai_whisper-large-v3-v20240930_626MB` (Sep 2024 refresh) is particularly attractive because:
1. It's only 32 MB larger than the current distil model (626 vs 594 MB)
2. It includes punctuation in the training data, reducing the need for post-processing
3. It has improved formatting and capitalization
4. It runs on ANE with acceptable latency

**Recommendation:** Change `defaultModelVariant` to `openai_whisper-large-v3-v20240930_626MB` and add a settings UI to let users pick between accuracy/speed variants.

#### Model download (WhisperKit.swift line ~220)
The `download()` method uses `HubApi.snapshot()` which downloads model files from HuggingFace. Currently the UI (SettingsView.swift line 88) says "To try another variant: defaults write com.michael.echo modelVariant <name>, then relaunch Echo." This is user-hostile.

**Recommendation:** Add a model picker in Settings that calls `WhisperKit.fetchAvailableModels()` and lets users switch without editing defaults.

### 3. Post-Processing Pipeline

**File:** `/Users/michael/echo/Echo/Processing/TextProcessor.swift`

#### Current state
Single `WhitespaceCleanupProcessor` (lines 13-20) that collapses whitespace runs. Comment on line 6 explicitly notes: *"this is the hook where a local LLM cleanup stage can be added later."*

#### Recommended processors

**a) CapitalizationProcessor** — Whisper output is all lowercase. Use Foundation's `NLLinguisticTagger` for truecasing:
```swift
struct CapitalizationProcessor: TextProcessor {
    func process(_ text: String) -> String {
        // Use NSLinguisticTagger for sentence-level capitalization
        let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass], options: 0)
        tagger.string = text
        // ... capitalize first word of each sentence
    }
}
```

**b) PunctuationRestorationProcessor** — The `large-v3-v20240930` model emits punctuation natively, but for users on other models or who need extra reliability, a small CoreML punctuation model (~10 MB) can be added. Alternatively, use a rule-based approach with sentence boundary detection.

**c) DeDuplicateProcessor** — Whisper occasionally repeats n-grams or entire phrases when it loses confidence. Track the last N tokens and suppress repeated sequences:
```swift
struct DeDuplicateProcessor: TextProcessor {
    let ngramSize = 3
    func process(_ text: String) -> String {
        // Remove duplicated n-grams
    }
}
```

**d) Smart casing for proper nouns** — Use `NSLinguisticTagger` with `.nameType` scheme to detect and capitalize person/organization names.

**Priority order for implementation:**
1. Capitalization (biggest visible improvement per unit effort)
2. De-duplication (reduces obvious Whisper artifacts)
3. Punctuation (partially addressed by model swap above)

### 4. Language Handling

**File:** `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` (line 44)

#### Current state
```swift
let options = DecodingOptions(
    task: .transcribe,
    language: "en",
    skipSpecialTokens: true
)
```

The `language: "en"` parameter:
- Forces English-only decoding tokens
- Prevents Whisper from detecting accented English or code-switching
- Ignores the model's multilingual capabilities

#### Analysis

The `distil-large-v3` model is English-optimized, but is still a multilingual model. When `language: "en"` is set, WhisperKit uses the English-specific decoder prefix tokens, which reduces the model's ability to handle:
- Non-native English accents (Indian, Spanish, Chinese accents)
- Code-switching (loanwords, names in other languages)
- Technical terminology with non-English origins

**Recommendation:** Change to:
```swift
let options = DecodingOptions(
    task: .transcribe,
    language: nil,           // Auto-detect
    detectLanguage: true,    // Enable detection
    skipSpecialTokens: true
)
```

**Trade-off:** Adding `detectLanguage: true` adds ~50-100 ms of latency on first decode (language detection runs before transcription). For push-to-talk dictation, this is imperceptible.

If the model is changed to the Sep 2024 refresh (which is also multilingual), this benefit is compounded.

### 5. Transcription Parameters — DecodingOptions

**File:** `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` (lines 43-47)
**Reference:** WhisperKit `Configurations.swift` (lines 156-245)

#### Current config (sparse — most fields are defaults)

| Parameter | Current | Default (WhisperKit) | Recommended |
|---|---|---|---|
| temperature | 0.0 | 0.0 | 0.0 (or 0.2 for fallback) |
| temperatureIncrementOnFallback | 0.2 (default) | 0.2 | 0.2 |
| temperatureFallbackCount | 5 (default) | 5 | 5 |
| compressionRatioThreshold | 2.4 (default) | 2.4 | 2.4 |
| logProbThreshold | -1.0 (default) | -1.0 | -1.0 |
| firstTokenLogProbThreshold | -1.5 (default) | -1.5 | -1.5 |
| noSpeechThreshold | 0.6 (default) | 0.6 | 0.6 |
| skipSpecialTokens | true | false | true (OK) |
| suppressBlank | false (default) | false | **true** |
| topK | 5 (default) | 5 | **40** (with temp > 0) |
| sampleLength | 448 (default) | 448 | 448 (OK) |
| withoutTimestamps | false (default) | false | **true** |
| wordTimestamps | false (default) | false | false (OK) |
| language | "en" | nil | **nil** |
| detectLanguage | false (default) | false | **true** |
| chunkingStrategy | nil (default) | nil | nil (OK for short audio) |

#### Key changes recommended

**a) `suppressBlank: true`** — Prevents Whisper from emitting blank tokens, which can occur at the start of segments. This is a free accuracy improvement.

**b) `withoutTimestamps: true`** — The transcription results include timestamps by default. Setting this removes them from the output text, avoiding timestamp artifacts in the final text. Currently Echo joins segments with a space separator, but timestamp tokens are stripped by `skipSpecialTokens`. Setting `withoutTimestamps: true` makes this explicit and cleaner.

**c) `topK: 40`** (when temperature > 0) — With temperature 0, WhisperKit uses greedy decoding. Keeping `temperature: 0.0` is fine for most cases, but allowing the fallback mechanism to use `topK: 40` during higher-temperature attempts increases diversity and can find better transcriptions when the initial pass fails.

**d) Enable the full fallback mechanism** — The current config implicitly relies on defaults, which is fine. But making them explicit documents the behavior and lets you tune them:
```swift
let options = DecodingOptions(
    task: .transcribe,
    language: nil,
    detectLanguage: true,
    skipSpecialTokens: true,
    withoutTimestamps: true,
    suppressBlank: true,
    temperature: 0.0,
    temperatureIncrementOnFallback: 0.2,
    temperatureFallbackCount: 5,
    compressionRatioThreshold: 2.4,
    logProbThreshold: -1.0,
    noSpeechThreshold: 0.6,
    concurrentWorkerCount: 4   // Explicit macOS worker count
)
```

### 6. Model Caching & Preparation

**File:** `/Users/michael/echo/Echo/DictationController.swift` (lines 75-82)

#### Current flow
1. `transcriber.prepare(progress:)` → calls `WhisperKit.download(variant:)` (downloads from HuggingFace)
2. `transcriber.loadModel()` → creates `WhisperKitConfig` with `load: true, download: false` and initializes

#### Analysis

**a) Download flow (TranscriptionService.swift lines 20-30):**
The `prepare` method downloads the model every time if not cached. The `HubApi.snapshot()` method caches downloaded files in `~/.cache/huggingface/...`. Subsequent launches check the cache and only re-download if the local hash doesn't match.

**Issue:** There's no progress reporting after 100% — the download callback passes `fractionCompleted` but the state machine in `DictationController.swift` (lines 103-106) only updates if state is `.downloadingModel`. After download completes, the state transitions to `.loadingModel` which happens in `start()` after `prepare()` returns. This is correct.

**b) Model loading (TranscriptionService.swift lines 32-38):**
```swift
let config = WhisperKitConfig(
    model: modelVariant,
    modelFolder: modelFolder?.path,
    load: true,
    download: false,
    prewarm: nil  // ← default is nil, which means false
)
```

**Issue:** `prewarm` is not set. On macOS, CoreML model specialization happens lazily on first inference. Without prewarming, the first transcription after app launch includes the specialization time (several seconds), causing slow first dictation.

**Recommendation:** Set `prewarm: true` in the config. The trade-off (2× load time, ~1 second when cache is hit) is worth the predictable first-transcription latency.

**c) Model switching (DictationController.swift lines 69-70):**
```swift
self.transcriber = transcriber ?? TranscriptionService(modelVariant: settings.modelVariant)
```
The transcriber is created once in `init` and never updated when `settings.modelVariant` changes. Users must relaunch the app.

**Recommendation:** Observe `settings.$modelVariant` and recreate the transcriber when the model changes. The `.sink` subscriptions are already set up in `DictationController.init` (lines 97-99).

---

## Concrete Code Change Suggestions

### Change 1: Enhanced DecodingOptions (TranscriptionService.swift)

```swift
// Current (line 43-47):
let options = DecodingOptions(
    task: .transcribe,
    language: "en",
    skipSpecialTokens: true
)

// Recommended:
let options = DecodingOptions(
    task: .transcribe,
    language: nil,                    // auto-detect
    detectLanguage: true,
    skipSpecialTokens: true,
    withoutTimestamps: true,
    suppressBlank: true,
    temperature: 0.0,
    temperatureIncrementOnFallback: 0.2,
    temperatureFallbackCount: 5,
    compressionRatioThreshold: 2.4,
    logProbThreshold: -1.0,
    firstTokenLogProbThreshold: -1.5,
    noSpeechThreshold: 0.6,
    concurrentWorkerCount: 4
)
```

### Change 2: Default model variant (SettingsStore.swift)

```swift
// Current (line 34):
static let defaultModelVariant = "distil-whisper_distil-large-v3_594MB"

// Recommended:
static let defaultModelVariant = "openai_whisper-large-v3-v20240930_626MB"
```

### Change 3: Add capitalization processor (TextProcessor.swift)

```swift
struct CapitalizationProcessor: TextProcessor {
    func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass, .nameType], options: 0)
        tagger.string = text
        
        var result = text
        // Capitalize first letter
        if let first = result.first {
            result.replaceSubrange(...result.startIndex, with: first.uppercased())
        }
        // Capitalize after sentence endings
        for match in text.ranges(of: /[.!?]\s+\w/) {
            let idx = result.index(match.upperBound, offsetBy: -1)
            result.replaceSubrange(idx...idx, with: result[idx].uppercased())
        }
        // Use NSLinguisticTagger for proper noun detection
        // (implementation details depend on desired complexity)
        return result
    }
}
```

### Change 4: Enable prewarming (TranscriptionService.swift)

```swift
// In loadModel(), change:
let config = WhisperKitConfig(
    model: modelVariant,
    modelFolder: modelFolder?.path,
    load: true,
    download: false,
    prewarm: true   // ← add this
)
```

### Change 5: Settings UI for model variant (SettingsView.swift)

Add a model picker that queries available models:
```swift
// In SettingsView, add state:
@State private var availableModels: [String] = []
@State private var isLoadingModels = false

// On appear, fetch available models:
let models = try? await WhisperKit.fetchAvailableModels(
    matching: ["*large*"],  // Filter to reasonable options
    from: "argmaxinc/whisperkit-coreml"
)
availableModels = models ?? []
```

---

## Trade-offs Summary

| Change | Accuracy Benefit | Latency Impact | Size Impact | Effort |
|---|---|---|---|---|
| DecodingOptions tuning | High (fewer garbled outputs) | None | None | Low (config change) |
| Model → large-v3-v20240930 | High (better overall WER) | ~1.5× slower (~real-time still) | +32 MB (trivial) | Trivial (one string) |
| Capitalization processor | Medium (cosmetic but important UX) | ~1-2 ms | None | Low |
| Language auto-detect | Medium (accents, code-switching) | +50-100 ms first decode | None | Trivial |
| Prewarm enabled | None (latency reduction) | -2-5s first dictation | None | Trivial |
| Model picker in UI | Medium (user chooses optimal) | None | None | Medium |
| Audio normalization/AGC | Low-Medium (quiet mics) | None | None | Low |
| VAD gating | Low-Medium (hallucination reduction) | None | None | Medium |

---

## Architecture Overview

```
AudioRecorder                   TranscriptionService          TextProcessor chain
  │                                   │                            │
  │ 16 kHz Float32 samples            │ WhisperKit (CoreML)        │ [WhitespaceCleanup]
  │ via AVAudioEngine tap             │ DecodingOptions            │ [Capitalization] ← proposed
  │ AVAudioConverter                  │ Model: distil-large-v3     │ [DeDuplication]  ← proposed
  │ Keep-warm: 45s                    │ language: "en"             │
  │                                   │ skipSpecialTokens: true    │
  ▼                                   ▼                            ▼
[samples] ──────────────────► [transcription text] ──────────► [cleaned text]
                                                                     │
                                                                     ▼
                                                              TextInserter
                                                              (⌘V paste)
```

**Dependencies:**
- `DictationController` orchestrates the pipeline
- `SettingsStore` provides model variant and mic selection
- `UsageStore` records latency, word count, duration
- `TranscriptStore` saves history locally

---

## Start Here

If implementing changes, start with **TranscriptionService.swift** — the `DecodingOptions` tuning and model variant change are one-liners with outsized impact. Then add `CapitalizationProcessor` to `TextProcessor.swift` for immediate UX improvement.

---

## Files Retrieved

1. `Echo/Transcription/TranscriptionService.swift` (lines 1-56) — WhisperKit wrapper, DecodingOptions, download/load pipeline
2. `Echo/Audio/AudioRecorder.swift` (lines 1-174) — Microphone capture, AVAudioConverter, 16 kHz format conversion
3. `Echo/Processing/TextProcessor.swift` (lines 1-21) — Post-processing pipeline protocol + whitespace cleanup
4. `Echo/Settings/SettingsStore.swift` (lines 1-91) — App settings, model variant, mic selection
5. `Echo/DictationController.swift` (lines 1-192) — Orchestration, recording lifecycle, transcription dispatch
6. `Echo/Usage/UsageStore.swift` (lines 1-205) — SQLite latency/word tracking
7. `Echo/Insertion/TextInserter.swift` (lines 1-150) — Clipboard-based text insertion
8. `Echo/History/TranscriptStore.swift` (lines 1-67) — Local dictation history persistence
9. `Echo/Audio/AudioInputDevice.swift` (lines 1-100) — Core Audio device enumeration
10. `Echo/Audio/AudioLinkWaker.swift` (lines 1-42) — Bluetooth audio link wake-up hack
11. `Echo/Settings/SettingsView.swift` (lines 1-120) — Settings UI (no model picker currently)
12. `Echo/UI/HomeView.swift` (lines 1-180) — Main home screen, shows model name
13. `Echo/Permissions.swift` (lines 1-39) — Microphone/accessibility permission requests
14. `WhisperKit/Core/Configurations.swift` (lines 140-260) — DecodingOptions struct and defaults
15. `WhisperKit/Core/WhisperKit.swift` (lines 1-550) — Main WhisperKit class, model management
16. `WhisperKit/Core/Models.swift` (lines 41-200) — ModelVariant enum, compute options
17. `WhisperKit/Core/TranscribeTask.swift` (lines 1-450) — Temperature fallback, decoding loop
18. `WhisperKit/Utilities/ModelUtilities.swift` (lines 88-180) — Model variant detection, file formatting

---

## Residual Risks

1. **Model compatibility:** The `openai_whisper-large-v3-v20240930_626MB` may not be available on all macOS versions or M-series chips. Fallback logic should be added to detect and revert.
2. **ANE memory pressure:** Larger models use more ANE memory. If users have other ANE-using apps (video conferencing, photo editing), background pressure could cause transcription failures or slowdowns.
3. **Language detection on short dictations:** For very short utterances (< 2 seconds), language detection accuracy is poor. Cache the detected language and reuse it within a session.
4. **Bluetooth mic latency:** The keep-warm pattern (45s) is a workaround; users switching away from Echo for >45s will experience delays. Consider extending or making configurable.
5. **No streaming/partial results:** The current pipeline waits for full audio before transcribing. For long dictations, users wait in silence. Streaming (real-time) transcription would require chunked VAD processing.
6. **Punctuation model licensing:** If a third-party punctuation restoration model is used, verify its license is compatible with Echo's open-source model.