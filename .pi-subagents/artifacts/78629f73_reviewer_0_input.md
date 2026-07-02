# Task for reviewer

## Deep Dive: Perfecting the Echo User Interface

You are a specialist UI design reviewer for a macOS dictation app called **Echo**. Read all the SwiftUI files below and produce a thorough, actionable deep-dive analysis on how to perfect the user interface.

### Project Context
Echo is a free, fully-local "dictate anywhere" macOS app (alternative to Wispr Flow). It uses WhisperKit for on-device transcription. The app has:
- A main window with a sidebar (Home, Insights, History, Settings)
- A custom design system (3D Sculpt: studio-grey neutrals, mesh-cyan accent, flat surfaces with hairline borders)
- Custom fonts: Space Grotesk (display), Inter (body), IBM Plex Mono (labels)
- Waveform ribbon animation, WPM gauge, GitHub-style streak heatmap, transcript rows
- An overlay view for recording state, a hotkey system, microphone selection

### Files to Read (all under /Users/michael/echo/Echo/)
- UI/Theme.swift - Design tokens, colors, fonts, card modifier, KeycapView, EyebrowText
- UI/MainWindowView.swift - Main window layout, sidebar navigation
- UI/HomeView.swift - Home screen with hero, info cards, recent section, permissions banner
- UI/HistoryView.swift - Transcript history with search, clear
- UI/InsightsView.swift - WPM gauge, word counts, app usage bars, streak heatmap
- UI/TranscriptRow.swift - Individual transcript list row
- UI/WaveformRibbon.swift - Animated waveform visualization
- Overlay/OverlayView.swift - Recording overlay
- Overlay/OverlayController.swift - Overlay window management
- Settings/SettingsView.swift - Settings screen
- EchoApp.swift - App entry point

### Your Task
Analyze every aspect of the UI and provide specific, actionable recommendations for improvement. Cover:

1. **Visual Hierarchy & Layout** — Are spacing, alignment, and sizing consistent? Are there any layout bugs, truncation issues, or awkward gaps? Are card heights and margins harmonious?

2. **Typography** — Is the type scale coherent? Are tracking, leading, and font pairing working well? Any readability concerns?

3. **Color & Contrast** — Do the dark/light theme colors hold up? Are accessibility contrast ratios met? Is the mesh-cyan accent used consistently?

4. **Interaction States** — Hover, press, selected, disabled states. Are they visually distinct and smooth? Any missing feedback?

5. **Motion & Animation** — WaveformRibbon, sidebar transitions, card hover effects, copy button feedback. Are they tasteful, performant, and respectful of reduce-motion?

6. **Component Cohesion** — Are shared components (echoCard, KeycapView, EyebrowText, TranscriptRow) used consistently? Any duplication or drift?

7. **Sidebar & Navigation** — Is 210px sidebar width right? Are the section transition animations appropriate? Is the footer status readout well-integrated?

8. **Window & Overlay** — Window sizing, min dimensions, overlay appearance/positioning, menu bar icon state.

**Format your findings as a structured report.** For each finding: describe the issue, show the relevant code/file reference, and give a concrete fix recommendation. Prioritize fixes from highest to lowest impact.

Do NOT modify any source files. Read them with the read tool to inspect them in detail.
Return your analysis through your response.

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