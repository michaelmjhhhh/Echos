# Changelog

All user-facing and engineering changes are recorded here. Model weights are unchanged unless a release explicitly says otherwise.

## [Unreleased]

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

[Unreleased]: https://github.com/michaelmjhhhh/Echos/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/michaelmjhhhh/Echos/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/michaelmjhhhh/Echos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/michaelmjhhhh/Echos/releases/tag/v0.2.0
