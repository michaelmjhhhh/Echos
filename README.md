# Echo

Free, fully-local "dictate anywhere" for macOS — a subscription-free alternative to Wispr Flow.

Hold **Right ⌥**, speak, release: your words are typed into whatever app has focus. Transcription runs entirely on-device with [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML, Apple Neural Engine). No network calls, no accounts.

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```sh
xcodegen generate
xcodebuild -scheme Echo -configuration Release build
open build/Release/Echo.app   # or run from Xcode
```

First launch:

1. Grant **Microphone** and **Accessibility** permissions (Echo prompts and the menu bar icon links to the right Settings panes).
2. Wait for the one-time model download (~600 MB, shown in the menu).
3. Hold Right ⌥ and talk.

## How it works

```
Right ⌥ held ──► AVAudioEngine (16 kHz mono) ──► WhisperKit (distil-large-v3, on-device)
                                                       │
cursor ◄── ⌘V paste (clipboard saved & restored) ◄── TextProcessor chain
```

- **Hotkey:** configurable in Settings (Right ⌥ / Right ⌘ / Fn).
- **Insertion:** clipboard paste with save/restore — the only method that works reliably across native, Electron, and browser apps. If a password field has focus (secure input), Echo leaves the transcript on the clipboard instead.
- **TextProcessor pipeline:** raw Whisper text flows through cleanup stages before insertion; this is the hook for a future local-LLM formatting pass.

## Tests

```sh
xcodebuild -scheme Echo test
```
