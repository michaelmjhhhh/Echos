# Changelog

All user-facing and engineering changes are recorded here. Model weights are unchanged unless a release explicitly says otherwise.

## [Unreleased]

### Added

- Add Parakeet v2 (English) as an optional speech model next to the Whisper models, through FluidAudio 0.17.7. It downloads about 465 MB to `~/Library/Application Support/FluidAudio/Models/` and requires Apple Silicon. Whisper pads every recording to a 30-second window, so Distil Large v3's encoder took about 0.6–0.75 s even for a one-second clip on the developer's M4; In synthetic replay of single spoken words on the same Mac, release-to-result time was 0.04 s for Parakeet versus 0.70 s for Distil Large v3 on clips under 1.2 s, and 0.19 s versus 2.0 s on 60-second clips; both models transcribed all 14 cases correctly. These are synthetic `say` samples, not a recognition-accuracy benchmark, and Parakeet has not yet been tested with real microphone dictation. Recordings over 14 s are split at pauses before decoding, because FluidAudio's own overlapping windows dropped a repeated word from a 60-second clip. Parakeet takes no text prompt, so dictionary hints, recent context and "Retry difficult speech" do not apply to it; saved spelling corrections and snippets still do. English only. `EchoEvaluate` accepts `parakeet-tdt-0.6b-v2` as a model.

## [0.5.1] - 2026-10-10

### Changed

- Polish every main-window page within the existing design system. Transcript rows show Copy and Open side by side and reveal them on hover or keyboard focus. History groups transcripts by day and shows a total count. The Home hero no longer reserves space for an empty actions row. Insights shows the words-per-minute window (last 30 days), lists result counts as label/value pairs, widens app names before truncating, and sizes the activity calendar to the card width. Settings controls share one right edge.
- History, Dictionary and Snippets share one search field with an inline match count and a clear button.
- The Dictionary sort menu uses the same text color as the buttons beside it, and a starred word's star sits at the card's trailing edge.
- Snippet rows open the editor on a single click, as dictionary cards do, and deleting a snippet now asks for confirmation.
- Counts use singular nouns for one item, for example "1 word" instead of "1 words".
- Ignore `.pi-subagents/` and stop tracking its generated subagent artifacts.
- Add `skills-lock.json`, which pins the `code-review` and `codebase-design` agent skills by source and hash.
- `AGENTS.md` now forbids adding the agent as a commit co-author.

The interface changes are covered only by a successful build and the existing automated checks; there are no automated visual checks, and light mode and small window sizes were not reviewed. Recognition and insertion code is unchanged from 0.5.0.

## [0.5.0] - 2026-10-10

### Added

- Add "Use recent dictation as context" (on by default). With Tiny (English), the previous transcript in the same app from the last five minutes is passed to the model, so names just used are recognized again. It stays in memory only. Other models ignore it: Distil Large v3 showed no gain in replay and returned empty text for most clips when context was used without dictionary words.
- Add an optional per-case `context` field to `EchoEvaluate` manifests, and report dropped silence captions and post-filter false insertions.

### Changed

- Lower the default dictionary hint budget from 200 to 50 tokens and clamp saved 100- or 200-token budgets to 50. WhisperKit keeps only the last 111 prompt tokens, so longer prompts dropped starred terms first.
- Split recordings over 28 seconds at the quietest pause in the last 8 seconds of each 28-second span, and decode the chunks in order, passing earlier text to each chunk as context. When the final chunk would be under 10 seconds, the last two chunks are split about evenly, each 10 seconds or longer. In synthetic replay, long-recording WER fell from 0.238 to 0.174 for Distil Large v3 without dictionary words and from 0.077 to 0.049 for Tiny at 50 tokens, and words near 30- and 60-second window edges were no longer dropped. Only two long synthetic passages were measured.
- Usage records report `noSpeechOnset` as the trim reason when no speech onset was found; such recordings were previously recorded as `noReliableSpeech`.
- Use the current transcription, insertion, history-persistence, and capture-generation interfaces throughout the app and existing test adapters. Usage checks share one bounded wait for the published snapshots used by the UI.

### Removed

- Remove unused model-installation state and inactive-model repair, obsolete rule and transcription-segment projections, and redundant card and history-flush wrappers. Active-model repair and persistence recovery remain available.

### Fixed

- Stop pasting "Thank you." and similar stock captions when the hotkey is held without speech. The transcript is dropped only when the trimmer found no speech onset and every sentence or comma-separated part is a known caption phrase ("Thank you, thank you.") or the text has no letters or digits. Text containing digits is kept. In replay, Tiny returned "you" for both noise clips and both were dropped. Keyboard or breath noise loud enough to count as an onset can still let a caption through.
- Suppress the tokens that open sound-event captions such as "[BLANK_AUDIO]", "(blender whirring)", "*sigh*" and music symbols, a subset of OpenAI's default suppress list. Dictated ":", "/", "@" and "#" are still allowed.
- Fix empty transcripts with large dictionaries. With the old 200-token default and a 49-word dictionary, Distil Large v3 returned empty text for 13 of 24 synthetic speech clips; at 50 tokens it returned none. All accuracy figures in this Unreleased entry come from synthetic `say` speech replayed through `EchoEvaluate` for Tiny (English) and Distil Large v3; they are not real-microphone measurements, and the other catalog models were not tested.

## [0.4.0] - 2026-09-25

### Added

- Add language, prompt-budget, and difficult-audio retry settings, with same-model retry and repair after failures.
- Add a full-transcript viewer and per-entry deletion, expose save/recovery errors, and add separate controls for usage retention, deletion, and summary export.
- Add the `EchoEvaluate` replay tool, synthetic audio fixtures, dependency-lock verification, and CI checks before release.
- Add this changelog and documented requirements for future changelog updates and release notes.

### Changed

- Preserve the default Distil Large v3 model and existing model weights. Cache prompt tokens and reuse a bounded warm audio engine between dictations.
- Keep model downloads under shared ownership and load installed models/tokenizers locally. Readiness now requires successful loading and real encoder warmup.
- Process text replacements once per stage, prefer the longest match, protect URLs/email/code, and preserve literal snippet whitespace.
- Store history in order and calculate usage summaries in the background. Distinguish recognized words, expanded text, dispatched paste events, copied results, cancellations, and failures.
- Pin WhisperKit/Argmax 0.18.0 and all resolved dependency revisions; publish checksums and build provenance with each release.

### Fixed

- Preserve short recordings and speech in the final partial second after a 30-second model window by padding transcription input without changing recorded duration.
- Prevent System Default and the built-in MacBook Air microphone from immediately ending capture after an unchanged-format audio-engine notification. Preserve the engine's default routing, reject stale engine notifications, and show actual interruptions.
- Hide private system-created aggregate devices from the microphone picker and recover saved references to obsolete private devices. Keep public aggregate and virtual inputs available.
- Reset audio conversion between captures, collect bounded trailing frames, and separate microphone readiness from speech volume. Do not discard quiet speech as silence.
- Prevent cancelled, timed-out, or old sessions from pasting into later sessions. Recover the correct model after cancellation and model switching.
- Recheck the original paste target and secure-input state. Keep a manual-copy result when focus changes, and restore the clipboard only while the current insertion still owns it.
- Make dictionary, snippet, and history persistence failures recoverable; protect corrupt files, avoid deleted-history resurrection, and flush pending writes on normal quit.
- Correct hotkey release handling, first-use waveform visibility, and cancellation/copy feedback.

### Known limitations

- Synthetic fixed-weight replay verifies specific short-clip and window-boundary defects; it does not establish overall accuracy or end-to-end latency for natural English dictation.
- System Default and the built-in MacBook Air microphone were checked on real hardware. Bluetooth/external microphone transitions and the full cross-application paste matrix still need device-specific acceptance checks.

## [0.3.0] - 2026-08-24

### Changed

- Reduce post-transcription latency and add stage-level timing ([#1](https://github.com/michaelmjhhhh/Echos/pull/1)).
- Keep the processed transcript on the clipboard by default, with a setting to restore the previous clipboard after pasting.

## [0.2.0] - 2026-07-04

### Added

- Publish the first GitHub release with a DMG for Apple Silicon Macs running macOS 14 or later.

[Unreleased]: https://github.com/michaelmjhhhh/Echos/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/michaelmjhhhh/Echos/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/michaelmjhhhh/Echos/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/michaelmjhhhh/Echos/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/michaelmjhhhh/Echos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/michaelmjhhhh/Echos/releases/tag/v0.2.0
