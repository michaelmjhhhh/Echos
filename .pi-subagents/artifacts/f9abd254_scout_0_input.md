# Task for scout

## Transcription Quality Improvement — In-Depth Codebase Review

You are investigating how to **improve voice-to-text transcription quality** in the Echo macOS app. Read the relevant source files and produce concrete, evidence-backed recommendations.

### Context

Echo is a free, on-device dictation macOS app that uses **WhisperKit** (Apple CoreML port of Whisper) for transcription. The pipeline:
1. AVAudioEngine captures 16 kHz mono Float32 audio
2. WhisperKit transcribes on-device via ANE
3. TextProcessor chain post-processes (currently only whitespace cleanup)
4. Text is inserted via clipboard ⌘V paste

### Key files to inspect (read each fully)
- `/Users/michael/echo/Echo/Transcription/TranscriptionService.swift` — WhisperKit wrapper
- `/Users/michael/echo/Echo/Audio/AudioRecorder.swift` — audio capture quality
- `/Users/michael/echo/Echo/Processing/TextProcessor.swift` — post-processing pipeline
- `/Users/michael/echo/Echo/Settings/SettingsStore.swift` — model variant config (default: distil-whisper_distil-large-v3_594MB)
- `/Users/michael/echo/Echo/DictationController.swift` — orchestration
- `/Users/michael/echo/Echo/Usage/UsageStore.swift` — latency tracking

### Research questions to address

1. **Audio quality**: How does the capture pipeline affect transcription accuracy? Are there sample rate, bit depth, or channel issues? What about the format conversion from the input device to 16 kHz?

2. **Model selection**: The default model is `distil-whisper_distil-large-v3_594MB` (~594 MB). What are the accuracy trade-offs of smaller/larger Whisper models available through WhisperKit? Could a full (non-distilled) model improve accuracy? Are there multilingual or punctuation-aware alternatives?

3. **Post-processing pipeline**: Currently only `WhitespaceCleanupProcessor`. What additional processing stages could improve output quality? Consider: punctuation restoration (the comment in TextProcessor.swift mentions a local LLM cleanup stage), capitalization, grammar correction, de-duplication/n-gram confidence filtering.

4. **Language handling**: The code hard-codes `language: "en"` — what about code-switching, accents, or non-native speakers? Could automatic language detection help?

5. **Transcription parameters**: The `DecodingOptions` in TranscriptionService.swift uses minimal config. What decoding strategies (beam search, temperature, best_of, compression_ratio_threshold) could improve accuracy?

6. **Model caching/preparation**: How does model download and loading work? Any room for improvement in how the model is prepared?

### Output format

Write your findings to `/tmp/echo-quality-review.md` with:
- Executive summary (top 3-5 recommendations ranked by impact)
- Detailed analysis per research area with file/line references
- Concrete code change suggestions where applicable
- Trade-offs considered (accuracy vs. size, speed, memory)

Do NOT modify any project source files. This is a read-only review.

---
**Output:**
Write your findings to exactly this path: /tmp/echo-quality-review.md
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