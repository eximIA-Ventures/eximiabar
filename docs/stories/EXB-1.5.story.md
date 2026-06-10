# Story EXB-1.5: Settings Window

**ID:** EXB-1.5
**Status:** Ready
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

- [ ] **T1 — SettingsStore** (`Sources/ClaudeBar/App/SettingsStore.swift`)
  - [ ] `@MainActor @Observable class SettingsStore`
  - [ ] Properties: `refreshCadence: RefreshCadence`, `launchAtLogin: Bool`, `notificationsEnabled: Bool`, `sessionThresholds: [Int]`, `weeklyThresholds: [Int]`, `costEnabled: Bool`, `costDays: Int`, `source: DataSource?` (nil = auto), `keychainPromptPolicy: KeychainPromptPolicy`, `useSecurityCLIReader: Bool`, `webExtrasEnabled: Bool`, `claudeBinaryPath: String?`, `displayMode: DisplayMode`, `showUsed: Bool`, `showAbsoluteReset: Bool`, `showWarningMarkers: Bool`, `workdayMarkers: WorkdayMarkers`, `notificationSound: Bool`
  - [ ] Default values per AC3–AC5
  - [ ] Persist to `UserDefaults.standard` with debounce 500 ms (`Task.sleep(for: .milliseconds(500))` pattern)
  - [ ] `KeychainPromptPolicy: String` raw value for UserDefaults serialization

- [ ] **T2 — LaunchAtLoginManager** (`Sources/ClaudeBar/App/LaunchAtLoginManager.swift`)
  - [ ] `@MainActor class LaunchAtLoginManager`
  - [ ] `func set(enabled: Bool) throws` — `SMAppService.mainApp.register()` / `.unregister()`
  - [ ] `var isEnabled: Bool` — `SMAppService.mainApp.status == .enabled`

- [ ] **T3 — General pane** (`Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift`)
  - [ ] Implement per AC3: sections with UPPERCASE headers, all controls wired to `SettingsStore`
  - [ ] Launch at login calls `LaunchAtLoginManager.set(enabled:)` on toggle
  - [ ] Refresh cadence picker wired to `SettingsStore.refreshCadence`
  - [ ] Quit button: `NSApp.terminate(nil)`

- [ ] **T4 — Claude pane** (`Sources/ClaudeBar/Settings/PreferencesClaudePane.swift`)
  - [ ] Source picker; Web option disabled with `.disabled(true)` and tooltip `"P2 — not yet available"`
  - [ ] Keychain prompt policy (conditional visibility — AC4)
  - [ ] `useSecurityCLIReader` toggle wired to `SettingsStore`
  - [ ] Web extras toggle hidden by default (show if developer mode?)

- [ ] **T5 — Display pane** (`Sources/ClaudeBar/Settings/PreferencesDisplayPane.swift`)
  - [ ] All toggles and pickers per AC5
  - [ ] Brand icon toggle updates `SettingsStore.displayMode` and immediately calls `StatusItemController.updateIcon()`

- [ ] **T6 — About pane** (`Sources/ClaudeBar/Settings/PreferencesAboutPane.swift`)
  - [ ] App icon from `NSApp.applicationIconImage`
  - [ ] Hover scale: `.scaleEffect(isHovered ? 1.05 : 1.0).animation(.easeInOut(duration: 0.2), value: isHovered)`
  - [ ] Version from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
  - [ ] Link to GitHub repo / LICENSE

- [ ] **T7 — Shared components** (`Sources/ClaudeBar/Settings/PreferencesComponents.swift`)
  - [ ] `PreferenceToggleRow` per AC7
  - [ ] `SettingsSection` per AC7

- [ ] **T8 — Settings window controller** (`Sources/ClaudeBar/Settings/SettingsWindowController.swift`)
  - [ ] `@MainActor class SettingsWindowController`
  - [ ] `func open()`: creates/shows `NSWindow` with `TabView` content; sets activation policy to `.regular`; registers `NSWindowDelegate` to revert to `.accessory` on close
  - [ ] Triggered from action row `Settings…` ⌘,

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

- [ ] `swift build` succeeds with zero new warnings
- [ ] Settings window opens at exactly 546×638 pt on ⌘,
- [ ] All four panes render with correct labels and controls
- [ ] `LaunchAtLogin` toggle actually registers/unregisters with `SMAppService`
- [ ] Refresh cadence change causes timer restart within 1 s (test by changing in settings)
- [ ] Keychain prompt policy change is read by `CredentialsStore` on next fetch
- [ ] Settings survive app restart (persisted to UserDefaults)
- [ ] Activation policy reverts to `.accessory` when settings window closes (no lingering Dock icon)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. No content changes required. | @po Pax |
