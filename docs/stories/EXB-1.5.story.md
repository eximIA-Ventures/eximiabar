# Story EXB-1.5: Settings Window

**ID:** EXB-1.5
**Status:** InReview
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
