Now I have a comprehensive view of the entire codebase. Here is my structured UX analysis.

---

# Echo UX Deep-Dive Analysis

## Files Reviewed
- `UI/HomeView.swift` (entire file)
- `UI/MainWindowView.swift` (entire file)
- `UI/HistoryView.swift` (entire file)
- `UI/InsightsView.swift` (entire file)
- `UI/Theme.swift` (entire file)
- `UI/TranscriptRow.swift` (entire file)
- `UI/WaveformRibbon.swift` (entire file)
- `Overlay/OverlayView.swift` (entire file)
- `Overlay/OverlayController.swift` (entire file)
- `Settings/SettingsView.swift` (entire file)
- `Settings/SettingsStore.swift` (entire file)
- `DictationController.swift` (entire file)
- `DictationState.swift` (entire file)
- `Transcription/TranscriptionService.swift` (entire file)
- `Processing/TextProcessor.swift` (entire file)
- `Insertion/TextInserter.swift` (entire file)
- `Hotkey/Hotkey.swift` (entire file)
- `Hotkey/HotkeyMonitor.swift` (entire file)
- `Permissions.swift` (entire file)
- `MenuContentView.swift` (entire file)
- `Audio/AudioRecorder.swift` (entire file)
- `Audio/AudioInputDevice.swift` (entire file)
- `History/TranscriptStore.swift` (entire file)
- `Usage/UsageStore.swift` (entire file)
- `EchoApp.swift` (entire file)

---

## 1. Onboarding Flow

### 1.1 Permission Requests — Sequential, Blocking Loop

**Observation:** In `DictationController.swift` (lines 86–94), `waitForPermissions()` runs a busy loop sleeping 1 second and re-checking both microphone and accessibility permissions. During this time the UI is stuck in `needsPermissions` state on the Home screen.

**User Impact:** If the user denies microphone permission in the system dialog, `requestMicrophone()` returns `false` (Permissions.swift:23), and the app loops forever showing a permissions banner. The user has no way to progress except to manually go to System Settings. The PermissionsBanner in `HomeView.swift` (lines 112–134) does offer "Open Microphone Settings" and "Open Accessibility Settings" buttons, which is good. However, there is no "Retry" or "Refresh" mechanism — the user must wait up to 1 second for the polling loop to notice a change.

**Recommendation (P1):** Add a "Refresh" button or listen for `NSWorkspace.shared.notificationCenter` for `NSWorkspace.didLaunchApplicationNotification` (or use `DistributedNotificationCenter` for the com.apple.systempreferences privacy change) instead of polling. Alternatively, switch to an explicit async/await flow: present both permission dialogs upfront, then move on. The polling pattern also prevents the app from showing model download progress until both permissions are granted — meaning a user who grants permissions but is confused by the download can't see what's happening.

### 1.2 Model Download — No Cancellation, No Retry

**Observation:** `TranscriptionService.prepare()` (lines 34–38) calls `WhisperKit.download()` with a progress callback. The download task is not exposed for cancellation. In `DictationController.start()` (lines 55–65), if the download fails, the state transitions to `.error("Model setup failed: ...")` and the only recovery is a 4-second timer (`scheduleReturnToIdle`) that goes back to `.idle`, which... will immediately try to start again? No — `start()` is called once in `init`. So a download failure leaves the app permanently stuck in error state unless the user quits and relaunches.

**User Impact:** A 600MB download failing partway (network interruption, disk full, server error) produces an opaque error message with no retry mechanism. The user must quit and relaunch. There is no "Skip download and use offline" or "Try again" affordance.

**Recommendation (P0):**
- Surface the download task so it can be cancelled and retried from the UI.
- Add a "Retry" button on the error state (both in `HeroStatus` and menu bar).
- Show estimated download size and remaining time during download.
- Persist partial downloads (if WhisperKit supports resume) or at least show "Download interrupted" verbatim.

### 1.3 Model Download Blocks All Interaction

**Observation:** During download/loading, the Home screen shows a progress percentage but the sidebar footer and menu bar still show status. The model `downloadingModel` → `loadingModel` states are readable, but there's no way to browse other tabs (Insights/History/Settings) during this time because the main content area is the HomeView which is still rendering these states.

**User Impact:** First-time users must sit through a 600MB download (potentially minutes) before they can explore the app or configure settings. This is a significant time-to-value friction.

**Recommendation (P1):** Allow users to navigate to Settings during download so they can at least configure hotkey/microphone while waiting. Show a non-blocking banner or overlay over all tabs during model preparation, rather than blocking the entire main content.

### 1.4 Permission-Banner Affordance After Grant

**Observation:** When both permissions are granted, the banner disappears with animation (good). But the transition from `needsPermissions` to `downloadingModel` happens silently — there's no celebratory or transitional state like "Permissions granted! Now downloading..." which would reassure the user.

**Recommendation (P2):** Add a brief interstitial or micro-interaction (checkmark animation) between permissions and download to acknowledge the user's action.

---

## 2. Dictation Workflow

### 2.1 Hotkey Hold-and-Release — Solid Core, Missing Feedback at Boundaries

**Observation:** The hotkey flow (`hotkeyPressed()` / `hotkeyReleased()` in DictationController.swift, lines 99–143) is clean. Key behaviors:
- Accidental tap guard: <0.3s of audio or <8 samples are ignored (line 149)
- Mic-not-ready guard: if `micReady` is false after 0.8s, shows error (lines 137–141)
- Max duration cap: 120 seconds (line 118)
- Bluetooth mic wake-up nudge via `AudioLinkWaker` (lines 113–117)

**User Impact:** The accidental tap guard is excellent — prevents unintended dictations from brief key presses. The 120-second cap is reasonable but the `maxDurationTask` just calls `finishRecording()` silently — the user hears nothing, sees no visual cue that the recording was cut off. They might release the key expecting a transcription and get silence or a truncated result with no explanation.

**Recommendation (P1):** When the 120-second auto-stop fires, show a brief overlay message like "Recording stopped at 2-minute limit" before transitioning to transcribing state. Also consider showing a live recording timer in the overlay or waveform area (e.g., "0:32 / 2:00").

### 2.2 Error Recovery for "No Audio from Microphone" (lines 137–141)

**Observation:** If the mic never produces audio after 0.8s, the state goes `.error("No audio from the microphone — try another input in the Echo menu")` with a 4-second auto-return to idle.

**User Impact:** The error message is decent, but "try another input in the Echo menu" refers to the menu bar (not the Settings tab). The user may be confused about where to change input. The error disappears after 4 seconds automatically, which could be frustrating if the user was mid-way through reading it.

**Recommendation (P2):** Make the error persist until dismissed (user action), or at least provide a "Dismiss" button along with a direct link/button to open Settings → Input.

### 2.3 Copy-Ready Pill UX (OverlayView.swift)

**Observation:** When there's no insertion target, the overlay shows a pill with the transcript text (truncated to 170pt) and a "Copy" button. It auto-dismisses after 10 seconds (DictationController.swift:177). The Copy button shows a checkmark for 1.2s then dismisses.

**User Impact:** The 10-second auto-dismiss is aggressive for users who may be reading the transcript. The truncated text (only ~20-25 characters visible) is often not enough to confirm the transcription was correct. Users may feel rushed.

**Recommendation (P1):**
- Extend the auto-dismiss to 20–30 seconds, or make it persistent until the user dismisses or starts a new dictation.
- Show a "Show full transcript" option that opens the Echo window to the Home/History view with the entry highlighted.
- Allow clicking the pill to expand/scroll the full text.

### 2.4 Audio Level Visualization During Recording

**Observation:** The WaveformRibbon in HomeView (lines 61–62, 68–72) and the LevelWaveform in OverlayView are both driven by `audioLevel`. The Overlay one is a simple 16-bar history, the HomeView one is a 28-bar bell-shaped envelope.

**User Impact:** The HomeView waveform is beautiful and provides good feedback. However, the overlay waveform (only visible while dictating into another app) is quite small and may not be easily visible in the user's peripheral vision at the bottom of the screen.

**Recommendation (P2):** Increase the overlay pill's waveform size slightly, or add a subtle glow/pulse that scales with audio level so the user can perceive it from their peripheral vision without needing to look directly at the pill. The current 2.5px bars at max 18px height (OverlayView.swift:96) may be too subtle.

---

## 3. Error States & Edge Cases

### 3.1 Microphone Failure (DictationController.swift:106)

**Observation:** If `recorder.start()` throws, the state becomes `.error("Microphone failed: \(error.localizedDescription)")` with auto-return to idle in 4 seconds.

**User Impact:** The error messages from `AudioRecorderError` (`.noInputDevice`, `.formatConversionUnavailable`, `.deviceSelectionFailed`) are technical and not actionable. For example, "No microphone input device found" doesn't tell the user *how* to fix it.

**Recommendation (P1):** Map each error to a user-facing recommendation:
- `.noInputDevice` → "No microphone found. Connect a microphone and try again."
- `.deviceSelectionFailed` → "Couldn't switch to the selected microphone. Try selecting a different input in Settings."
Add a "Open Settings" button in the error-state overlay.

### 3.2 Permission Revocation While Running

**Observation:** The app checks permissions only at startup in `waitForPermissions()`. If the user later revokes microphone or accessibility access via System Settings while Echo is running, there's no monitoring. The next dictation attempt would silently fail or crash.

**User Impact:** The user would try to dictate and get no response or a confusing error, with no clear indication that they need to re-grant permissions.

**Recommendation (P0):** Subscribe to `NSWorkspace.shared.notificationCenter` for workspace notifications or use `kAXFocusedUIElementChangedNotification` to detect accessibility changes. Re-check permissions before each dictation and show a prominent banner if they've been revoked.

### 3.3 Insertion Failure (TextInserter.swift:115–121)

**Observation:** If `IsSecureEventInputEnabled()` returns true after the initial `hasInsertionTarget` check (race condition), `insert()` returns `.copiedToClipboard`. The transcript is left on the clipboard but the user may not realize it needs to be manually pasted.

**User Impact:** The user thinks the insertion succeeded (state goes to `.idle`) but nothing appeared in their text field. They have to discover the clipboard contents.

**Recommendation (P1):** When `insert()` returns `.copiedToClipboard`, show the overlay with a brief message like "Password field detected — transcript copied to clipboard. Press ⌘V to paste." Stay in `.copyReady` state rather than going back to idle.

### 3.4 Secure Input Detection: Race Condition

**Observation:** `TextInserter.insert()` checks `IsSecureEventInputEnabled()` *after* setting the pasteboard but *before* synthesizing ⌘V. If secure input was toggled on between the `hasInsertionTarget` check and the paste, it falls back to clipboard copy. However, the pasteboard was already overwritten with the transcript.

**User Impact:** The user's original clipboard content is lost (replaced with the transcript) and the transcript isn't actually inserted. The `restore` function runs after 0.7s delay but if the user copies something else in between, the restore writes stale data.

**Recommendation (P1):** Save the clipboard snapshot *before* any pasteboard modification (move the `snapshot()` call earlier), and always restore regardless of the result path. Consider showing a brief "Clipboard restored" notification.

### 3.5 Model Loading Failure After Download

**Observation:** If the downloaded model files are corrupted or incompatible, `loadModel()` in TranscriptionService.swift (lines 40–48) throws. This is caught as a generic `TranscriptionError` in DictationController.swift:162.

**User Impact:** The error message "Transcription failed: ..." doesn't distinguish between a transient model-load failure and a permanent transcription error. The 4-second auto-return to idle means the user can't investigate.

**Recommendation (P1):** Differentiate model errors from transcription errors. If model loading fails after a successful download, offer a "Re-download model" action button.

---

## 4. Information Architecture

### 4.1 Tab Organization: Home → Insights → History → Settings

**Observation:** The four-section layout (MainWindowView.swift:38–53) follows a logical progression: see the current state (Home), understand your usage (Insights), review past work (History), configure (Settings). This is sound.

**Potential Issue:** The lack of any badge or notification on the History tab when new transcripts are available. Users may forget to review/history browse.

**Recommendation (P2):** Add a subtle dot or count badge to the History sidebar icon when new transcripts have been added since the user last viewed it.

### 4.2 Home Screen Redundancy

**Observation:** The Home screen (HomeView.swift) contains:
- Permissions banner (conditional)
- Hero area with waveform + status text + instruction
- Info cards (microphone, model, today stats)
- Recent transcripts (last 3)

The "Recent" section with "View all" link to History is good. But the Hero area's "Hold [keycap] in any app — release to insert your words at the cursor." instruction is persistent on every view, which may feel wasteful to experienced users.

**Recommendation (P2):** After the user has completed N dictations (e.g., 5), replace the instruction text with a more contextual message like "Dictate at any time by holding [keycap]". Or collapse the hero when the user has used the app enough to know the flow.

### 4.3 Sidebar: No Quick-Action for New Dictation

**Observation:** The sidebar (MainWindowView.swift:65–87) shows four navigation items. There's no "New Dictation" button or quick toggle. The user can't initiate a dictation from the main window.

**User Impact:** If the user is looking at the Echo window and wants to dictate, they have to dismiss the window (⌘W or click away) and then use the hotkey. This breaks the flow.

**Recommendation (P2):** Add a "Dictate Now" button at the top of the sidebar that simulates a hotkey press (calls `hotkeyPressed()`). While recording, show "Stop Dictation" instead.

---

## 5. Productivity & Power User Features

### 5.1 Auto-Punctuation — Missing

**Observation:** The text processing pipeline (`TextProcessor` protocol in TextProcessor.swift line 9) has only `WhitespaceCleanupProcessor`. There is no auto-punctuation, capitalization, or formatting. Whisper models often output without punctuation unless explicitly prompted.

**User Impact:** Raw transcriptions are uncapitalized, unpunctuated streams of words. Users must manually add periods, commas, and capitalization, significantly reducing the value of dictation compared to competitors like Wispr Flow or Apple's built-in dictation (which adds punctuation).

**Recommendation (P1):** Add an `AutoPunctuationProcessor` that:
- Capitalizes the first letter of each sentence.
- Adds periods at the end of sentences (detected by pause duration or sentence-ending words).
- Uses a lightweight regex + heuristic approach, or integrates a small local model (e.g., a tiny BERT-based punctuation restoration model).

### 5.2 Voice Commands — Missing

**Observation:** There's no mechanism for custom voice commands (e.g., "new line", "delete that", "select all", "undo").

**User Impact:** Users of Wispr Flow or Dragon Naturally Speaking expect to be able to say commands like "scratch that" or "new paragraph". Echo offers no such capability, limiting its utility for power users.

**Recommendation (P2):** Implement a simple post-processing step that searches the transcript for command phrases and replaces them with the appropriate action or text. For example:
- "new line" / "new paragraph" → insert `\n` / `\n\n`
- "scratch that" / "delete that" → discard the last utterance
- "select all" → triple-press ⌘A (requires Accessibility API)

### 5.3 Per-App Settings — Missing

**Observation:** Settings are global. There's no mechanism for per-application configurations (e.g., use a different model in Xcode vs. Slack, or disable auto-punctuation in password fields).

**Recommendation (P2):** Add a per-app configuration panel in Settings that allows users to customize behavior by application bundle ID. Store in a dictionary keyed by bundle ID with overrides for model, auto-punctuation toggle, and hotkey.

### 5.4 Model Switching — Only via Terminal

**Observation:** SettingsView.swift (lines 74–78) shows the current model variant as read-only text with a footnote: "To try another variant: `defaults write com.michael.echo modelVariant <name>`, then relaunch Echo."

**User Impact:** This is a terrible user experience for a consumer app. Users are directed to Terminal to change an in-app setting. The model cannot be switched without a relaunch.

**Recommendation (P1):** 
- Add a dropdown of available model variants in Settings (discovered by scanning the model cache directory or from a bundled list).
- Gracefully reload the model without requiring a relaunch (show a loading state while swapping).

### 5.5 Quick-Copy from Menu Bar

**Observation:** The menu bar (MenuContentView.swift) shows only status text, "Open Echo", and "Quit Echo". There's no access to recent transcripts, no quick-copy action, no way to see the last transcript without opening the main window.

**User Impact:** Users who just dictated and got a transcription need to open the Echo window to copy/review it. This is friction for a productivity tool.

**Recommendation (P2):** Add a "Last transcript" submenu item in the menu bar with the most recent transcription (truncated) and a "Copy" action next to it. Show the last 5 transcripts in a hierarchical menu.

---

## 6. Feedback & Affordance

### 6.1 State Awareness — Good Coverage, One Gap

**Observation:** The app communicates state through:
- Hero status text (HomeView)
- Sidebar footer with colored dot and short status (MainWindowView)
- Menu bar icon (EchoApp.swift)
- Overlay pill (while dictating into other apps)

All states have distinct visual representations. The `DictationState` enum (entire file, 29 lines) has 9 well-defined states with associated values.

**Gap:** The `.needsPermissions` state in the menu bar icon is `"mic.slash"` — this is the same icon used for `.idle` when permissions are missing. But `.idle` is unreachable until permissions are granted, so this is only a problem if permissions are revoked later.

**User Impact:** If permissions are revoked while the app is running, the menu bar icon changes to `"mic.slash"` but the user may not know why.

**Recommendation (P1):** Use distinct menu bar icons for permission errors vs. idle/muted states. Consider a red-badge variant or a warning symbol.

### 6.2 Overlay Visibility — Bottom of Screen

**Observation:** The overlay (OverlayController.swift:101–107) positions at `visible.minY + 24` (24pt from the bottom of the visible screen area). This is similar to Wispr Flow's placement.

**User Impact:** On macOS with a dock at the bottom, the overlay may overlap with the dock or be partially hidden. The overlay is only 56pt tall, but the dock auto-hides setting may affect visibility.

**Recommendation (P2):** Respect the dock's position. Check `NSScreen.visibleFrame` which already accounts for the dock, but also account for the dock's auto-show trigger zone (2px). Consider positioning 8pt above the dock's top edge when the dock is visible.

### 6.3 No Audio Chime for Start/Stop

**Observation:** The app does not play any sound when recording starts or stops, nor when transcription completes. The only feedback is visual (overlay appears/disappears).

**User Impact:** Users with visual impairments or who are looking away from the screen may not know when recording has started or ended. Competing products like Wispr Flow use subtle audio cues.

**Recommendation (P2):** Add optional audio cues (subtle pop/clink sounds) for:
- Recording start (a soft "tap")
- Recording stop / transcription complete (a soft "chime")
- Error state (a gentle "buzz")
Make these opt-in via Settings.

### 6.4 Microphone Level Meter — Only During Recording

**Observation:** The `audioLevel` is only published while `isLive` is true (i.e., during recording). There's no pre-recording level check or "test microphone" feature.

**User Impact:** Users can't verify their microphone is working before starting a dictation. If the mic is muted or broken, they only discover this after pressing the hotkey and waiting 0.8s for the error.

**Recommendation (P2):** Add a "Test Microphone" button in Settings → Input that shows a live level meter and plays back a short loopback recording. This would also help with Bluetooth mic debugging.

---

## 7. History & Discoverability

### 7.1 Search Functionality

**Observation:** HistoryView.swift (lines 22–27) implements search with `localizedCaseInsensitiveContains(query)`. It filters the in-memory `entries` array.

**User Impact:** On large histories (max 500 entries), the linear filter is fast enough. But the search only covers the `text` field — no date range filtering, no word count filtering, no app-source filtering (though app info isn't stored in TranscriptEntry currently).

**Recommendation (P2):**
- Add date range filtering using the existing `date` field.
- Add a "copied from" app column to `TranscriptEntry` if the app name is available (could be populated from `UsageStore`).
- Consider using `NSPredicate` for more complex queries.

### 7.2 Clear History — Permanent Deletion Warning

**Observation:** HistoryView.swift (lines 53–61) shows a confirmation dialog with the message "History lives only on this Mac and can't be recovered once deleted." This is good privacy messaging.

**Potential Issue:** The "Clear History" button is always visible when there are entries, right next to the search bar. A user might accidentally click it while trying to clear the search field.

**Recommendation (P2):** Move "Clear History" to a less prominent position (e.g., at the bottom of the history list, or in a context menu on a gear icon). Or add a second "Are you sure?" step beyond the confirmation dialog.

### 7.3 Transcript Row — Copy Button Hover

**Observation:** TranscriptRow.swift (lines 28–30, 38–52) shows a copy button only on hover. The button appears with a 1.5s "Copied" confirmation state.

**User Impact:** The hover-to-reveal pattern is fine for discoverability. However, on trackpad/mouse users are served; on touch-bar MacBooks or users who navigate with keyboard only cannot access the copy button.

**Recommendation (P1):** Make the copy button always visible (or at least have a keyboard shortcut, e.g., `⌘C` when a transcript is selected). Currently `textSelection(.enabled)` is set on the text, so users can select and copy manually, but there's no explicit affordance for keyboard-only users.

### 7.4 Insights — Meaningful Metrics

**Observation:** InsightsView.swift provides:
- WPM gauge (0–200 scale)
- Total words with monthly comparison
- Dictation count + active days
- App usage breakdown
- Streak heatmap (GitHub-style)

**User Impact:** The metrics are well-chosen and genuinely useful. The WPM gauge with 200 max is a good aspirational target. The app usage breakdown is unique and valuable for self-reflection.

**Minor Issues:**
- The WPM calculation (UsageStore.swift:148–160) averages over the last 30 days. A new user with 1 dictation gets an unrepresentatively high or low WPM.
- The streak card shows "1 day streak" for 1 day (line 75 in InsightsView.swift), which grammatically should be "1-day streak" — minor.

**Recommendation (P2):**
- Show WPM with a minimum sample size (e.g., at least 3 dictations) before displaying the gauge.
- Add a "Words per day" line chart over the 20-week window (the data is already in `daily`).

### 7.5 Streak Heatmap — 18-Week Window

**Observation:** The heatmap (StreakHeatmap in InsightsView.swift, lines 170–226) shows 18 weeks of data with intensity-based coloring.

**User Impact:** 18 weeks (~4.5 months) is a decent window. However, the heatmap doesn't scroll or expand. Users who have been using Echo for longer than 4 months lose their early history visualization.

**Recommendation (P2):** Add a time-range selector (1 month / 3 months / 6 months / 1 year / All) to the Insights view, allowing users to zoom in and out of their heatmap.

---

## 8. Settings & Customization

### 8.1 Settings Layout — Logical, but Sparse

**Observation:** SettingsView.swift has three cards: Input, Behavior, Model. The layout is clean and uses standard macOS controls (Picker, Toggle).

**User Impact:** The settings are functional but sparse. Several important configurations are missing (see below).

**Recommendation (P1):** Add to the Input section:
- **Input volume/gain** slider — allows users to adjust microphone sensitivity
- **Noise suppression** toggle — switch on/off a simple noise gate
Add to the Behavior section:
- **Auto-punctuation** toggle (see 5.1)
- **Audio cues** toggle (see 6.3)
- **Overlay position** — top/bottom of screen
- **Recording timeout** — slider from 30s to 5min

### 8.2 Appearance Controls

**Observation:** SettingsView.swift (lines 41–47) provides System/Light/Dark appearance picker. This is well-implemented with `NSApp.appearance`.

**Minor Issue:** The appearance change applies immediately, which is good. But there's no preview or explanation of what changes.

**Recommendation (P2):** This is fine as-is. The immediate feedback is sufficient.

### 8.3 Launch at Login — No Explanation of Failure

**Observation:** SettingsStore.swift (lines 77–82): `updateLaunchAtLogin()` catches errors from `SMAppService` but silently reverts the toggle. The user sees the toggle snap back with no explanation.

**User Impact:** Failed login-item registration is silent and confusing.

**Recommendation (P1):** Show an alert with the error description when launch-at-login registration fails. Common causes include managed devices/MDM restrictions.

### 8.4 Hotkey Caveat for Fn Key

**Observation:** SettingsView.swift (lines 32–34) conditionally shows a footnote when the Fn key is selected: "Set System Settings → Keyboard → 'Press 🌐 key' to 'Do Nothing' first..."

**User Impact:** This is valuable guidance. However, it appears in small footnote text and the user may not notice it until after selecting Fn. The caveat should also include a "Open Keyboard Settings" button.

**Recommendation (P2):** Add a "Open Keyboard Settings" button next to the caveat that opens `x-apple.systempreferences:com.apple.preference.keyboard`.

### 8.5 Missing: Input Device Refresh

**Observation:** `SettingsView.onAppear` calls `AudioInputDevices.all()` to populate the microphone picker. This is called once on appear but never refreshed.

**User Impact:** If the user plugs in a new microphone while Settings is open, it won't appear in the list until they navigate away and back.

**Recommendation (P1):** Add a refresh button or periodically poll for device changes (using Core Audio listener callbacks like `kAudioHardwarePropertyDevices`).

---

## 9. Accessibility

### 9.1 VoiceOver Support — Partial

**Observation:** The app uses SwiftUI which provides basic VoiceOver support. However, several custom components may have poor labels:
- `WaveformRibbon` is drawn as shapes with no accessibility label
- `KeycapView` is custom-painted with a `Text` label, which should be accessible
- `StreakHeatmap` cells have `.help()` modifiers but no explicit accessibility labels
- `WPMGauge` is a custom shape with no accessibility value

**User Impact:** VoiceOver users may not understand what the waveform represents, what the gauge value is, or be able to navigate heatmap cells.

**Recommendation (P1):**
- Add `.accessibilityLabel()` and `.accessibilityValue()` to all custom views.
- The WaveformRibbon should have an accessibility label like "Audio level visualization" with a value of the current level.
- The WPMGauge should report its numeric value: "\(value) words per minute".
- Heatmap cells should report date and word count.

### 9.2 Keyboard Navigation

**Observation:** The sidebar is navigable via Tab/arrow keys (it uses standard Button controls). But:
- There's no "Skip to content" shortcut.
- The Settings pickers (Picker) are keyboard-accessible via Tab.
- TranscriptRow copy button is hover-only, so keyboard-only users cannot copy transcripts.

**User Impact:** Keyboard-only users (including VoiceOver users) cannot copy transcripts from the history view without using the ⌘C text selection workaround.

**Recommendation (P1):** Add a persistent "Copy" button (not hover-only) with a keyboard shortcut, or at least make it focusable via the keyboard. Ensure the entire app can be navigated with Tab alone.

### 9.3 Reduce Motion Support — Implemented

**Observation:** The app uses `@Environment(\.accessibilityReduceMotion)` in:
- `HomeView.swift` (line 12)
- `MainWindowView.swift` (line 12)
- `WaveformRibbon.swift` (lines 25, 76)

The waveform breathing animation pauses when reduce motion is enabled, and spring animations use `nil` (no animation) instead of `.spring`. This is excellent.

**User Impact:** Users who prefer reduced motion get a static, non-animated experience. No jarring movements.

**Recommendation:** None needed — this is well-implemented. However, the `TimelineView` in WaveformRibbon continues running even when paused (`paused: reduceMotion && !isLive` means it still updates when `isLive` is true, which is correct). The breathing calculation (`0.4 + 0.25 * sin(...)`) still runs via the `TimelineView` but uses a constant `0.55` when reduce motion is on. Good.

### 9.4 Dynamic Type — Partially Supported

**Observation:** Font sizes use `.echo(12)`, `.echo(13)`, `.echo(15)`, `.echoDisplay(16)`, `.echoDisplay(24)`, `.echoDisplay(30)`. These are fixed point sizes, not Dynamic Type-compatible.

**User Impact:** Users who increase text size in System Settings will not see Echo's text scale accordingly. The app uses custom fonts (Inter, Space Grotesk, IBM Plex Mono) which further complicates Dynamic Type support.

**Recommendation (P2):** Migrate from fixed sizes to SwiftUI's Dynamic Type text styles (`Font.body`, `.caption`, `.title`, etc.) or at minimum use a scaling factor based on the user's preferred content size setting. This requires rethinking the tight visual design but is important for accessibility.

### 9.5 Contrast and Color

**Observation:** The design system (Theme.swift) uses:
- `echoAccent` (cyan): `#00BFCF` dark / `#00808F` light — meets WCAG AA (4.5:1) on `echoBase` dark (`#1C1C1E`) but check light mode contrast
- `echoText` / `echoSecondary` have good contrast ratios
- `echoHairline` is very subtle (10% alpha) — may be invisible to users with low vision

**User Impact:** Users with low vision may struggle with the hairline borders (10% opacity) that define card boundaries. The cards lack background shadows or other depth cues.

**Recommendation (P2):** Add a "High Contrast" mode or at minimum increase hairline opacity to 20–25%. Alternatively, add a very subtle background color difference between cards and the base background (currently `echoCard` vs `echoBase` is only ~6% luminance difference in dark mode).

---

## 10. Trust & Privacy

### 10.1 On-Device-Only Messaging — Good, but Subtle

**Observation:** The app communicates on-device processing in a few places:
- HistoryView.swift:56 — "History lives only on this Mac and can't be recovered once deleted."
- SettingsView.swift:63 — "History is stored only on this Mac — nothing ever leaves it."
- SettingsView.swift:77 — "English-optimized Whisper, runs fully on-device."
- The app uses no network APIs (no URLSession, no remote config).

**User Impact:** Privacy-conscious users are well-served. The messaging is present but subtle—it appears in footnotes and confirmation dialogs.

**Recommendation (P2):** Add a dedicated "Privacy" section in Settings or a persistent banner on the Home screen (on first launch) that explains:
- "Echo runs 100% on your Mac. No audio, transcripts, or usage data ever leave this device."
- "No account required. No internet connection needed after initial model download."
- "Your transcripts are stored locally and can be deleted at any time."

### 10.2 No Network Indicator — Missing

**Observation:** The app doesn't show whether it's online or offline. The model download is the only network-dependent operation.

**User Impact:** Users who have never completed the initial download see "Warming up..." or "Downloading speech model... 0%" — but there's no indication if the download is failing due to network issues vs. slow server.

**Recommendation (P1):** Show a "No network connection" state if the initial model download fails with a network-related error. Use `NWPathMonitor` to observe connectivity and guide the user.

### 10.3 Transcript Data Isolation — Good

**Observation:** TranscriptStore persists to `Application Support/Echo/history.json`. UsageStore persists to `Application Support/Echo/usage.sqlite`. No cloud sync, no iCloud, no network requests.

**User Impact:** Complete data sovereignty. Users who uninstall Echo lose their data — this is documented in the clear-history confirmation dialog but not in general.

**Recommendation (P2):** Add an option to export history as JSON or CSV for users who want to back up their transcripts before uninstalling.

---

## Summary

Echo is a well-architected app with a clean, purposeful design system and a solid dictation core. The state machine is robust, the overlay approach is elegant, and the privacy-first architecture is a genuine differentiator. The main UX gaps are:

1. **Onboarding friction** — The 600MB model download blocks all interaction; permission polling is inelegant; download failures have no retry mechanism.
2. **Missing power-user features** — No auto-punctuation, no voice commands, no per-app settings, model switching requires Terminal.
3. **Accessibility gaps** — Dynamic Type not supported, custom views lack VoiceOver labels, keyboard-only users can't copy transcripts.
4. **Error recovery** — Most errors auto-dismiss after 4 seconds without user action; permission revocation isn't monitored at runtime; secure-input race condition can silently eat the clipboard.
5. **Settings completeness** — No input gain control, no auto-punctuation toggle, model switching is CLI-only.

The highest-impact improvements (P0–P1) involve making onboarding smoother, adding auto-punctuation, improving error recovery with persistent user-actionable messaging, and filling the accessibility gaps.

---