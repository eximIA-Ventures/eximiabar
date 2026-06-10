# Story EXB-1.2: Status Item + Menu Bar Icon

**ID:** EXB-1.2
**Status:** Ready
**Depends on:** EXB-1.1 (provides `UsageSnapshot`, `RateWindow`)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** macOS user with exímIABar running,
**I want** a live meter icon in the menu bar that visually encodes my Claude session and weekly usage at a glance,
**so that** I can see my rate limit status without opening any window.

---

## Acceptance Criteria

1. The app is a `LSUIElement` agent (no Dock icon, no app menu) — set `LSUIElement = YES` in `Info.plist` and `NSPrincipalClass = NSApplication`.
2. `NSStatusItem` is created with `.variableLength`. `button.imageScaling = .scaleNone`.
3. The icon is rendered at 18×18 pt logical size, drawn into an `NSBitmapImageRep` at 2× scale (36×36 px), resulting in an `NSImage` with `isTemplate = true`. The system tints it automatically with `labelColor` in both light and dark mode.
4. Pixel grid: all coordinates snapped to 0.5 pt. Two horizontal bars:
   - Session bar: `RectPx(x:3, y:19, w:30, h:12)` (in the 36×36 bitmap)
   - Weekly bar: `RectPx(x:3, y:5, w:30, h:8)`
   - Both have **corner radius 0** (Claude style — blocky, not rounded).
5. Fill proportional to `remaining/100` — a bar at 87.5% remaining is 87.5% filled from the left.
6. Visual layer ordering per pixel (α blending with `.clear` for cutouts — no opacity trickery): track fill `labelColor` α0.28, track stroke 1 pt `labelColor` α0.44, progress fill `labelColor` α1.0.
7. Stale state (last successful fetch > 5 min ago): fill α0.55, stroke α0.28, track α0.18.
8. Error state: icon dims to the stale alphas.
9. Crab cutouts drawn with blend mode `.clear` over the filled icon (these are transparent "holes"):
   - Lateral arms: 3 px wide each side of both bars
   - 4 legs: 2×3 px each, below the weekly bar
   - Eyes: 2×5 px vertical slots on the session bar, "close" from top on blink (P2 — implement the static shape; skip blink animation)
   Exact coordinates: reference `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:257-336` (Claude style block, lines 257–336).
10. Weekly bar absent (no `seven_day` data): render bar dimmed at α0.45. Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:671-710`.
11. Incident overlay (P2 features, but shape must be present for toggle): minor incident = 4 pt filled circle in the lower-right corner; major = "!" glyph (2×6 rect + 2×2 dot). Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:935-968`. For P0/P1 builds, overlay is always hidden.
12. LRU icon cache: 64 slots, keyed by a quantized state tuple (utilization quantized to 0.1% steps, stale bool, error bool). Cache hit returns existing `NSImage` without re-rendering. Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:31-70`.
13. **Brand icon + % mode (F2, P1):** when `displayMode == .brandIcon`, the status item shows the Claude SVG template icon (16×16 from `Resources/ProviderIcon-claude.svg`) plus a title string `" 87%"` (session remaining) or `"87% · +5%"` if pace >0. Reference: `_reference_codexbar/Sources/CodexBar/MenuBarDisplayText.swift:4-37` and `ProviderBrandIcon.swift`.
14. Icon updates are dispatched on the main thread. The `IconRenderer` class itself is stateless (pure function per render call) — it MUST NOT hold `@MainActor` state.
15. **Anti-freeze:** `IconRenderer` does all drawing in an `NSBitmapImageRep` context off-main, returns the completed `NSImage`. The `StatusItemController` receives the image and sets `button.image` on MainActor only.
16. `swift build` for the `ClaudeBar` target succeeds, zero new warnings.

---

## Tasks

- [ ] **T1 — App scaffold** (`Sources/ClaudeBar/App/`)
  - [ ] `ClaudeBarApp.swift`: `@main struct ClaudeBarApp: App` body creates `AppState` and `StatusItemController`. In `applicationDidFinishLaunching`: create `NSStatusItem`, wire `AppState` observer.
  - [ ] `Info.plist`: `LSUIElement = YES`, `CFBundleIdentifier = com.eximia.eximiabar`, `NSPrincipalClass = NSApplication`
  - [ ] `AppState.swift` stub (minimal — `@MainActor @Observable class AppState`; `var snapshot: DisplaySnapshot? = nil`). Full implementation in S4.

- [ ] **T2 — IconRenderer** (`Sources/ClaudeBar/StatusItem/IconRenderer.swift`)
  - [ ] Port the Claude-style render block from `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:257-336` into a new file. Adapt: rename `Codex` → `ClaudeBar`; remove multi-provider dispatch; keep only the Claude variant.
  - [ ] Implement `renderIcon(session: RateWindow?, weekly: RateWindow?, isStale: Bool, hasError: Bool) -> NSImage` as a static function
  - [ ] Implement LRU cache (64 slots, 0.1% quantization) around the static renderer (AC12)
  - [ ] Implement weekly-absent dim logic (AC10)
  - [ ] Implement static crab cutout shapes (AC9) — blink animation deferred to P2

- [ ] **T3 — Brand icon mode** (`Sources/ClaudeBar/StatusItem/`)
  - [ ] `ProviderBrandIcon.swift`: load `Resources/ProviderIcon-claude.svg` as `NSImage` with `isTemplate = true`
  - [ ] `MenuBarDisplayText.swift`: `func displayText(session: RateWindow?, pace: Double?) -> String?` — returns `" 87%"` or `"87% · +5%"` per AC13. Reference: `_reference_codexbar/Sources/CodexBar/MenuBarDisplayText.swift:4-37`
  - [ ] Add `Resources/ProviderIcon-claude.svg` — copy from `_reference_codexbar/Sources/CodexBar/Resources/ProviderIcon-claude.svg`

- [ ] **T4 — StatusItemController** (`Sources/ClaudeBar/StatusItem/StatusItemController.swift`)
  - [ ] `@MainActor class StatusItemController`
  - [ ] Creates `NSStatusItem` with `.variableLength` (AC2)
  - [ ] `func update(snapshot: DisplaySnapshot?)`: calls `IconRenderer.render(...)` off-main via `Task.detached`, then `await MainActor.run { button.image = ... }`
  - [ ] Respects `displayMode` setting from `SettingsStore` (stub: default `.meterIcon`; full wiring in S5)
  - [ ] Click on status item triggers popover show (hook only — popover implementation in S3)

- [ ] **T5 — Incident overlay stubs**
  - [ ] Add `renderIncidentOverlay(minor: Bool, major: Bool) -> NSImage` function; always returns `nil` for P0/P1 (AC11 shape code present but toggled off)

---

## Dev Notes

### Icon coordinate system
The icon is drawn in a 36×36 px bitmap (2× of the 18×18 pt logical size). All measurements in the spec and reference code are in **pixels in this 36×36 bitmap**:
- Session bar: origin (3, 19), size 30×12 px
- Weekly bar: origin (3, 5), size 30×8 px
Note the coordinate origin is bottom-left in Core Graphics (macOS), so y=5 from the bottom.

### Reference file to port
`_reference_codexbar/Sources/CodexBar/IconRenderer.swift` — this is a large file (~1000 lines). You need:
- Lines 31–70: LRU cache implementation
- Lines 257–336: Claude-specific crab shape (braços, pernas, olhos)
- Lines 671–710: weekly-absent dim logic
- Lines 935–968: incident overlay shapes

For the rest of the file (other providers, stacked icon, etc.) — skip entirely.

### Template image behavior
`image.isTemplate = true` makes AppKit automatically tint the icon with the current `labelColor`. Do NOT set any explicit color in the icon — paint everything with `NSColor.black` (or `.labelColor`) at full alpha; template mode handles dark/light inversion.

### LRU cache key quantization
Quantize `remaining` to 0.1% steps: `let key = (Int(session.remaining * 10), Int(weekly.remaining * 10), isStale, hasError)`. This gives 1001 × 1001 × 2 × 2 theoretical states but realistically ~100 live entries.

### SVG icon
`ProviderIcon-claude.svg` must be in the app bundle `Resources/` directory. Reference the original at `_reference_codexbar/Sources/CodexBar/Resources/ProviderIcon-claude.svg`. In `Package.swift`, declare it under `.resources: [.copy("Resources/")]`.

### DisplayMode enum
```swift
enum DisplayMode {
    case meterIcon          // F1 — two-bar crab icon
    case brandIconPercent   // F2 — Claude SVG + text
}
```
Store in `SettingsStore` (stub in this story, full in S5).

### Anti-freeze pattern for this story
```swift
// CORRECT: render off-main, update on-main
Task.detached(priority: .userInitiated) {
    let image = IconRenderer.render(session: snap.session, weekly: snap.weekly, ...)
    await MainActor.run { self.button.image = image }
}
// WRONG:
// MainActor: let image = IconRenderer.render(...) ← blocks main thread
```

---

## Definition of Done

- [ ] `swift build` succeeds with zero new warnings
- [ ] App launches as LSUIElement (no Dock icon) with meter icon visible in menu bar
- [ ] Icon correctly fills session and weekly bars proportionally when given mock snapshot data
- [ ] Stale state (α reduction) visually distinct from active state
- [ ] LRU cache avoids re-rendering when called with same quantized state twice consecutively
- [ ] Brand icon mode renders Claude SVG + percentage string in status bar
- [ ] `IconRenderer.render(...)` is callable from a background thread without data races (Thread Sanitizer clean)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. No content changes required. | @po Pax |
