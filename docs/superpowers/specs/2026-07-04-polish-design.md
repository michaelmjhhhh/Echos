# Polish: local LLM cleanup pass — design

**Date:** 2026-07-04
**Status:** Approved

## Summary

When enabled, every dictation's transcript passes through a small on-device
instruct model that removes filler words ("um", "uh", "you know"), resolves
false starts and self-corrections ("send it Tuesday — no wait, Wednesday" →
"send it Wednesday"), and fixes punctuation and capitalization. The output
stays faithful to what was said: the model never adds content, never answers
questions found in the text, and never restructures meaning. Inference runs
entirely offline via MLX, preserving Echo's no-network, no-account identity.

This is the feature the `TextProcessor` pipeline was designed to host (see the
comment in `Echo/Processing/TextProcessor.swift` and the README's "hook for a
future local-LLM formatting pass").

## Decisions

| Question | Decision |
| --- | --- |
| Scope | Cleanup only — no tone rewriting, no structural formatting |
| Engine | MLX Swift + downloaded small instruct model (works on macOS 14+, Apple Silicon — Echo's existing floor) |
| Activation | Single settings toggle; when on, applies to every dictation |
| Failure policy | Best-effort: any error, timeout, or suspicious output falls back to the raw transcript |

Rejected alternatives: Apple Foundation Models (macOS 26+ only, would exclude
macOS 14–15 users); a hybrid Foundation-Models-plus-MLX approach (double the
integration and prompt-tuning work for one feature); tone presets and
bullet-point formatting (deferred — cleanup must earn trust first).

## Architecture

New `Echo/Polish/` module mirroring `Echo/Transcription/`:

### `PolishService` (`Echo/Polish/PolishService.swift`)

Behind a `Polishing` protocol shaped like `Transcribing`:

```swift
protocol Polishing {
    /// Downloads model files if needed, reporting progress in 0...1.
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// Loads the (already downloaded) model into memory.
    func loadModel() async throws
    /// Unloads the model, releasing its memory.
    func unloadModel()
    /// Returns the cleaned transcript. Throws on any failure.
    func polish(_ text: String) async throws -> String
}
```

The concrete implementation wraps MLX Swift (`MLXLLM` / `MLXLMCommon` from
`mlx-swift-examples`, added via SPM in `project.yml`).

- **Model:** a ~1B-class 4-bit instruct model from `mlx-community`
  (candidates: Llama-3.2-1B-Instruct-4bit, Qwen family equivalent). The exact
  variant is chosen with a quality bake-off during implementation and stored
  as a swappable constant alongside `SettingsStore.defaultModelVariant`.
  Roughly 0.6–1 GB download, ~1 GB resident when loaded.
- **Decoding:** greedy (temperature 0) so results are deterministic; capped
  max tokens derived from input length (see guardrails).
- **Warmup:** after load, one throwaway generation so first real use doesn't
  pay the cold start — same trick as `TranscriptionService.loadModel()`.

### `PolishPrompt` (`Echo/Polish/PolishPrompt.swift`)

Pure prompt construction and output validation, separated from inference the
way `VocabularyPrompt` is, so all interesting logic unit-tests without a
model:

- Builds the system + user message pair instructing strict cleanup: remove
  fillers and false starts, apply the speaker's self-corrections, fix
  punctuation/capitalization, output only the cleaned text, never add or
  answer anything.
- Validates model output (see guardrails) and decides polished-vs-raw.

## Pipeline position

Polish is async, so it cannot be a plain `TextProcessor` (whose `process` is
synchronous). Instead it runs as an explicit step inside
`DictationController`'s transcription task. Effective order:

1. `WhitespaceCleanupProcessor`
2. `ReplacementProcessor` (dictionary) — fixes misheard words *before* the
   LLM sees them
3. **Standalone snippet check** — if the whole utterance is a snippet
   trigger, insert the expansion verbatim and skip polish entirely
   (expansions are literal content — emails, URLs, prompts — an LLM must
   never touch)
4. **Polish** (only when enabled and the transcript passes the length gate)
5. Mid-sentence snippet expansion — runs *after* polish so expansions are
   never rewritten

Implementation note: today `SnippetProcessor` performs both standalone and
mid-sentence matching in one `process` call. This design splits those two
modes so the standalone check can run before polish and the mid-sentence pass
after. The split is a refactor of `SnippetProcessor` internals; its existing
behavior with polish disabled is unchanged and existing tests must keep
passing.

Known trade-off: a mid-sentence trigger phrase could in principle be altered
by polish before step 5 sees it. The cleanup prompt instructs
transcription-faithful editing (not rewriting), which preserves deliberate
phrases; this is accepted for v1 and revisited only if real usage shows
broken triggers.

## Guardrails

Polish is best-effort; the raw (steps 1–2) transcript is always the fallback.
A dictation is never lost or indefinitely delayed because of polish.

- **Length gate:** transcripts under 4 words skip polish — nothing to clean,
  zero added latency.
- **Timeout:** 4 seconds. If inference hasn't finished, cancel and insert the
  raw transcript.
- **Output validation** (in `PolishPrompt`), falling back to raw when the
  output is:
  - empty or whitespace-only;
  - suspiciously long — cleanup shortens or preserves, so output exceeding
    1.3× the input word count + 10 words indicates the model added content;
  - wrapped in model chatter (e.g. leading "Here is the cleaned text:") that
    survives extraction.
- **Errors:** any thrown error (model not loaded, MLX failure) → raw text,
  logged via `os.Logger` (subsystem `com.michael.echo`, category `polish`).

## Settings & lifecycle

- `SettingsStore` gains `polishEnabled: Bool` (default `false`), persisted in
  `UserDefaults` like the other settings.
- `SettingsView` gains a Polish section: a toggle, a one-line description,
  and inline download progress the first time it's enabled (same UX pattern
  as the Whisper model download in the menu).
- **Toggle on (first time):** download starts immediately with visible
  progress; on failure the toggle reverts with an inline error message.
- **Load policy:** the model loads (with warmup) when the toggle is on —
  at app launch if already enabled, or right after a successful download.
  It stays resident while enabled and `unloadModel()` frees it when toggled
  off.
- **Overlay:** during polish the overlay stays in the existing
  `.transcribing` state. Expected added latency is well under a second for a
  typical dictation; no new `DictationState` case is introduced.
- **History & usage:** unchanged — history stores what was actually inserted,
  usage metrics record the same fields as today (polish time is naturally
  included in the existing latency measurement).

## Testing

- `DictationControllerTests` with a mock `Polishing`: pipeline order;
  fallback on thrown error; fallback on timeout; length gate; standalone
  snippet bypasses polish; mid-sentence snippets expand after polish;
  polish disabled → behavior identical to today.
- `PolishPromptTests`: prompt construction; output validation (empty,
  too-long, chatter) and the polished-vs-raw decision.
- `SnippetProcessorTests`: extended for the standalone/mid-sentence split;
  existing cases keep passing.
- No model download in CI — `PolishService` itself is exercised manually.

## Out of scope (deferred)

- Tone presets and structural formatting (bullets, paragraphs).
- Per-app polish profiles (e.g. verbatim in terminals) — natural follow-up
  once the frontmost-app signal is routed into behavior.
- A per-dictation bypass modifier key.
- Showing raw-vs-polished diffs in History.
