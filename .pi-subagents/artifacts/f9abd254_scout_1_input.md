# Task for scout

## Transcription Latency — In-Depth Codebase Review

You are investigating how to **minimize latency in the transcription pipeline** of the Echo macOS app. Read the relevant source files and produce concrete, evidence-backed recommendations.

### Context

Echo is a free, on-device dictation macOS app. The full hotkey-to-insertion pipeline:
1. User holds hotkey (Right ⌥) → audio capture starts (AVAudioEngine, 16 kHz mono)
2. User releases hotkey → recording stops, samples collected
3. `state = .transcribing` → `transcriber.transcribe(samples)` called
4. WhisperKit runs CoreML inference on-device (ANE)
5. TextProcessor chain processes result
6. Clipboard ⌘V paste into frontmost app
7. Usage metrics recorded (duration, latency)

### Key files to inspect (read each fully)
- `/Users/michael/echo/Echo/DictationController.swift` — pipeline orchestration, timing
- `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` — WhisperKit transcription
- `/Users/michael/echo/Echo/Audio/AudioRecorder.swift` — audio capture, keep-warm logic
- `/Users/michael/echo/Echo/Audio/AudioLinkWaker.swift` — Bluetooth wake latency
- `/Users/michael/echo/Echo/Insertion/TextInserter.swift` — ⌘V insertion, clipboard save/restore
- `/Users/michael/echo/Echo/DictationState.swift` — state machine
- `/Users/michael/echo/Echo/Settings/SettingsStore.swift` — model variant config
- `/Users/michael/echo/Echo/Usage/UsageStore.swift` — already tracking latency metrics
- `/Users/michael/echo/Echo/Hotkey/HotkeyMonitor.swift` — hotkey capture latency
- `/Users/michael/echo/Echo/Overlay/OverlayController.swift` — UI feedback during transcribing

### Research questions to address

1. **Model loading latency**: The model downloads on first launch (~600 MB), then loads into memory. How does `loadModel()` affect startup? Is there any lazy-loading or memory-mapping opportunity?

2. **Transcription inference latency**: WhisperKit runs the full audio buffer through the model after recording stops. What strategies could reduce latency? Consider:
   - Streaming/real-time inference (transcribe while still recording)
   - Running smaller/cheaper model variant for speed
   - Audio prefixed/chunked processing (VOIP-style)
   - Prompt caching or model warm-up tricks
   - `DecodingOptions` tuning (beam size, temperature, best_of)

3. **Audio pipeline latency**: The capture pipeline has an `AVAudioConverter` from the input format to 16 kHz. Is there overhead here? What about the keep-warm pattern (45s engine reuse)?

4. **Bluetooth mic wake latency**: `AudioLinkWaker` plays 0.4s of silence to wake Bluetooth links. Is this sufficient? Could the wake happen earlier (e.g., pre-warm on app launch or mouse activity)?

5. **Post-processing latency**: Whitespace cleanup is trivial, but what if more processing (LLM) is added? How to keep this fast?

6. **Insertion latency**: Clipboard save/restore with 0.7s restore delay. Could this be optimized? What about using Accessibility API directly for insertion instead of clipboard?

7. **Overlay latency**: The overlay panel shows 'Transcribing…' — any measurable overhead from state publishing/UI updates on the transcript path?

8. **Measured latency**: UsageStore already captures `latency_seconds`. What does typical latency look like? Any patterns in the latency data?

### Output format

Write your findings to `/tmp/echo-latency-review.md` with:
- Executive summary (top 3-5 latency reduction opportunities ranked by impact)
- Detailed analysis per area with file/line references
- Concrete code change suggestions where applicable (with before/after sketches)
- Measurable latency budgets and targets (e.g., 'transcription inference under X seconds for Y seconds of audio')
- Trade-offs: latency vs. accuracy, battery, memory

Do NOT modify any project source files. This is a read-only review.

---
**Output:**
Write your findings to exactly this path: /tmp/echo-latency-review.md
This path is authoritative for this run.
Ignore any other output filename or output path mentioned elsewhere, including output destinations in the base agent prompt, system prompt, or task instructions.

## Acceptance Contract
Acceptance level: attested
Completion is not accepted from prose alone. End with a structured acceptance report.

Criteria:
- criterion-1: Return concrete findings with file paths and severity when applicable

Required evidence: review-findings, residual-risks

Finish with a fenced JSON block tagged `acceptance-report` in this shape:
Use empty arrays when no items apply; array fields contain strings unless object entries are shown.
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "specific proof"
    }
  ],
  "changedFiles": [
    "src/file.ts"
  ],
  "testsAddedOrUpdated": [
    "test/file.test.ts"
  ],
  "commandsRun": [
    {
      "command": "command",
      "result": "passed",
      "summary": "short result"
    }
  ],
  "validationOutput": [
    "validation output or concise summary"
  ],
  "residualRisks": [
    "none"
  ],
  "noStagedFiles": true,
  "diffSummary": "short description of the diff",
  "reviewFindings": [
    "blocker: file.ts:12 - issue found, or no blockers"
  ],
  "manualNotes": "anything else the parent should know"
}
```