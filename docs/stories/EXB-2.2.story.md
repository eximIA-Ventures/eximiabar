# Story EXB-2.2: Language Selector — Localization (en + pt-BR)

**ID:** EXB-2.2
**Status:** Ready for Review
**Depends on:** EXB-1.5 (Settings window + SettingsStore), EXB-1.3 (popover strings), EXB-1.4 (notifications)
**Epic:** EPIC-EXB
**Wave:** Onda 4 (v1.1.0)
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user who prefers Portuguese (or English) regardless of their system language,
**I want** a "Language / Idioma" picker in Settings → General with System, English, and Português (Brasil) options,
**so that** all visible strings in the app reflect my preferred language immediately.

---

## Acceptance Criteria

1. `Package.swift` declares `defaultLocalization: "en"` on the `ClaudeBar` target.
2. Two `Localizable.strings` files exist: `en.lproj/Localizable.strings` and `pt-BR.lproj/Localizable.strings`. Every user-visible string in the app (popover, settings, notifications, About panel, action row labels) has a key in both files.
3. Settings → General contains a `Picker` labelled `"Language"` / `"Idioma"` with three options: `"System"` / `"Sistema"`, `"English"`, `"Português (Brasil)"`. The picker itself must be localizable (its label adapts to the current language).
4. The selected language is persisted in `UserDefaults` under key `"appLanguage"` as a `String` (`"system"`, `"en"`, `"pt-BR"`). Default is `"system"`.
5. Switching from the current language to a different one applies via one of the two accepted mechanisms (chosen in implementation — see Dev Notes): **Option A** — immediate in-process switch using `Bundle` override; **Option B** — relaunch with a confirmation dialog. Whichever is chosen, the behavior must be documented in a code comment in `SettingsStore.swift`.
6. If Option B (relaunch) is implemented: a confirmation alert appears with "Restart Now" / "Reiniciar Agora" and "Later" / "Depois" buttons; the app relaunches via `Process` (reopen via `NSWorkspace.open(Bundle.main.bundleURL)`); the stored language takes effect on next launch.
7. If Option A (in-process) is implemented: all visible strings update without relaunch; the localized bundle must be found at runtime for the SwiftPM `.app` bundle layout.
8. All string keys follow the convention `"<screen>.<element>"` (e.g., `"popover.refresh_now"`, `"settings.general.language"`).
9. The About panel and menu bar tooltip (if any) are also localized.
10. `swift build` succeeds with zero new warnings.
11. `swift test` passes with zero regressions.

---

## Tasks

- [x] **T1 — Package.swift defaultLocalization** (AC1)
  - [x] Add `defaultLocalization: "en"` — at the `Package(…)` initializer, the SwiftPM-correct location that enables localized resources on the `ClaudeBar` target (no per-target `defaultLocalization` parameter exists)

- [x] **T2 — Localizable.strings files** (AC2, AC8)
  - [x] Create `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` (129 keys)
  - [x] Create `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` (129 keys — exact parity)
  - [x] Audited all hardcoded user-visible strings across: `UsageCardView.swift`, `MetricRow.swift`, `UsagePaceText.swift`, `PopoverFormatter.swift`, all 4 settings panes + `PreferencesComponents`, `QuotaNotifier.swift`, `StatusItemController.swift` tooltip, `ClaudeBarApp.swift` menu, `SettingsWindowController.swift` title, `SettingsStore.swift` enum labels
  - [x] Added `.copy("Resources/en.lproj")` and `.copy("Resources/pt-BR.lproj")` to Package.swift resources

- [x] **T3 — Replace hardcoded strings with localized lookups** (AC2)
  - [x] Wrapped every user-visible string with `L("key")` / `L("key", args…)` (custom in-process engine — see Dev Agent Record)
  - [x] Positional formats use `%1$@`/`%2$d` so argument order survives translation

- [x] **T4 — SettingsStore: language preference** (AC4, AC5)
  - [x] Added `var appLanguage: AppLanguage` to `SettingsStore` (`@Observable`, default `.system`)
  - [x] Persisted via `UserDefaults` key `"appLanguage"` (stable, un-namespaced — read directly by the engine)
  - [x] Documented Option A mechanism with code comment on `appLanguage`

- [x] **T5 — Settings → General picker** (AC3)
  - [x] Added `Picker(L("settings.general.language"), …)` to the General pane (System section)
  - [x] Three options: `.system`/`.english`/`.portuguese` with labels resolved through `L(…)` (picker is itself localizable)

- [x] **T6 — Language switch mechanism** (AC5/AC7 — Option A)
  - [x] In-process switch: `appLanguage.didSet` resets the bundle cache; `SettingsRootView.id(appLanguage)` forces SwiftUI to rebuild every localized body immediately; status item + main menu repaint via `onAppLanguageChange`. No relaunch, no dialog.

- [x] **T7 — Build + regression** (AC10, AC11)
  - [x] `swift build` (debug + `-c release`) zero warnings
  - [x] `swift test` 139/139 passing (130 pre-existing + 9 new localization tests), zero regressions

---

## Dev Notes

### SwiftPM localization layout
In a SwiftPM `.app`, `.lproj` folders must be declared as resources:
```swift
.executableTarget(
    name: "ClaudeBar",
    resources: [
        .copy("Resources/en.lproj"),
        .copy("Resources/pt-BR.lproj"),
        // existing resources...
    ]
)
```
`NSLocalizedString` uses `Bundle.main` by default, which in the built `.app` points to `Contents/Resources/`. The `.lproj` folders must land there for the lookup to work.

### Option A vs Option B — trade-offs
- **Option A (in-process):** Override `Bundle.main` by swapping to a custom `Bundle` subclass that redirects resource lookups to the selected `.lproj`. Clean UX (immediate), but SwiftPM apps have a non-standard bundle layout that may complicate `Bundle` subclassing. Risk: localized XIB/NIB resources (none used here) would not reload.
- **Option B (relaunch):** Simpler and 100% reliable for a SwiftPM-packaged app. Standard macOS pattern (used by many utilities). The confirmation dialog is a one-time friction. **Recommended for this app.**

### NSLocalizedString pattern
```swift
// Simple
let label = NSLocalizedString("popover.refresh_now", comment: "Refresh Now action row label")

// With parameter
let msg = String(format: NSLocalizedString("notification.quota_warning", comment: "Quota warning: %@ remaining"), remaining)
```

### Notification strings (QuotaNotifier)
`UNNotificationContent.title` and `body` accept plain strings — wrap them with `NSLocalizedString` before assigning.

### Strings to localize (non-exhaustive starting point)
```
popover.refresh_now           = "Refresh Now"            / "Atualizar Agora"
popover.usage_dashboard       = "Usage Dashboard"        / "Painel de Uso"
popover.status_page           = "Status Page"            / "Página de Status"
popover.settings              = "Settings…"              / "Preferências…"
popover.quit                  = "Quit"                   / "Encerrar"
popover.refreshing            = "Refreshing…"            / "Atualizando…"
popover.updated_ago           = "Updated %@ ago"         / "Atualizado há %@"
settings.general.language     = "Language"               / "Idioma"
settings.general.language.system = "System"              / "Sistema"
```

### Anti-freeze invariants (unchanged)
No language switching code should run on MainActor with blocking calls. `NSWorkspace.open` is non-blocking.

---

## Definition of Done

- [x] `Package.swift` has `defaultLocalization: "en"`
- [x] `en.lproj/Localizable.strings` and `pt-BR.lproj/Localizable.strings` exist and are complete (129 keys each, exact parity)
- [x] All user-visible strings in popover, settings, notifications, and About are localized
- [x] Language picker present in Settings → General with three options
- [x] Switching language works — immediate, in-process (Option A), no relaunch
- [x] Selected language persists across app restarts via UserDefaults (`"appLanguage"`)
- [x] `swift build` zero new warnings (debug + release)
- [x] `swift test` zero regressions (139/139)

---

## Dev Agent Record

### Agent
Dex (@dev) — full implementation, Option A in-process localization.

### Implementation summary
Full en + pt-BR localization via a custom in-process engine (`L(…)`), **Option A** (immediate switch,
no relaunch). The engine, `ClaudeBar/App/Localization.swift`, is **ADAPTED** from the reference
`_reference_codexbar/Sources/CodexBar/Localization.swift` — the proven pattern for this exact SwiftPM
`.app` bundle layout: a `.lproj` bundle resolved from the package resource bundle
(`ClaudeBar_ClaudeBar.bundle`), cached behind a lock with the disk lookup outside the critical section
(anti-freeze), re-resolving transparently when the language changes. Renamed Codex→Claude, the catalog
trimmed to the three languages this app ships (System / English / Português Brasil), and the
reference's `UsageFormatter` provider hooks dropped (exímIABar formats inline via `PopoverFormatter`).

### IDS decisions
- **`Localization.swift` engine** → **ADAPT** from `_reference_codexbar` (proven; rebrand + trim).
- **`AppLanguage` enum** → **ADAPT** the reference enum, trimmed to 3 cases (story AC3).
- **`Localizable.strings`** → **CREATE** (story AC8 mandates `<screen>.<element>` keys; the reference
  uses full-sentence keys — incompatible). EN values are the **exact** literals the app shipped with
  through Onda 1–3, so the existing string-comparing tests stay green in the default (English) locale.
- **`appLanguage` persistence** → **ADAPT** the existing `SettingsStore` debounced-save pattern.

### `[AUTO-DECISION]` Option A vs B
Story Dev Notes recommend Option B (relaunch), but the reference proves Option A works flawlessly for
the SwiftPM `.app` layout and the test harness validates it. Chose **Option A** (in-process):
`L(…)` reads the active `.lproj`; flipping `settings.appLanguage` resets the bundle cache and
`SettingsRootView.id(appLanguage)` forces SwiftUI to rebuild every localized body immediately. Superior
UX (no relaunch, no dialog). AC5/AC7 satisfied; AC6 is N/A by its own conditional wording.

### Test stability note
EN `.strings` values are byte-for-byte the prior literals, so `UsagePaceTextTests`,
`MenuBarDisplayTextTests`, and `PopoverFormatterTests` required **no edits** — they pass unchanged
because the localization engine resolves the English base in the test process (a test seam in
`Localization.swift` forces `"en"` unless a test explicitly sets `appLanguage`/the `@TaskLocal`
override). Net: no existing string-comparing test was weakened. 9 new tests added in
`LocalizationTests.swift` exercise pt-BR resolution, the in-process switch, positional formats,
fallback, and the `appLanguage` persistence round-trip.

### Validation
- `swift build` — Build complete, **zero warnings** (debug).
- `swift build -c release` — Build complete, **zero warnings**.
- `swift test` — **139 tests in 20 suites passed** (130 pre-existing + 9 new). Zero regressions.
  - Note: `PromptPolicyTests.policyProviderIsReadOnEveryLoadReachingKeychain` (a `ClaudeBarCore` test,
    untouched by this story) flaked once on the **first** run after a rebuild due to the macOS keychain
    ACL one-time slow path (epic risk R4); deterministically green on every subsequent run and on clean
    `main`. Not a regression from this story.

### File List
**Created:**
- `Sources/ClaudeBar/App/Localization.swift` — in-process localization engine (`L(…)` + cached bundle resolver)
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — English base table (129 keys)
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — Português (Brasil) table (129 keys)
- `Tests/ClaudeBarTests/LocalizationTests.swift` — 9 localization + appLanguage-persistence tests

**Modified:**
- `Package.swift` — `defaultLocalization: "en"` + `.copy` of both `.lproj` resources
- `Sources/ClaudeBar/App/SettingsStore.swift` — `AppLanguage` enum, `appLanguage` property + persistence + Option A `didSet`, `onAppLanguageChange` callback; `RefreshCadence`/`KeychainPromptPolicy`/`WorkdayMarkers` labels via `L(…)`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — localized `Settings…` menu item; `onAppLanguageChange` wiring (repaint status item + menu)
- `Sources/ClaudeBar/Popover/UsageCardView.swift` — header, status, metrics, extra usage, cost, action rows localized
- `Sources/ClaudeBar/Popover/MetricRow.swift` — `% left` + usage accessibility label localized
- `Sources/ClaudeBar/Popover/UsagePaceText.swift` — pace primary/secondary + duration strings localized
- `Sources/ClaudeBar/Popover/PopoverFormatter.swift` — `Resets`/`Updated …` strings localized
- `Sources/ClaudeBar/Notifications/QuotaNotifier.swift` — `WindowKind.label` + notification title/bodies localized
- `Sources/ClaudeBar/StatusItem/StatusItemController.swift` — tooltip + accessibility title localized
- `Sources/ClaudeBar/Settings/SettingsRootView.swift` — tab labels localized + `.id(appLanguage)` for instant switch
- `Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift` — Language picker (AC3) + all strings localized
- `Sources/ClaudeBar/Settings/PreferencesClaudePane.swift` — source/keychain/developer strings localized
- `Sources/ClaudeBar/Settings/PreferencesDisplayPane.swift` — menu-bar/menu-content strings localized
- `Sources/ClaudeBar/Settings/PreferencesAboutPane.swift` — name/version/tagline/links/attribution localized
- `Sources/ClaudeBar/Settings/PreferencesComponents.swift` — threshold-field Upper/Lower/Apply labels localized
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — window title localized

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-11 | 1.0 | Initial draft — Onda 4 (v1.1.0) | @sm River |
| 2026-06-11 | 1.1 | Full en + pt-BR localization (Option A in-process). 129-key parity, 9 new tests, 139/139 green, zero warnings. | @dev Dex |
