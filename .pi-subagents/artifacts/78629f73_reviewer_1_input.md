# Task for reviewer

## Deep Dive: Maximizing the Echo User Experience

You are a specialist UX/product designer for a macOS dictation app called **Echo**. Read all the relevant source files below and produce a thorough, actionable deep-dive analysis on how to maximize the user experience.

### Project Context
Echo is a free, fully-local "dictate anywhere" macOS app (alternative to Wispr Flow). Key UX flows:
1. **Onboarding** — Permissions (microphone + accessibility), model download (600MB first-time)
2. **Dictation flow** — Hold hotkey → speak → release → transcription → text insertion at cursor
3. **Post-dictation** — History review, copy, search; insights on usage patterns
4. **Settings** — Hotkey customization, model selection, input device, history toggle

### Files to Read (all under /Users/michael/echo/Echo/)
- UI/HomeView.swift - Main screen, hero area, status text, info cards
- UI/MainWindowView.swift - Navigation, sidebar, health footer
- UI/HistoryView.swift - Transcript history, search, clear
- UI/InsightsView.swift - Usage stats, WPM, streaks, app breakdown
- UI/Theme.swift - Design system
- UI/TranscriptRow.swift - Transcript presentation
- UI/WaveformRibbon.swift - Live audio visualization
- Overlay/OverlayView.swift - Recording overlay appearance
- Overlay/OverlayController.swift - Overlay window behavior
- Settings/SettingsView.swift - App settings
- Settings/SettingsStore.swift - Settings persistence
- DictationController.swift - Core dictation state machine
- DictationState.swift - State enum
- Transcription/TranscriptionService.swift - Transcription pipeline
- Processing/TextProcessor.swift - Text cleanup pipeline
- Insertion/TextInserter.swift - Text insertion at cursor
- Hotkey/Hotkey.swift - Hotkey configuration
- Hotkey/HotkeyMonitor.swift - Hotkey monitoring
- Permissions.swift - Permission handling
- MenuContentView.swift - Menu bar content
- Audio/AudioRecorder.swift - Audio recording
- Audio/AudioInputDevice.swift - Device selection
- History/TranscriptStore.swift - Transcript persistence
- Usage/UsageStore.swift - Usage tracking

### Your Task
Analyze every user-facing aspect of the app and provide specific, actionable UX improvements. Cover:

1. **Onboarding Flow** — First-launch experience: permissions prompts, model download, time-to-value. Is it smooth? What friction exists? What happens if permissions are denied?

2. **Dictation Workflow** — Hotkey hold-and-release interaction. Feedback during recording (audio level, transcription progress). What happens with errors, silence, or very long dictations?

3. **Error States & Edge Cases** — Microphone failure, model download failure, permission revocation, insertion failure (password fields, locked apps). How are errors communicated? Can the user recover?

4. **Information Architecture** — Is the tab organization (Home → Insights → History → Settings) logical? Are users finding what they need? Is there missing context?

5. **Productivity & Power User Features** — Auto-punctuation? Custom voice commands? Per-app settings? Model switching? Quick-copy from menu bar?

6. **Feedback & Affordance** — Does the user always know what state Echo is in (idle, recording, transcribing, error)? Are there moments of uncertainty? Is the overlay sufficient?

7. **History & Discoverability** — Searching transcripts, reviewing past dictations, understanding usage patterns. Are insights meaningful? Are streaks motivating?

8. **Settings & Customization** — Is the settings layout logical? Are options explained well? Any missing configuration?

9. **Accessibility** — VoiceOver support, keyboard navigation, reduce-motion, dynamic type, contrast. Any gaps?

10. **Trust & Privacy** — On-device-only messaging, no-account, no-network. Is this communicated effectively in the UI?

**Format your findings as a structured report.** For each finding: describe the user impact, show relevant file references, and give a concrete recommendation with priority (P0 = critical, P1 = important, P2 = nice-to-have).

Do NOT modify any source files. Read them with the read tool to inspect them in detail.
Return your analysis through your response.

## Acceptance Contract
Acceptance level: reviewed
Completion is not accepted from prose alone. End with a structured acceptance report.

Criteria:
- criterion-1: Implement the requested change without widening scope
- criterion-2: Return evidence sufficient for an independent acceptance review

Required evidence: changed-files, tests-added, commands-run, validation-output, residual-risks, no-staged-files

Review gate: required by reviewer.

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