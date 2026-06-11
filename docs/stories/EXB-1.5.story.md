# Story EXB-1.5: Settings Window

**ID:** EXB-1.5
**Status:** Done
**Depends on:** EXB-1.1 (credential models), EXB-1.4 (AppState, SettingsStore stub)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user of exímIABar,
**I want** a settings window with four panes covering general preferences, Claude-specific source and keychain options, display mode, and an about panel,
**so that** I can configure refresh interval, notifications, launch-at-login, icon style, and credential source without editing any files.

---

## Acceptance Criteria

1. Settings window size: **546×638 pt**, padding horizontal 24 pt / vertical 16 pt. Opened by ⌘, or the `Settings…` action row. Reference: spec §3.3.
2. Window uses `TabView` with `.tabViewStyle(.tabBarOnly)` or SwiftUI `Settings` scene — toolbar-style tab picker at the top. Four tabs: General, Claude, Display, About.
3. **General pane** (`_reference_codexbar/Sources/CodexBar/PreferencesGeneralPane.swift`):
   - Section headers in `.caption` secondary UPPERCASE style
   - `Launch at Login` toggle using `SMAppService.mainApp` (register on true, unregister on false)
   - `Refresh Cadence` picker (`.menu` style, `maxWidth 200`): Manual / Every 1 min / Every 2 min / Every 5 min (default) / Every 15 min / Every 30 min
   - Notifications section: enable/disable toggle + per-window (Session, Weekly) threshold pickers (multi-value: `[50, 20]` default, configurable)
   - Cost toggle (enable/disable cost scan) + day stepper 1–365 (default 30)
   - `Quit exímIABar` button in `.borderedProminent .large`
4. **Claude pane** (derived from `_reference_codexbar/Sources/CodexBar/PreferencesProviderDetailView.swift`):
   - Source picker: Auto / OAuth / CLI / Web (Web disabled/greyed in P0/P1)
   - `Keychain prompt policy` picker (3 options): `"Never"` / `"Only on user action"` (default) / `"Always"`. Visible only when `SettingsStore.useSecurityCLIReader == true`.
   - `Avoid keychain prompts` toggle (`useSecurityCLIReader`): when ON, reads credentials via `/usr/bin/security` CLI (timeout 1.5 s) instead of direct Security.framework call.
   - `Web extras` toggle (default OFF) — extra web fetch on top of OAuth; hidden as a developer option
   - `Custom claude binary path` text field (for debug)
   - Threshold warning settings per window: `QuotaWarningSettingsViews` reference: `_reference_codexbar/Sources/CodexBar/QuotaWarningSettingsViews.swift`
5. **Display pane** (`_reference_codexbar/Sources/CodexBar/PreferencesDisplayPane.swift`):
   - `Show: Used / Remaining` toggle — whether bars show consumed or remaining
   - `Reset time: Absolute / Countdown` toggle — `"Resets 14:00"` vs `"Resets in 2h 15m"`
   - `Warning markers` toggle — show/hide threshold dashes on bars
   - `Workday markers` picker: Off / 4-day / 5-day / 7-day
   - `Brand icon + %` toggle — switches `displayMode` between `.meterIcon` and `.brandIconPercent` (F2, P1)
6. **About pane** (`_reference_codexbar/Sources/CodexBar/PreferencesAboutPane.swift`):
   - App icon 92×92 pt, corner radius 16, hover scale animation 1.05
   - App name + version string (from `Bundle.main.infoDictionary`)
   - Links styled with `.accentColor`
7. Settings components:
   - `PreferenceToggleRow`: `HStack { Toggle(isOn: $binding) { Text(label) } }` with subtitle `.footnote .tertiary` spacing 5.4 pt below. Reference: `_reference_codexbar/Sources/CodexBar/PreferencesComponents.swift`.
   - `SettingsSection`: `VStack(spacing: 10)` with title `.subheadline.semibold`.
8. `SettingsStore` is a fully implemented `actor` (not a stub) that persists all settings to `UserDefaults` with debounced writes (500 ms). It uses `@Published` or `@Observable` on a `@MainActor`-isolated wrapper type that `AppState` observes.
9. `LaunchAtLoginManager`: wraps `SMAppService.mainApp.register()` / `.unregister()`. Returns current state `SMAppService.mainApp.status`. Available macOS 13+.
10. Settings window opens with `NSApp.setActivationPolicy(.regular)` while open and reverts to `.accessory` on close (LSUIElement apps need this to bring the window to front).
11. **Keychain prompt policy enforcement:** `CredentialsStore` reads `SettingsStore.keychainPromptPolicy` at runtime. If `never`: never open a keychain dialog. If `onUserAction` (default): prompt only when `RefreshPhase.userInitiated`. If `always`: prompt in any phase. No stored memoization of policy — always read current value.
12. `swift build` succeeds, zero new warnings.

---

## Tasks

- [x] **T1 — SettingsStore** (`Sources/ClaudeBar/App/SettingsStore.swift`)
  - [x] `@MainActor @Observable class SettingsStore`
  - [x] Properties: `refreshCadence: RefreshCadence`, `launchAtLogin: Bool`, `notificationsEnabled: Bool`, `sessionThresholds: [Int]`, `weeklyThresholds: [Int]`, `costEnabled: Bool`, `costDays: Int`, `source: DataSource?` (nil = auto), `keychainPromptPolicy: KeychainPromptPolicy`, `useSecurityCLIReader: Bool`, `webExtrasEnabled: Bool`, `claudeBinaryPath: String?`, `displayMode: DisplayMode`, `showUsed: Bool`, `showAbsoluteReset: Bool`, `showWarningMarkers: Bool`, `workdayMarkers: WorkdayMarkers`, `notificationSound: Bool`
  - [x] Default values per AC3–AC5
  - [x] Persist to `UserDefaults.standard` with debounce 500 ms (`Task.sleep(for: .milliseconds(500))` pattern)
  - [x] `KeychainPromptPolicy: String` raw value for UserDefaults serialization

- [x] **T2 — LaunchAtLoginManager** (`Sources/ClaudeBar/App/LaunchAtLoginManager.swift`)
  - [x] `@MainActor class LaunchAtLoginManager`
  - [x] `func set(enabled: Bool) throws` — `SMAppService.mainApp.register()` / `.unregister()`
  - [x] `var isEnabled: Bool` — `SMAppService.mainApp.status == .enabled`

- [x] **T3 — General pane** (`Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift`)
  - [x] Implement per AC3: sections with UPPERCASE headers, all controls wired to `SettingsStore`
  - [x] Launch at login calls `LaunchAtLoginManager.set(enabled:)` on toggle
  - [x] Refresh cadence picker wired to `SettingsStore.refreshCadence`
  - [x] Quit button: `NSApp.terminate(nil)`

- [x] **T4 — Claude pane** (`Sources/ClaudeBar/Settings/PreferencesClaudePane.swift`)
  - [x] Source picker; Web option disabled (greyed) — surfaced with a "not yet available (P2)" note
  - [x] Keychain prompt policy (conditional visibility — AC4)
  - [x] `useSecurityCLIReader` toggle wired to `SettingsStore`
  - [x] Web extras toggle hidden by default (inside a `DisclosureGroup("Developer")`)

- [x] **T5 — Display pane** (`Sources/ClaudeBar/Settings/PreferencesDisplayPane.swift`)
  - [x] All toggles and pickers per AC5
  - [x] Brand icon toggle updates `SettingsStore.displayMode` and immediately re-renders the status item via the `onDisplayModeChange` callback

- [x] **T6 — About pane** (`Sources/ClaudeBar/Settings/PreferencesAboutPane.swift`)
  - [x] App icon from `NSApp.applicationIconImage`
  - [x] Hover scale: `.scaleEffect(isHovered ? 1.05 : 1.0)` with `.easeInOut(duration: 0.2)`
  - [x] Version from `Bundle.main` `CFBundleShortVersionString` (+ build)
  - [x] Link to GitHub repo / LICENSE

- [x] **T7 — Shared components** (`Sources/ClaudeBar/Settings/PreferencesComponents.swift`)
  - [x] `PreferenceToggleRow` per AC7
  - [x] `SettingsSection` per AC7 (plus `SectionHeader`, `LabelledRow`, `ThresholdPairField`, `AboutLinkRow`)

- [x] **T8 — Settings window controller** (`Sources/ClaudeBar/Settings/SettingsWindowController.swift`)
  - [x] `@MainActor class SettingsWindowController`
  - [x] `func open()`: creates/shows `NSWindow` with `TabView` content; sets activation policy to `.regular`; registers `NSWindowDelegate` to revert to `.accessory` on close
  - [x] Triggered from action row `Settings…` ⌘,

---

## Dev Notes

### Activation policy dance (critical for LSUIElement apps)
When `LSUIElement = YES`, the app has no Dock icon and stays in the background. To bring a settings window to front, you must temporarily switch activation policy:

```swift
NSApp.setActivationPolicy(.regular)
NSApp.activate(ignoringOtherApps: true)
settingsWindow.makeKeyAndOrderFront(nil)
```

On window close (`windowWillClose`):
```swift
NSApp.setActivationPolicy(.accessory)
```

Without this, the settings window appears behind other apps.

### SMAppService (macOS 13+)
```swift
import ServiceManagement

SMAppService.mainApp.register()   // enable launch at login
SMAppService.mainApp.unregister() // disable

// Check status
SMAppService.mainApp.status == .enabled
```
Bundle must include `Info.plist` with correct `CFBundleIdentifier = com.eximia.eximiabar`.

### SettingsStore debounce pattern
```swift
private var saveTask: Task<Void, Never>?

private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        await persist()
    }
}

@MainActor private func persist() {
    UserDefaults.standard.set(refreshCadence.rawValue, forKey: "refreshCadence")
    // ... etc
}
```

### KeychainPromptPolicy values
```swift
enum KeychainPromptPolicy: String, CaseIterable {
    case never = "never"
    case onUserAction = "onUserAction"   // default
    case always = "always"
}
```

### Reference files
- `_reference_codexbar/Sources/CodexBar/SettingsStore.swift:6-38` — base settings; `SettingsStore+Config.swift`, `SettingsStore+Defaults.swift`
- `_reference_codexbar/Sources/CodexBar/PreferencesGeneralPane.swift`
- `_reference_codexbar/Sources/CodexBar/PreferencesDisplayPane.swift`
- `_reference_codexbar/Sources/CodexBar/PreferencesAboutPane.swift`
- `_reference_codexbar/Sources/CodexBar/PreferencesComponents.swift`
- `_reference_codexbar/Sources/CodexBar/QuotaWarningSettingsViews.swift`

### Threshold picker
Default thresholds `[50, 20]` means: warn at 50% remaining AND at 20% remaining. Display as two stepper fields or a multi-value tag input. Each is independently configurable per window (session vs weekly).

### Web extras toggle
`webExtrasEnabled` default is `false`. In the Claude pane, show it in a `DisclosureGroup("Developer")` hidden behind a click — users shouldn't normally see it. When enabled, `UsageFetcher` appends a second HTTP call to `claude.ai` for extra window enrichment (spec §4.6). For P0/P1, this fetch is stubbed out even if toggled on — just log and skip.

---

## Definition of Done

- [x] `swift build` succeeds with zero new warnings
- [x] Settings window opens at exactly 546×638 pt on ⌘, (fixed `setContentSize` + non-resizable styleMask; ⌘, routed via an installed minimal main menu)
- [x] All four panes render with correct labels and controls
- [x] `LaunchAtLogin` toggle actually registers/unregisters with `SMAppService` (via `LaunchAtLoginManager`)
- [x] Refresh cadence change causes timer restart within 1 s (`onRefreshCadenceChange` → `AppState.startRefreshTimer()`, unchanged from EXB-1.4)
- [x] Keychain prompt policy change is read by `CredentialsStore` on next fetch (runtime `promptPolicyProvider`, no memoization — `PromptPolicyTests`)
- [x] Settings survive app restart (persisted to UserDefaults — `SettingsStoreTests.settingsSurviveRestart`)
- [x] Activation policy reverts to `.accessory` when settings window closes (`windowWillClose`)

---

## Dev Agent Record

### Agent
@dev (Dex)

### File List
**New:**
- `Sources/ClaudeBar/App/LaunchAtLoginManager.swift` — `LaunchAtLoginManager` (`SMAppService.mainApp` register/unregister + status)
- `Sources/ClaudeBar/Settings/PreferencesComponents.swift` — `PreferenceToggleRow`, `SettingsSection`, `SectionHeader`, `LabelledRow`, `ThresholdPairField`, `AboutLinkRow`
- `Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift` — General pane (AC3)
- `Sources/ClaudeBar/Settings/PreferencesClaudePane.swift` — Claude pane (AC4)
- `Sources/ClaudeBar/Settings/PreferencesDisplayPane.swift` — Display pane (AC5)
- `Sources/ClaudeBar/Settings/PreferencesAboutPane.swift` — About pane (AC6)
- `Sources/ClaudeBar/Settings/SettingsRootView.swift` — 4-tab `TabView` (AC2)
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — `NSWindow` host + activation-policy dance (AC10)
- `Tests/ClaudeBarTests/SettingsStoreTests.swift` — defaults, persistence round-trip, debounce, callbacks, policy mapping (8 tests)
- `Tests/ClaudeBarCoreTests/PromptPolicyTests.swift` — `allowsPrompt(phase:)` semantics + runtime provider (5 tests)

**Modified:**
- `Sources/ClaudeBar/App/SettingsStore.swift` — replaced the EXB-1.2/1.4 stub with the full `@MainActor @Observable` store: all AC3–AC5 properties, `RefreshCadence.label`, new `KeychainPromptPolicy`/`WorkdayMarkers` enums, `UserDefaults` persistence with 500 ms debounced off-main writes, `flush()`, and `onDisplayModeChange`/`onKeychainPolicyChange` callbacks. `quotaThresholds` → `sessionThresholds`/`weeklyThresholds`.
- `Sources/ClaudeBar/App/AppState.swift` — baseline-seed notifier now reads `sessionThresholds` (rename follow-through).
- `Sources/ClaudeBar/App/LiveUsageProvider.swift` — added a `promptPolicyProvider`-based initializer; extracted `makePipeline` so both inits share the OAuth fetch closure.
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — wired `LaunchAtLoginManager`, `SettingsWindowController`, a thread-safe `PromptPolicyHolder` (lock-free off-main policy source, AC11), `onDisplayModeChange`/`onKeychainPolicyChange` hooks, a minimal main menu providing ⌘, (AC1), launch-at-login reconciliation, and termination `flush()`. Replaced the empty-`Settings`-scene `openSettings` action with the real window.
- `Sources/ClaudeBarCore/OAuth/PromptPolicy.swift` — added `.always` case + `allowsPrompt(phase:)` helper (AC11).
- `Sources/ClaudeBarCore/OAuth/CredentialsStore.swift` — `promptPolicy` constant → `promptPolicyProvider` closure read on every `load` (AC11, no memoization); added a designated provider-based initializer; legacy `promptPolicy:` init delegates to it.
- `Tests/ClaudeBarTests/AppStateTests.swift` — `SettingsStore` now constructed with an isolated `UserDefaults` suite so persistence never touches the app domain.

### IDS Decisions
- **Shared components**: ADAPTED `_reference_codexbar/.../PreferencesComponents.swift` (`PreferenceToggleRow`, `SettingsSection`, `AboutLinkRow`) for visual fidelity; CREATED `SectionHeader`/`LabelledRow`/`ThresholdPairField` (no clean reusable equivalent — `ThresholdPairField` distils the reference `QuotaWarningThresholdField` to the two-field warn-at editor AC3/AC4 need).
- **SettingsStore**: ADAPTED the in-place EXB-1.2/1.4 stub rather than creating a parallel type (the stub is referenced by `AppState`, `StatusItemController`, tests).
- **Keychain policy at runtime (AC11)**: ADAPTED Core `PromptPolicy` (added `.always` + `allowsPrompt`) and converted `CredentialsStore`'s stored policy to a `@Sendable` provider closure — the minimal change that satisfies "read current value, no memoization" without touching the actor's load order.
- **Claude pane**: the 22 KB reference `PreferencesProviderDetailView.swift` is multi-provider CodexBar scaffolding; CREATED a focused Claude-only pane covering exactly the AC4 controls rather than porting that machinery.

### Deviations
1. **`.tabViewStyle(.tabBarOnly)` (AC2).** Used the default macOS `TabView`, which already renders the toolbar-style top tab picker AC2 describes. `.tabBarOnly` is an iOS-era modifier; the macOS default *is* the top tab bar. No visual difference.
2. **⌘, routing (AC1).** An LSUIElement agent has no app menu, so a bare ⌘, key equivalent isn't delivered. Installed a minimal `NSApp.mainMenu` with a "Settings…" item bound to ⌘, that opens the window — the standard pattern for menu-bar-only apps. The popover `Settings…` action row remains the primary path.
3. **`source: .web` (AC4).** The Web source option is rendered but the binding ignores a Web selection (P2 out of scope per epic) — surfaced as greyed with a "not yet available (P2)" note, matching the disabled-greyed AC.
4. **Web extras / custom binary (AC4).** Both stubbed for P0/P1 per Dev Notes — the toggle/field persist their values; no extra fetch is wired (lands with the relevant later story).

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. No content changes required. | @po Pax |
| 2026-06-10 | 1.2 | Implemented all ACs. 98 tests pass (13 new). swift build clean (0 warnings). Status: Ready → InReview. | @dev Dex |
| 2026-06-10 | 1.3 | QA Gate CONCERNS — Status: InReview → Done. All 12 ACs verified in code; clean build (0 warnings); 98/98 tests pass; anti-freeze invariants hold. 2 non-blocking issues (stale comment + slightly weak AC11 test assertion). | @qa Quinn |
| 2026-06-11 | 1.4 | Polish — resolved both round-1 non-blocking issues: MNT-001 (stale `Settings`-scene comment rewritten to describe the inert lifecycle host) and TEST-001 (AC11 assertion strengthened from `>= 1` to exact `== loadCount`, with every load forced through keychain layer (e)). Build clean, 130 tests pass. | @dev Dex |

---

## QA Results — rodada 1

**Reviewer:** Quinn (Test Architect & Quality Advisor)
**Review Date:** 2026-06-10
**Method:** Verified against real code — every claim in the dev report independently checked. Full clean rebuild and full test suite run locally by QA (not trusting reported output).

### Gate: CONCERNS → Done

PASS with two documented non-blocking issues. The architecturally critical work (AC11 runtime keychain-policy path, anti-freeze invariants, visual fidelity) is correct and safe. Both issues are cosmetic/documentation-level.

### 1. Acceptance Criteria — all 12 verified in code

| AC | Verdict | Evidence |
|----|---------|----------|
| 1 — 546×638, padding h24/v16, ⌘, + action row | PASS | `SettingsWindowController.swift:39` `setContentSize(546×638)` + non-resizable `styleMask`; all four panes apply `.padding(.horizontal,24).padding(.vertical,16)`; ⌘, via installed minimal main menu (`ClaudeBarApp.swift:136-152`), action row via `openSettings` closure (`ClaudeBarApp.swift:168-172`). **Deviation #2 (⌘, routing) verified valid** — LSUIElement agents need an installed `mainMenu` to receive the key equivalent. |
| 2 — TabView, 4 tabs | PASS | `SettingsRootView.swift` — `TabView` with General/Claude/Display/About `.tabItem`s. **Deviation #1 (`.tabBarOnly`) verified valid** — macOS default `TabView` already renders the top tab picker; `.tabBarOnly` is an iOS-era modifier. No visual difference. |
| 3 — General pane | PASS | `PreferencesGeneralPane.swift` — UPPERCASE `SectionHeader`; launch-at-login routes through `LaunchAtLoginManager.set(enabled:)` with error-revert; `.menu` cadence picker `maxWidth 200`; session/weekly thresholds default `[50,20]`; cost toggle + 1–365 stepper; Quit `.borderedProminent .large` → `NSApp.terminate(nil)`. |
| 4 — Claude pane | PASS | `PreferencesClaudePane.swift` — source picker with Web greyed + "not yet available (P2)" note and binding that ignores `.web` (Deviation #3, valid); keychain-policy picker visible only `if settings.useSecurityCLIReader` (AC4); `useSecurityCLIReader` toggle; web-extras + custom-binary behind `DisclosureGroup("Developer")` (Deviation #4, valid — values persist, no fetch wired). |
| 5 — Display pane | PASS | `PreferencesDisplayPane.swift` — `showUsed`, `showAbsoluteReset`, `showWarningMarkers`, `workdayMarkers` `.menu` picker, brand-icon toggle flipping `displayMode` with immediate status-item re-render via `onDisplayModeChange` (`ClaudeBarApp.swift:85-88`). |
| 6 — About pane | PASS | `PreferencesAboutPane.swift` — icon 92×92, `cornerRadius(16)`, hover `scaleEffect 1.05` `.easeInOut(0.2)`, version from `CFBundleShortVersionString`/`CFBundleVersion`, accent-colored links. **Exact match** to `_reference_codexbar/.../PreferencesAboutPane.swift:38-41`. |
| 7 — Shared components | PASS | `PreferencesComponents.swift` — `PreferenceToggleRow` `VStack spacing: 5.4` / `.toggleStyle(.checkbox)` / subtitle `.footnote .tertiary`; `SettingsSection` `VStack spacing: 10` / title `.subheadline.weight(.semibold)`. **Byte-for-byte match** to reference component file (`spacing: 5.4`, `spacing: 10` confirmed in reference). |
| 8 — SettingsStore | PASS | `SettingsStore.swift` — `@MainActor @Observable final class` (matches T1; AC8 prose says "actor" but T1 governs); every listed property present with documented defaults; 500 ms debounced save coalesced into a `Sendable PersistedSnapshot` written inside `Task.detached(priority: .utility)` (off-MainActor); `flush()` for termination; `settingsSurviveRestart` test green. |
| 9 — LaunchAtLoginManager | PASS | `LaunchAtLoginManager.swift` — `SMAppService.mainApp.register()/.unregister()`, `isEnabled` via `.status == .enabled`, macOS 13+. |
| 10 — Activation-policy dance | PASS | `SettingsWindowController.swift` — `.regular` + `activate(ignoringOtherApps:)` on `open()`; `.accessory` on `windowWillClose` (also flushes settings). |
| 11 — Keychain policy at runtime | PASS | **Critical path verified.** `CredentialsStore.swift:129` reads `self.promptPolicyProvider().allowsPrompt(phase:)` inside `load()` — no memoization; legacy `promptPolicy:` init delegates to the `@Sendable` provider init (backward compatible). Core `PromptPolicy` gains `.always` + `allowsPrompt(phase:)` with correct semantics (`never`→false, `onUserAction`→userInitiated-only, `always`→true). Off-MainActor source is a lock-free `PromptPolicyHolder` (`OSAllocatedUnfairLock`), seeded at launch and kept in lock-step via `onKeychainPolicyChange`. `policyProviderIsReadPerLoad` + `keychainPolicyMapsToCorePolicy` tests green. |
| 12 — swift build, zero warnings | PASS | Full `swift package clean` + rebuild run by QA: `Build complete!`, **zero warnings, zero errors**. |

### 2. Build & Tests (run by QA)

- **`swift build`** (after `swift package clean`): clean, **0 warnings / 0 errors**. AC12 confirmed.
- **`swift test`**: **98 tests in 14 suites passed** — including the 13 new (8 SettingsStore, 5 PromptPolicy). No skips, no flakes observed.

### 3. Anti-freeze (non-negotiable) — HOLDS

- **Zero I/O on MainActor:** grep for `Data(contentsOf` / `.synchronize()` / `DispatchQueue.main.sync` / `Thread.sleep` / `contentsOfFile` across Settings + SettingsStore + LaunchManager → **zero hits**. UserDefaults writes are coalesced and dispatched off-main via `Task.detached`.
- **Keychain policy read lock-free:** `PromptPolicyHolder` uses `OSAllocatedUnfairLock`; the credential read path never hops to the MainActor.
- **NSPanel, not NSMenu:** the popover stays an `NSPanel` (`UsagePanelController`, with an in-code comment forbidding `NSMenu` for the dropdown). The only `NSMenu` in the diff is the deliberate ⌘, main-menu carrier — not the popover. Correct separation.
- **No observation storm:** `startObserving` re-registers `withObservationTracking` on a single observable property (`appState.snapshot`) per iteration — one property, one re-render.

### 4. Visual Fidelity (vs `_reference_codexbar`)

| Element | Reference value | Implementation | Match |
|---------|-----------------|----------------|-------|
| Window size | `defaultWidth 546` / `windowHeight 638` (`PreferencesView.swift`) | `546×638` hardcoded | Exact |
| `PreferenceToggleRow` | `spacing 5.4`, `.checkbox`, `.footnote .tertiary` subtitle | identical | Exact |
| `SettingsSection` | `spacing 10`, `.subheadline.weight(.semibold)` | identical | Exact |
| About icon | `92×92`, `cornerRadius 16`, `scaleEffect 1.05`, shadow `.accentColor.opacity(0.25) radius 6` | identical | Exact |
| Cadence picker | `.menu` + `maxWidth 200` | `.menu` + `maxWidth 200` | Match |
| Pane padding | reference General uses `h20/v12` | `h24/v16` | **Intentional — follows AC1 (24/16), which supersedes the older reference; applied consistently across all 4 panes.** |

### 5. Integration / Regression — no regression

- `AppState.swift` change is a pure rename follow-through (`quotaThresholds` → `sessionThresholds`); notification double-crossing tests (`crossedThresholdReturnsMostSevereOnDoubleCrossing`, `thresholdFiresOnceOnCrossing`, `thresholdRefiresAfterRecovery`, `depletedThenRestoredFires`) all green → EXB-1.4 behavior preserved.
- **No POST to refresh endpoint added:** `pipelineNeverRunsWebSource` green; source binding `case .web: break`; `hasWebSession: false`; refresh-ownership suite (`claudeCLIOwnerNeverCallsRefreshEndpoint`, `claudebarOwnerCallsRefreshEndpointDirectly`) green.
- `utilization` 0–100 untouched (error placeholder still `utilization: 0`).
- Scope: committed change set exactly matches the story File List (17 source/test files). Uncommitted working-tree changes are only the pre-existing EXB-1.1/1.2/1.3 story docs — not application source, no scope violation.

### Issues (non-blocking)

| id | severity | finding | suggested_action |
|----|----------|---------|------------------|
| MNT-001 | low | **RESOLVED (2026-06-11, round 2 polish).** `ClaudeBarApp.swift:28-34` still declares `Settings { EmptyView() }` as the SwiftUI `App` body scene, and the comment on line 30 ("the real settings window arrives in EXB-1.5") is now stale. The real window is driven imperatively by `SettingsWindowController`; the empty `Settings` scene is functionally inert (no openable content), so there is no conflict — but it is latent ambiguity + dead documentation. | Remove the empty `Settings` scene (replace the App body with a no-window `MenuBarExtra`/agent-only scene if SwiftUI requires a body), or update the stale comment to state the scene is an inert lifecycle host. Cleanup item for a later story. |
| TEST-001 | low | **RESOLVED (2026-06-11, round 2 polish).** `PromptPolicyTests.policyProviderIsReadPerLoad` asserts `reads.value >= 1` after two loads. This proves the provider is not captured-once-at-init, but is slightly weaker than asserting the policy is re-sampled on *every single* load. Production code clearly re-reads per `load()` (CredentialsStore:129), so the behavior is correct; only the assertion is loose. | Strengthen the test to assert a fresh read on each `load` that reaches layer (e) (e.g. count == number of (e)-reaching loads), for tighter regression protection on the no-memoization guarantee. |

### Decision

Gate: **CONCERNS** — approved to Done with the two low-severity items documented for follow-up. Handoff: @devops `*push`.

---

## Polish — round 2 (2026-06-11, @dev Dex)

Both round-1 non-blocking issues resolved.

### MNT-001 (low) — stale `Settings`-scene comment — RESOLVED

`Sources/ClaudeBar/App/ClaudeBarApp.swift` — chose the comment-update option (removing the empty `Settings` scene risks SwiftUI requiring a non-empty `App` body; the scene is functionally inert, so the surgical fix is to make the documentation accurate). The comment now states the empty `Settings` scene is an **inert lifecycle host** with no openable content, and that the real settings window is driven imperatively by `SettingsWindowController` (opened via the popover `Settings…` action row and the ⌘, key equivalent on the installed main menu). No behaviour change.

### TEST-001 (low) — weak AC11 assertion — RESOLVED

`Tests/ClaudeBarCoreTests/PromptPolicyTests.swift` — replaced `policyProviderIsReadPerLoad` (asserted `reads.value >= 1`) with `policyProviderIsReadOnEveryLoadReachingKeychain`, which asserts the **exact** read count: `reads.value == loadCount`. The store is built over an empty home directory (no env token, no cache, no credentials file) so every `load` falls through layers (a)–(d) straight into keychain layer (e), where the policy provider is consulted (`CredentialsStore.load`, line 129) exactly once per call before `loadFromClaudeKeychain`. `invalidateCaches()` between loads drops any record a host `"Claude Code-credentials"` item might produce, so no load short-circuits at the in-memory layer (b) — making the read count deterministic at exactly `loadCount` regardless of host keychain state. This is the tight no-memoization regression guard QA requested (strictly stronger than `>= 1`).

### Build & Tests (re-run)

- `swift build`: clean, zero warnings.
- `swift test`: **130 tests / 18 suites — all pass.** No regressions — `SettingsStoreTests`, `PromptPolicyTests`, `AppStateTests`, `RefreshOwnershipTests` (incl. `claudeCLIOwnerNeverCallsRefreshEndpoint`) all green.

### Files Modified (round 2)
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — `Settings`-scene comment (MNT-001).
- `Tests/ClaudeBarCoreTests/PromptPolicyTests.swift` — AC11 test strengthened to exact-count (TEST-001).

VERDICT (round 2): MNT-001 + TEST-001 RESOLVED.
