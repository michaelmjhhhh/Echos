Now I have all the information needed. Let me compile the comprehensive analysis.

---

# Echo UI Deep-Dive Analysis

## Files Reviewed

- `Echo/UI/Theme.swift` — Design tokens, color system, fonts, card modifier, KeycapView, EyebrowText
- `Echo/UI/MainWindowView.swift` — Main window layout, sidebar
- `Echo/UI/HomeView.swift` — Home screen (hero, info cards, recent)
- `Echo/UI/HistoryView.swift` — Transcript history
- `Echo/UI/InsightsView.swift` — WPM gauge, word counts, app usage, streak heatmap
- `Echo/UI/TranscriptRow.swift` — Transcript list row
- `Echo/UI/WaveformRibbon.swift` — Animated waveform
- `Echo/Overlay/OverlayView.swift` — Recording overlay pill
- `Echo/Overlay/OverlayController.swift` — Overlay window manager
- `Echo/Settings/SettingsView.swift` — Settings screen
- `Echo/EchoApp.swift` — App entry point
- `Echo/DictationState.swift` — State definitions
- `Echo/DictationController.swift` — Controller logic
- `Echo/Usage/UsageStore.swift` — Usage database
- `Echo/History/TranscriptStore.swift` — Transcript storage
- `Echo/MenuContentView.swift` — Menu bar content

---

## Critical (must fix)

### C1. Info card value text truncation in HomeView

**File:** `Echo/UI/HomeView.swift` (lines 90-101)

**Issue:** The three info cards (Microphone, Model, Today) are placed in an `HStack(spacing: 16)` with each card at `.frame(maxWidth: .infinity)`. On the default 760px window, the main content area is ~549px. After sidebar, padding, and spacing, each card's inner text area is approximately **124px wide**. At `Inter 15pt medium`, "Whisper Distil Large v3" (~24 chars ≈ 216px) and even "System Default" (~14 chars ≈ 126px) overflow this width, and `.lineLimit(1)` silently truncates — users see "Whisper Distil Large v3…" and "System Defa…".

**Fix:** Either (a) increase the card min-width by using a 2-card layout instead of 3 on constrained widths, (b) reduce font size to `echo(13, .medium)` for these values, (c) use `.minimumScaleFactor(0.7)` to allow scaling down, or (d) make the cards responsive with a `Layout` that stacks vertically when insufficient width.

---

### C2. App usage bar app name truncation

**File:** `Echo/UI/InsightsView.swift` (line 224)

**Issue:** `AppUsageBar` fixes the app name label to `.frame(width: 88, alignment: .leading)` with `.lineLimit(1)`. At `Inter 12pt medium`, 88px fits ~11–12 characters. Application names like "Visual Studio Code" (17 chars) or "Google Chrome" (12 chars) are truncated. The card is also inside the same 3-column layout as C1, compounding the space problem.

**Fix:** Increase the name frame width (e.g., 110–120px) and correspondingly reduce the bar's `GeometryReader` area, or use `.minimumScaleFactor(0.6)` to let long names shrink, or add a tooltip/`help()` modifier to show the full name on hover.

---

### C3. Frame modifier ordering creates confusing, potentially fragile layout

**Files:** `Echo/UI/HomeView.swift:28-30`, `Echo/UI/HistoryView.swift:32-34`, `Echo/UI/InsightsView.swift:52-54`

**Issue:** All main content views use this pattern:
```swift
VStack { ... }
    .frame(maxWidth: 640)         // inner
    .frame(maxWidth: .infinity)   // outer (effective)
    .padding(24)
```
The outer `.frame(maxWidth: .infinity)` is applied *after* `.frame(maxWidth: 640)` in the modifier chain, meaning the infinity constraint wraps the 640 constraint. SwiftUI resolves conflicting maxWidth constraints by taking the minimum, so the effective maxWidth is 640. However, the outer `.frame(maxWidth: .infinity)` will also cause the view to **center** its child (default alignment), which pushes the 640-wide content into the middle of the available area. This works, but the intent is obscured — it reads as if both constraints should apply simultaneously. The `padding(24)` is outermost, so the padding is *outside* the frame constraints, meaning the VStack itself is padded inward *after* being centered at 640px.

**Fix:** Replace with the canonical SwiftUI centering pattern:
```swift
VStack { ... }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(24)
```
Then wrap the *content* inside the VStack with `.frame(maxWidth: 640)` or apply `frame(maxWidth: 640)` to the VStack's internal content. This is clearer and avoids double-constraint confusion.

---

## Warnings (should fix)

### W1. Overlay Copy button lacks hover/press feedback

**File:** `Echo/Overlay/OverlayView.swift` (lines 53-59)

**Issue:** The Copy button in the overlay pill uses `ButtonStyle(.plain)` with no custom hover, press, or focus state. When the user mouses over it, there's no visual feedback. Since the overlay is the primary interaction surface during copy-ready state, this is a notable UX gap.

**Fix:** Add a `@State private var isHovering` with `.onHover` and change the button background fill to a lighter/darker cyan on hover, plus a subtle scale effect on press via a custom `ButtonStyle`.

---

### W2. Low accent contrast in light mode

**File:** `Echo/UI/Theme.swift` (lines 12-15)

**Issue:** The light-mode accent `#00808F` (RGB 0, 128, 143) on white card backgrounds yields a contrast ratio of approximately **3.2:1**, which fails WCAG AA for normal text (requires 4.5:1) and only passes for large text (3:1 threshold). The accent is used for icons, sidebar indicators, semantic status dots, and small labels throughout the UI.

**Fix:** Darken the light-mode accent to approximately `#006673` (a shift of ~15% luminance) to achieve a 4.5:1 ratio on white, or restrict accent use to large/decorative elements and use a darker variant (`#005A66`) for text and icons.

---

### W3. Overlay panel size hardcoded — content may overflow

**File:** `Echo/Overlay/OverlayController.swift` (line 10), `Echo/Overlay/OverlayView.swift` (line 44)

**Issue:** The overlay panel is fixed at 320×56px. The transcript text in `copyReady` state is constrained to `.frame(maxWidth: 170)`. The pill has `.padding(.horizontal, 18)` on each side (= 36px total), leaving 320 - 36 = 284px for content. The `HStack(spacing: 10)` contains: optional icon (~16px) + transcript text (170px) + Copy button (~60px) = ~246px + spacings ≈ 284px. This fits, but **just barely**. Any localization, system font change, or longer elements will cause layout breakage. Additionally, when showing error messages (which have no `maxWidth` constraint), the text can overflow the 320px panel.

**Fix:** Use `fixedSize()` or intrinsic sizing on the panel rather than a hardcoded width, or apply `.lineLimit(1)` and `.truncationMode(.middle)` to the error message text. Consider making `panelSize` dynamic based on content.

---

### W4. Sidebar footer background opacity reduces text readability

**File:** `Echo/UI/MainWindowView.swift` (lines 117-119)

**Issue:** The sidebar footer uses `.fill(Color.echoCard.opacity(0.7))` over the `.ultraThinMaterial` sidebar background. The 0.7 opacity causes the material to show through, reducing the effective contrast of the status text and microphone name. On light mode, this can be especially problematic as `echoCard` (white) at 0.7 over `ultraThinMaterial` (which is vibrantly blurred) creates a muddy appearance.

**Fix:** Remove the opacity or raise it to 0.9, or use a solid `Color.echoCard` without transparency. The slight transparency visual is nice but not worth the readability trade-off for always-visible status information.

---

### W5. Waveform ribbon idle contrast too low

**File:** `Echo/UI/WaveformRibbon.swift` (line 49)

**Issue:** At idle, bars are filled with `Color.echoSecondary.opacity(0.35)` on `Color.echoCard` (#252527 dark, #FFFFFF light). In dark mode: `#8C8B88` at 35% ≈ `#D0CFCC` effective over `#252527` — approximately **2.5:1 contrast ratio**. This is well below WCAG AA for any text-equivalent content. While the waveform is decorative and not text, users with visual impairments may struggle to see it.

**Fix:** Raise idle opacity to 0.5–0.55, or use a slightly lighter tint (e.g., `echoSecondary.opacity(0.45)`). The design goal of "breathing but subtle" can still be achieved at higher minimum opacity.

---

### W6. No focus ring or keyboard navigation support

**Issue:** Throughout the app, buttons use `.buttonStyle(.plain)` which removes the default focus ring. There's no custom focus ring styling via `.focusEffect()` or `.focusable()`. Users navigating by keyboard (Tab, arrow keys) will have no visual indication of focus position.

**Fix:** Add an `.overlay` with a focused state ring (using `@FocusState` or `.focused()`) for interactive elements in the sidebar, settings, and overlay, or use `.buttonStyle(.borderedProminent)` with custom styling where appropriate.

---

## Suggestions (consider)

### S1. Recent section shows only 3 items with no "Show more"

**File:** `Echo/UI/HomeView.swift` (line 134)

**Issue:** The "View all" button navigates to the full History section, but there's no intermediate "Show more" expansion within the Home view. For users who want to quickly see 5-6 recent entries without switching sections, the current 3-item limit is restrictive.

**Fix:** Increase the preview to 5 items, or add a "Show 5 more" inline expansion.

---

### S2. Empty state for InsightsView is missing

**File:** `Echo/UI/InsightsView.swift`

**Issue:** When the user has no dictation data yet, Insights shows zero values, a flatline gauge, and an empty "Dictate into any app" message. There's no cohesive empty state like the ones in HomeView and HistoryView. The streak heatmap is drawn with empty (hairline) cells, which may look broken or confusing.

**Fix:** Add a top-level empty state similar to HistoryView showing a message like "Dictations will appear here after your first one" with the app icon.

---

### S3. Copy button delay inconsistent

**File:** `Echo/UI/TranscriptRow.swift` (line 37), `Echo/DictationController.swift` (line 195)

**Issue:** The transcript row copy confirmation lasts 1.5 seconds (`Task.sleep(for: .seconds(1.5))`), while the overlay copy confirmation lasts 1.2 seconds (`Task.sleep(for: .seconds(1.2))`). These durations should be consistent for predictable UX.

**Fix:** Unify to one constant (e.g., `Motion.copyConfirmationDuration = 1.4`) in `Motion` or `Theme.swift`.

---

### S4. Sidebar row capsule takes layout space when hidden

**File:** `Echo/UI/MainWindowView.swift` (line 168)

**Issue:** The selected-state capsule indicator uses `.opacity(isSelected ? 1 : 0)` which still occupies layout space. This means the icon and text shift 3px to the right compared to a layout where the capsule is absent. It's a minor alignment issue but goes against the "no shifting content" UX principle.

**Fix:** Use `.frame(width: isSelected ? 3 : 0)` or conditionally include/hide the capsule view to maintain stable icon positions.

---

### S5. Stat card fixed heights may cause overflow on small windows

**Files:** `Echo/UI/InsightsView.swift` (lines 74, 128)

**Issue:** The stat cards use fixed heights of 104px and 200px. On the minimum window size (720×560), with the sidebar taking 211px, the content area is 509×549. With 48px vertical padding (24 top + 24 bottom), the scrollable area is ~501px tall. Two rows of cards (104 + 16 spacing + 200 = 320px) plus the eyebrow, spacing, and extra content fit, but only barely. If content wraps due to localization or larger fonts, it will overflow the fixed frame.

**Fix:** Use `frame(minHeight:)` instead of `frame(height:)`, or use `.fixedSize(horizontal: false, vertical: true)` on the card content to let it grow naturally.

---

### S6. "View all" button hover state missing

**File:** `Echo/UI/HomeView.swift` (lines 115-125)

**Issue:** The "View all" button in the Recent section header has no hover or press state animation, unlike sidebar rows and transcript rows which do.

**Fix:** Add `@State private var isHovering` and a background change on hover, mirroring the pattern used in `SidebarRow`.

---

### S7. WaveformRibbon history array mutation triggers unnecessary view updates

**File:** `Echo/UI/WaveformRibbon.swift` (line 35)

**Issue:** The `onChange(of: level)` block calls `history.removeFirst()` and `history.append(...)` on every audio level change. Since `history` is `@State`, each mutation triggers a full body re-evaluation. At 24fps this is fine, but the `animation(.linear(duration: 0.1), value: history)` animates the *entire* array change, creating a sliding-window animated effect. This may cause unnecessary layout passes.

**Fix:** Consider using a `Timer`-based approach or `TimelineView` for the scrolling window, or using `Canvas` for direct drawing without SwiftUI layout overhead.

---

### S8. Settings microphone picker not refreshed when devices change

**File:** `Echo/Settings/SettingsView.swift` (lines 19-25, 103)

**Issue:** The microphone list is loaded once in `.onAppear { inputDevices = AudioInputDevices.all() }`. If the user plugs in a new microphone or Bluetooth device while settings are open, the list is stale. The `Picker` will show outdated data.

**Fix:** Use `.onReceive` with a notification publisher (e.g., `NSNotification.Name.AudioHardwareDevicesChanged`) to refresh the device list dynamically.

---

### S9. No visual indication that transcript text is selectable

**File:** `Echo/UI/TranscriptRow.swift` (line 21)

**Issue:** The transcript text has `.textSelection(.enabled)`, which is great for accessibility. However, there's no visual indication (e.g., cursor change on hover) that text can be selected. On macOS, `.textSelection(.enabled)` changes the cursor automatically, but only within `NSTextView` or with specific SwiftUI configurations.

**Fix:** Verify this works as expected on macOS 14+, and if not, wrap in a `TextEditor` or use `.onHover` to change the cursor to `.iBeam`.

---

### S10. Streak heatmap month labels may overlap

**File:** `Echo/UI/InsightsView.swift` (lines 285-291)

**Issue:** Month labels are positioned using `offset(x: CGFloat(columnIndex) * columnStride)` where `columnStride = cellSize + cellGap = 12`. With 18 columns spanning 18 × 12 = 216px, if two month labels fall within ~30px of each other (e.g., Jan 31 and Feb 1 adjacent in the same week), the labels will overlap because they're placed at absolute offsets without collision detection.

**Fix:** Implement collision detection: only show a month label if its column is at least 3-4 columns from the previous label, or stagger them vertically.

---

### S11. Menu bar item not state-aware beyond icon

**File:** `Echo/EchoApp.swift` (lines 30-32), `Echo/MenuContentView.swift`

**Issue:** The menu bar extra icon changes based on `controller.state.menuBarSymbol`, but the menu content always shows the static description. There's no dynamic state update in the menu items (e.g., showing "Stop Dictation" when recording).

**Fix:** Consider adding a dynamic menu item when `controller.state == .recording` that shows "Stop Dictation" with a keyboard shortcut, or show a small recording indicator in the menu.

---

## Summary

The Echo UI is well-crafted with a consistent "3D Sculpt" design system, thoughtful typography pairing (Space Grotesk + Inter + IBM Plex Mono), and tasteful motion design. The code shows careful attention to accessibility features like `reduceMotion` and `.textSelection(.enabled)`. 

The most impactful issues are **text truncation in the info cards** (C1, C2) which directly affects the first thing a user sees, and the **confusing frame modifier pattern** (C3) which could cause future layout bugs. On the interaction side, the **missing hover feedback on the overlay Copy button** (W1) and **low-contrast light-mode accent** (W2) are the most noticeable polish gaps. Several smaller suggestions around component consistency, dynamic data refresh, and edge-case handling would further elevate the app from good to excellent.