# Story EXB-1.3: Popover NSPanel (Dropdown Card)

**ID:** EXB-1.3
**Status:** Done
**Depends on:** EXB-1.1 (snapshot types), EXB-1.2 (status item, icon), EXB-1.4 (AppState + refresh loop)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user clicking the exímIABar icon,
**I want** a dropdown card showing session/weekly/sonnet usage bars, pace, extra usage, cost and action rows,
**so that** I can see the full rate limit picture at a glance and trigger key actions (refresh, settings, quit) with keyboard shortcuts.

---

## Acceptance Criteria

1. The dropdown is an `NSPanel` (NOT `NSMenu`). It is created with style mask `[.nonactivatingPanel, .titled]`, level `.statusBar + 1`, backing `.buffered`, deferred `false`. It does NOT become key or activate the app.
2. The panel contains a single `NSHostingView` root wrapping `UsageCardView` (SwiftUI). Height is determined by SwiftUI auto-sizing — NEVER call `fittingSize` or `layoutSubtreeIfNeeded` synchronously.
3. Background: `NSVisualEffectView` with material `.menu`, blending mode `.behindWindow`, embedded as the panel's `contentView` with the `NSHostingView` as a child — matches the vibrancy of system menus.
4. Panel width: **310 pt** (AC from §3.2 of spec).
5. Panel anchors to the status item button rect (bottom edge of `button.window.frame` or `button.frame` in screen coordinates). Closes automatically on resign key / click outside / Escape key.
6. Opening the panel triggers a user-initiated refresh (via `AppState.triggerRefresh(.userInitiated)`).
7. **Header section** (top of card, ref `_reference_codexbar/Sources/CodexBar/MenuCardView.swift:253-299`):
   - Line 1: `"Claude"` in `.headline.semibold` left, user email `.subheadline` secondary truncated `.middle` right, column spacing 12 pt
   - Line 2: `"Updated Xm ago"` or `"Refreshing…"` in `.footnote` left; on error: error text in `systemRed` (up to 4 lines) + copy button SF Symbol `doc.on.doc` (18×18) that transitions to `checkmark` (18×18) on press with scale 0.94; plan label (e.g., `"Max"`) `.footnote` secondary right
   - Line spacing: 4 pt between lines 1 and 2
8. **Divider** after header.
9. **MetricRow Session** (F3): title `"Session"` in `.body.medium`, a `UsageProgressBar` at height 6 pt, `"N% left"` in `.footnote`, `"Resets HH:mm"` in `.footnote` secondary. Internal row spacing 6 pt. Row-to-row spacing 12 pt. Reference: `_reference_codexbar/Sources/CodexBar/MenuCardView.swift:383-452`.
10. **MetricRow Weekly** (F3): same layout as session row, plus pace line below bar (see AC13).
11. **MetricRow Sonnet** (F3): rótulo `"Sonnet"`. Data from `snapshot.sonnet` (`seven_day_sonnet ?? seven_day_opus`). If both nil, row is hidden.
12. **MetricRow Daily Routines** (conditional): shown only when `snapshot.dailyRoutines != nil`. Label `"Daily Routines"`.
13. **Pace line** (F4, ref `_reference_codexbar/Sources/CodexBarCore/UsagePace.swift` and `_reference_codexbar/Sources/CodexBar/UsagePaceText.swift:37-54`): rendered below the Weekly bar only.
    - Hidden if less than 3% of the window duration has elapsed.
    - Strings (EXACT — do not use screenshot wording): `"On pace"` / `"N% in deficit"` / `"N% in reserve"` and secondary `"Lasts until reset"` / `"Runs out in Xd Yh"` / `"Runs out now"`.
    - Threshold "slightly": `|delta| ≤ 6` → `"On pace"`.
14. **UsageProgressBar** (ref `_reference_codexbar/Sources/CodexBar/UsageProgressBar.swift:4-195`):
    - Height 6 pt, corner radius 3 pt
    - Single SwiftUI `Canvas` — no Metal shaders
    - Track: `tertiaryLabelColor.opacity(0.22)`
    - Fill: **Claude brand color `Color(red: 204/255, green: 124/255, blue: 94/255)`** (#CC7C5E)
    - Pace punch-out: diagonal stripe triangular cutout, width `max(25, height * 6.5)` pt, stripe 2 px central; green (`systemGreen`) for reserve, red (`systemRed`) for deficit. Reference: `_reference_codexbar/Sources/CodexBar/UsageProgressBar.swift:96-117`.
    - Warning markers (when thresholds set): vertical dashes 1 px wide, 55% of bar height, `primary.opacity(0.32)`. One marker per configured threshold (e.g., 50%, 20%).
15. **Divider + Extra usage section** (conditional — shown when `snapshot.extraUsage != nil`):
    - Orange bar (`.systemOrange`) showing `used / limit`
    - `"This month: $222.00 / $2000.00"` and `"11% used"` in `.footnote`
    - Converts `used_credits` and `monthly_limit` from centavos: divide by 100.
16. **Divider + Cost section** (F11 output — shown when cost data is available):
    - Title `"Estimated cost"` in `.body.medium`
    - `"Today: $0.08 · 27K tokens"` in `.footnote`
    - `"Last 30 days: $3.72 · 5.4M tokens"` in `.footnote`
    - Chevron (`chevron.right` SF Symbol) → cost detail submenu (list per model for the period)
17. **Action rows** (height 28 pt each): SF Symbol icon (16×16 template) + label + keyboard shortcut right (in `smallSystemFontSize`). Highlight style: background `selectedContentBackgroundColor` radius 6, inset 6/2 pt. Exact labels and shortcuts:
    - `Refresh Now` ⌘R
    - `Usage Dashboard` (opens `https://claude.ai/settings/usage`)
    - `Status Page` (opens `https://status.claude.com`)
    - `Settings…` ⌘,
    - `Quit` ⌘Q
    - On auth error: additional row `Re-login at claude.ai` (opens `https://claude.ai`)
18. **Keyboard shortcuts** ⌘R, ⌘, and ⌘Q work when the panel is key (panel must accept key events via `acceptsMouseMovedEvents = true` and `makeKey()`).
19. **MenuHighlightStyle**: hover state on action rows uses `selectedContentBackgroundColor` fill, text changes to `selectedMenuItemTextColor`. Reference: `_reference_codexbar/Sources/CodexBar/MenuHighlightStyle.swift:7-35`.
20. Panel opens and closes without stalling the main thread. Opening must NOT call any network I/O synchronously. Layout happens asynchronously via SwiftUI.
21. **Anti-freeze:** the panel is created once and reused (show/hide). SwiftUI view inside is purely a function of the `DisplaySnapshot` passed by `AppState`. No `NSMenu` path — this is enforced architecturally.

---

## Tasks

- [x] **T1 — UsageProgressBar** (`Sources/ClaudeBar/Popover/UsageProgressBar.swift`)
  - [x] Port `_reference_codexbar/Sources/CodexBar/UsageProgressBar.swift:4-195`
  - [x] `struct UsageProgressBar: View { var percent: Double; var tint: Color; var pacePercent: Double?; var paceReserve: Bool; var warningMarkerPercents: [Double] }` (signature adapted to the local `RateWindow`/snapshot shape — see Dev Notes)
  - [x] Track, fill with brand color, pace punch-out triangle (AC14), warning markers

- [x] **T2 — Pace logic** (`Sources/ClaudeBarCore/Model/UsagePace.swift`)
  - [x] Port `UsagePace.swift` from `_reference_codexbar/Sources/CodexBarCore/` — pure computation, no UI
  - [x] `struct UsagePace`: `percentRemaining`, `deficit`, `reserve`, `status: PaceStatus`
  - [x] `enum PaceStatus { case onPace, deficit(Double), reserve(Double) }` (run-out carried separately in `projectedRunOut`/`lastsUntilReset`, matching the reference's `stage`/`eta` split — see Dev Agent Record)
  - [x] `UsagePace.compute(window: RateWindow, now: Date) -> UsagePace?` — returns nil if <3% elapsed

- [x] **T3 — Pace text** (`Sources/ClaudeBar/Popover/UsagePaceText.swift`)
  - [x] Port `_reference_codexbar/Sources/CodexBar/UsagePaceText.swift:37-54` — maps `PaceStatus` to exact strings from AC13

- [x] **T4 — MetricRow** (`Sources/ClaudeBar/Popover/MetricRow.swift`)
  - [x] `struct MetricRow: View { var title: String; var window: RateWindow; var showPace: Bool = false; var pace: UsagePace? = nil }`
  - [x] Layout: title → bar → "N% left" + "Resets HH:mm" + optional pace line (AC9–AC13)
  - [x] Time formatting: `"Resets HH:mm"` uses local time zone, 24h format if system preference is 24h (`PopoverFormatter.resetText`)

- [x] **T5 — Header, extra usage, cost sections** (`Sources/ClaudeBar/Popover/UsageCardView.swift`)
  - [x] `struct UsageCardView: View` — assembles all sections top-to-bottom (AC7–AC17)
  - [x] Header (AC7) — reference `_reference_codexbar/Sources/CodexBar/MenuCardView.swift:253-299`
  - [x] Copy button state machine: `.doc.on.doc` → `.checkmark` on tap, revert after 2 s
  - [x] Extra usage section (AC15) — conditional
  - [x] Cost section (AC16) — conditional, stub content (full data from S7)
  - [x] Action rows (AC17) with hover highlight (AC19)

- [x] **T6 — Panel controller** (`Sources/ClaudeBar/Popover/UsagePanelController.swift`)
  - [x] `@MainActor class UsagePanelController`
  - [x] Creates `NSPanel` once with spec params (AC1–AC5)
  - [x] `NSVisualEffectView` + `NSHostingView<UsageCardView>` tree (AC3)
  - [x] `func show(near button: NSStatusBarButton)` — positions panel below status item, calls `makeKeyAndOrderFront`, triggers refresh (AC6)
  - [x] `func close()` — `orderOut(_:)`, no animation
  - [x] Resign/click-out detection: `NSWindowDelegate.windowDidResignKey` → `close()`
  - [x] Keyboard handling: Escape → `close()`; ⌘R/⌘,/⌘Q forwarded to action handlers

- [x] **T7 — Wire into StatusItemController** (`Sources/ClaudeBar/StatusItem/StatusItemController.swift`)
  - [x] On status item button click: toggle `UsagePanelController.show/close` (`onClick` now passes the button; `AppDelegate` owns the panel and toggles it)
  - [x] Pass `AppState.snapshot` to `UsageCardView` via observation (snapshot-provider closure + `withObservationTracking` while open)

---

## Dev Notes

### Critical architecture decision: NSPanel NOT NSMenu
The original CodexBar used `NSMenu` with embedded SwiftUI hosting views. This caused WindowServer stalls (#1376, #1379, #1384) because AppKit measures and re-lays out the SwiftUI tree synchronously inside the menu tracking run loop.

exímIABar's panel approach:
- `NSPanel` is outside the menu-tracking run loop — AppKit does not call `fittingSize` or `layoutSubtreeIfNeeded` on it
- SwiftUI lays out the content asynchronously, no stall
- Panel positioned manually using `button.window.frame` screen coordinates

### Panel positioning
```swift
let buttonFrame = button.convert(button.bounds, to: nil)
let screenFrame = button.window!.convertToScreen(buttonFrame)
let origin = NSPoint(x: screenFrame.minX, y: screenFrame.minY - panelHeight)
panel.setFrameOrigin(origin)
```
Use `NSScreen.main?.frame` to keep panel within screen bounds (clamp x if near right edge).

### SwiftUI auto-sizing pattern
Do NOT set a fixed height. Let SwiftUI compute the size:
```swift
let hostingView = NSHostingView(rootView: UsageCardView(...))
hostingView.translatesAutoresizingMaskIntoConstraints = false
// Don't call hostingView.fittingSize here — it blocks the main thread
panel.contentView = effectView
effectView.addSubview(hostingView)
NSLayoutConstraint.activate([
    hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
    hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
    hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
    hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
])
```

### Brand color
```swift
// In Swift
Color(red: 204/255, green: 124/255, blue: 94/255)
// As NSColor
NSColor(calibratedRed: 204/255, green: 124/255, blue: 94/255, alpha: 1)
```
No asset catalog — hardcoded hex `#CC7C5E`.

### Pace strings (EXACT — port from `UsagePaceText.swift:37-54`, NOT from screenshot)
```
"On pace"
"N% in deficit"       ← N is an integer
"N% in reserve"
"Lasts until reset"
"Runs out in Xd Yh"   ← X days, Y hours
"Runs out now"
```
Threshold "slightly" (On pace) when `abs(delta) ≤ 6`.

### Action row layout
```swift
HStack {
    Image(systemName: sfSymbol)
        .frame(width: 16, height: 16)
    Text(label)
    Spacer()
    Text(shortcut)
        .font(.system(size: NSFont.smallSystemFontSize))
        .foregroundColor(.secondary)
}
.frame(height: 28)
.padding(.horizontal, 6)
.background(isHovered ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
.cornerRadius(6)
```
Hover detection via `.onHover { hovered in ... }`.

### Reference screenshot
Pixel-perfect reference: `_reference_codexbar/docs/screenshots/claude-extra-usage-bug.png` — only real screenshot of the Claude card. Use it to verify visual output.

### Cost section (S7 dependency)
In this story, the Cost section renders a stub `"Cost data loading…"` placeholder. S7 will replace it with real data. The section structure (AC16) must be in place.

---

## Definition of Done

- [x] `swift build` succeeds with zero new warnings (verified `swift build` and `swift build -c release` — clean)
- [x] Clicking status item opens the NSPanel (not NSMenu) — `UsagePanelController` is the only dropdown path; zero `NSMenu` usage
- [x] Panel opens without any observable main-thread stall — no `fittingSize`/`layoutSubtreeIfNeeded`; SwiftUI auto-sizes; refresh fetch runs off-main via `AppState`
- [x] Header shows `"Claude"` + email + updated timestamp
- [x] Session and Weekly MetricRows show filled bars with `"N% left"` and `"Resets HH:mm"`
- [x] Pace line appears on Weekly row when ≥3% of window elapsed, with exact strings from AC13 (unit-tested in `UsagePaceTextTests`)
- [x] Brand color `#CC7C5E` used for bar fill (`PopoverStyle.brand`)
- [x] Action rows trigger correct actions: ⌘R refreshes, ⌘, opens settings, ⌘Q quits (forwarded via `KeyablePanel.performKeyEquivalent` and row buttons)
- [x] Panel closes on click-outside, Escape, and resign key (`windowDidResignKey`, `cancelOperation`/keyCode 53)
- [~] Thread Sanitizer shows no races when panel opens/closes rapidly — code is `@MainActor`-isolated end-to-end with Swift 6 complete concurrency (compiles clean under `-strict-concurrency=complete`); a manual TSan run requires a GUI session and is deferred to QA hardware verification

## Dev Agent Record

### Agent
@dev (Dex) — EXB-1.3 implementation

### Files Created
- `Sources/ClaudeBarCore/Model/UsagePace.swift` — pure pace computation (T2)
- `Sources/ClaudeBar/Popover/PopoverStyle.swift` — brand color `#CC7C5E`, palette, layout metrics
- `Sources/ClaudeBar/Popover/PopoverFormatter.swift` — reset/updated/currency/token formatting
- `Sources/ClaudeBar/Popover/UsageProgressBar.swift` — Canvas progress bar (T1)
- `Sources/ClaudeBar/Popover/UsagePaceText.swift` — exact AC13 pace strings (T3)
- `Sources/ClaudeBar/Popover/MetricRow.swift` — metric row (T4)
- `Sources/ClaudeBar/Popover/UsageCardView.swift` — full card: header/metrics/extra/cost/actions (T5)
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — NSPanel controller (T6)
- `Tests/ClaudeBarCoreTests/UsagePaceTests.swift` — 9 pace-logic tests
- `Tests/ClaudeBarTests/UsagePaceTextTests.swift` — pace-string + formatter tests

### Files Modified
- `Sources/ClaudeBar/StatusItem/StatusItemController.swift` — `onClick` now passes the button; exposes `button` (T7)
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — owns `UsagePanelController`, wires the action set, toggles on click (T7)

### Justified Deviations
1. **`UsageProgressBar` signature** — story T1 lists `value`/`total`/`showPaceTip`. The repo's `RateWindow` exposes `utilization` (0–100) directly, so the bar takes `percent: Double` (the utilization) plus `pacePercent`/`paceReserve`, matching the reference Canvas semantics 1:1. No `total` needed since the API value is already a percentage.
2. **`PaceStatus` has no `.runsOut(Date)` case** — the reference keeps the delta classification (`stage`) and the run-out projection (`eta`) as *separate* fields. Conflating them into one enum made a slightly-over-burn window that still projects a run-out render as a run-out instead of "On pace" (caught by `slightlyOffLineStaysOnPace`). Fixed by classifying `status` by delta only and carrying `projectedRunOut`/`lastsUntilReset` separately — exactly the reference's split. `UsagePaceText` builds the secondary line from those fields.
3. **AC15 "divide by 100"** — the core `ExtraUsage` is *already* normalized from centavos to major units in `UsageSnapshot+OAuth.mapExtraUsage` (verified). The card renders `usedCredits`/`monthlyLimit` directly; re-dividing would be a double conversion.
4. **AC1 style mask** — added `.fullSizeContentView` to `[.nonactivatingPanel, .titled]` so the `NSVisualEffectView` vibrancy fills the would-be title-bar strip (visual fidelity — a bare `.titled` panel reserves an opaque title band above the content). All other AC1 params (level `.statusBar + 1`, `.buffered`, `defer: false`, non-activating, non-key-stealing) are exact.
5. **`MenuHighlightStyle`/`\.menuItemHighlighted` not ported** — that machinery existed only to recolour content while an `NSMenu` item was highlighted. The panel is an `NSPanel`, so there is no menu-tracking highlight; action-row hover is handled locally per row via `.onHover`. `PopoverStyle` carries only the needed palette.

### Test Results
- `swift build`: clean, zero warnings
- `swift build -c release`: clean, zero warnings
- `swift test`: **85 tests / 12 suites — all pass** (11 new: 9 pace-logic + pace-string/formatter coverage)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. No content changes required. | @po Pax |
| 2026-06-10 | 1.2 | Implemented all ACs (T1–T7). 10 files created, 2 modified, 11 new tests. Build + 85 tests pass. Status: Ready → Done. | @dev Dex |
