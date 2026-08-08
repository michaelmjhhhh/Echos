# Echo: technical project brief (repository evidence)

**Scope.** This brief describes the checked-out `main` tree, whose current tip is `eaddfbc9f0cf9cbc6471897c253056adc724afd4` (see `.git/logs/refs/heads/main`). File/line references are to the current tree; roadmap statements are explicitly separated.

## Confirmed current product workflow

- Echo is a menu-bar macOS app: hold the configured hotkey (default Right Option), speak, release, and the transcript is processed and inserted into the focused app. `Echo/EchoApp.swift:3-49` creates the controller, stores, main window, and `MenuBarExtra`; `Echo/Settings/SettingsStore.swift:25-67` persists the hotkey (Right Option, Right Command, or Fn); `Echo/Hotkey/Hotkey.swift:3-35` maps those choices.
- Startup requests microphone access, prompts for Accessibility, waits until both are granted, downloads/prepares and loads the model, starts the global hotkey monitor, then becomes idle. `Echo/DictationController.swift:126-169,205-231`; `Echo/Permissions.swift:4-30`. README’s first-launch workflow independently confirms both permissions and the one-time download (`README.md:20-26`).
- On key down the recorder starts and the state becomes `recording`; release stops capture and asynchronously trims/transcribes/processes/inserts. There is a 120-second safety cap and Bluetooth wake-up path (`Echo/DictationController.swift:233-327`). `EchoTests/DictationControllerTests.swift:30-119` covers readiness, short recordings, trimming, and the full pipeline.

## Implementation architecture

- `DictationController` is the main-actor lifecycle coordinator and dependency-injection seam: recorder, transcriber/factory, inserter, processors, hotkey monitor, and optional stores are injected (`Echo/DictationController.swift:3-119`). The app wires one shared instance of each store and injects them into the controller (`Echo/EchoApp.swift:5-36`).
- Capture is AVAudioEngine input converted to 16-kHz, mono Float32; a tap computes RMS levels and accumulates samples (`Echo/Audio/AudioRecorder.swift:18-24,66-143`). The engine remains warm for 45 seconds after stop to preserve Bluetooth HFP links (`Echo/Audio/AudioRecorder.swift:24-26,49-64`).
- The transcript path is: voice-activity trim, Whisper transcription with dictionary vocabulary, generic whitespace cleanup, dictionary replacement, snippet expansion, then insertion (`Echo/DictationController.swift:329-414`). Capture/trimming tests verify selected samples are sent and too-short selected audio is discarded (`EchoTests/DictationControllerTests.swift:68-119`).

## Local transcription model/runtime

- `TranscriptionService` wraps WhisperKit. It downloads a model only when required, recognizes an already-downloaded folder locally, loads with `prewarm: true`, and performs a throwaway 0.1-second inference to warm the pipeline (`Echo/Transcription/TranscriptionService.swift:3-61`). Real inference uses 16-kHz samples, English transcription, and skip-special-tokens (`:63-85`).
- Default is `distil-whisper_distil-large-v3_594MB`; the catalog also offers Tiny/Base/Small, Large v3 Turbo, and Large v3 (`Echo/Settings/SettingsStore.swift:35-37`; `Echo/Transcription/WhisperModelCatalog.swift:10-46`). Model files live under the Hugging Face/WhisperKit CoreML layout and require four artifacts to count as downloaded (`WhisperModelCatalog.swift:49-78`). A model switch releases the old service, loads the new one, persists the setting only on success, and reloads the prior model on failure (`Echo/DictationController.swift:171-203`).
- The model/runtime is explicitly on-device CoreML/WhisperKit and has no application network/API/account workflow; README states this directly (`README.md:3-5,30-39`). A test proves an existing model prepares without a network download (`EchoTests/TranscriptionServiceTests.swift:12-30`).

## Permissions and insertion behavior

- Microphone permission uses AVFoundation; Accessibility uses `AXIsProcessTrusted`, with system prompts/settings deep links (`Echo/Permissions.swift:4-30`). The target is not sandboxed and declares microphone usage text (`project.yml:35-47`).
- Insertion snapshots the general pasteboard, places transcript text there, synthesizes Command-V, then restores the original items after 0.7 seconds (`Echo/Insertion/TextInserter.swift:51-65,118-171`). The focused-element heuristic deliberately pastes on uncertainty, recognizes editable AX roles/settable attributes, and rejects secure input and confident non-editable roles (`Echo/Insertion/TextInserter.swift:20-49`).
- If no insertion target exists—or secure input appears between the check and paste—the controller enters `copyReady`; the overlay offers Copy and the offer expires after 10 seconds (`Echo/DictationController.swift:417-449`). Tests cover no target, Copy, and the secure-input backstop (`EchoTests/DictationControllerTests.swift:135-178`).

## Text processing, dictionary, snippets

- Current generic processing is intentionally small: surrounding whitespace is trimmed and internal whitespace/newline runs collapse to single spaces (`Echo/Processing/TextProcessor.swift:3-17`). The protocol is the extension point for future processors, not evidence that an LLM currently exists.
- Dictionary entries are local JSON (`Application Support/Echo/dictionary.json`), capped at 1,000 entries and 60 characters per word. Entries supply both ordered recognition-prompt words and compiled case-insensitive whole-word misspelling replacements; longest misspellings win, and sentence-start lowercase replacements are recapitalized (`Echo/Dictionary/DictionaryStore.swift:1-12,46-75,137-183`; `Echo/Processing/ReplacementProcessor.swift:3-49`).
- Snippets are local JSON (`snippets.json`), capped at 1,000 entries, 60-character triggers and 4,000-character expansions. Matching is case-insensitive and whole-word; standalone utterances (including trailing punctuation) replace the entire utterance, while mid-sentence triggers expand in place. Expansions remain verbatim (`Echo/Snippets/SnippetStore.swift:1-11,35-64,108-134`; `Echo/Processing/SnippetProcessor.swift:3-52`). Tests confirm both modes, overlap ordering, literal expansion, and dictionary-before-snippet ordering (`EchoTests/SnippetProcessorTests.swift:8-112`).

## History and usage

- History is optional (`saveHistory` defaults true), local JSON, newest-first, capped at 500 entries; it is written through a serial persistence actor and stores transcript text (`Echo/Settings/SettingsStore.swift:40-43,61-63`; `Echo/History/TranscriptStore.swift:1-56`; `Echo/History/HistoryPersistence.swift:8-43`).
- Usage is separate local SQLite and intentionally stores counts/timings and app identity, not transcript content. It records outcomes, model variant, trimming/capture/transcription/processing/insertion latency, and supports totals, monthly words, active days, WPM, per-app words, daily words, and streak calculations (`Echo/Usage/UsageStore.swift:1-32,50-137,180-252`). Tests verify persistence, legacy migration, failure exclusion, schema privacy, WPM, per-app, daily, and streak behavior (`EchoTests/UsageStoreTests.swift:46-177`).

## Build requirements

- `project.yml` targets macOS 14, Swift 5.9, package dependency ArgmaxOSS/WhisperKit from 0.9.0, and an app plus unit-test target (`project.yml:1-19,21-55`). README requires Apple Silicon, macOS 14+, Xcode 16+, and XcodeGen; build is `xcodegen generate` then `xcodebuild -scheme Echo -configuration Release build`, tests via `xcodebuild -scheme Echo test` (`README.md:9-18,41-46`). The app is manually signed with a configured Apple development identity, hardened runtime and App Sandbox disabled (`project.yml:35-47`).

## Roadmap / inference (not current behavior)

- The text-processor comment says it is a hook for a future local-LLM formatting pass (`Echo/Processing/TextProcessor.swift:3-7`; README `:34-36`). No local LLM implementation was found in the current source tree.
- The post-transcription latency document is an approved design, not proof of a future release: it proposes cached rules, non-blocking history persistence, and waveform coalescing while explicitly excluding Whisper/model-selection and clipboard redesign (`docs/superpowers/specs/2026-07-12-post-transcription-latency-design.md:1-35`). Current code already contains cache snapshots, an actor, and a waveform coalescer, so the document may describe work subsequently landed; its “approved design” status should not be presented as a product roadmap commitment.
- Commit history shows iterative Bluetooth capture/warm-up, copy fallback, SQLite Insights, diagnostics, model selector, capture optimization, and post-transcription latency work (`.git/logs/refs/heads/main`, commits including `b5df372`, `efac2fe`, `ae0c129`, `577a3ef`, `e893e7e`). These commit subjects establish change history, not independent runtime evidence.

## Remaining uncertainties / residual risks

1. No runtime build or UI/manual test was run in this research pass; actual permissions, hardware capture, Bluetooth behavior, and cross-app paste reliability remain environment-dependent.
2. README claims “no network calls,” while first launch/model switching can download model files (`README.md:20-26`; `TranscriptionService.swift:25-44`): interpret this as no transcription-service/API calls, not literally no network traffic.
3. `project.yml` contains a fixed manual signing identity; whether it exists on another developer machine is unverified (`project.yml:35-47`).
4. History persistence is best effort (`HistoryPersistence.swift:27-43`), so a crash or disk failure can lose the latest local history snapshot even though insertion succeeds.

## Acceptance report

- **Review findings:** no source changes; one documentation-risk finding (README’s “no network calls” is broader than model-download behavior), and one portability risk (fixed signing identity). Severity: medium for wording, medium for build portability.
- **Residual risks:** hardware/permission/cross-app insertion behavior and unexecuted build/tests remain unverified; best-effort history persistence can lose latest entries.

```acceptance-report
{
  "criteriaSatisfied": [
    {"id": "criterion-1", "status": "satisfied", "evidence": "Concrete workflow, architecture, runtime, permissions, insertion, processing, feature, build, roadmap, and risk findings cite repository paths and line ranges/commits."}
  ],
  "changedFiles": ["docs/echo-project-research.md"],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": ["Repository source and history were inspected; no source code was altered."],
  "residualRisks": ["No build/test execution; hardware and cross-app behavior unverified", "README no-network wording conflicts with model downloads", "Fixed signing identity may not exist on other Macs", "History persistence is best effort"],
  "noStagedFiles": true,
  "diffSummary": "Added one evidence-backed research brief; source code unchanged.",
  "reviewFindings": ["medium: README.md:3-5,20-26 - no-network wording should distinguish inference from model download", "medium: project.yml:35-47 - fixed manual signing identity is environment-specific"],
  "manualNotes": "Current behavior is separated from roadmap/inference; no commit, push, publish, or subagents used."
}
```