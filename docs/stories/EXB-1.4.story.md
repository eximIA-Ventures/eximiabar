# Story EXB-1.4: AppState + Refresh Loop + Notifications

**ID:** EXB-1.4
**Status:** InReview (QA CONCERN resolved — threshold double-crossing fixed)
**Depends on:** EXB-1.1 (FetchPipeline, UsageSnapshot), EXB-1.2 (StatusItemController stub)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user running exímIABar,
**I want** the app to automatically refresh usage data on a configurable timer, update the icon in real time, and notify me when my quota crosses configured thresholds,
**so that** I always see current data without manual intervention.

---

## Acceptance Criteria

1. `AppState` is a `@MainActor @Observable class` with **fewer than 300 lines**. Its only public state property is `var snapshot: DisplaySnapshot?` (an immutable struct). All fetch logic lives in `ClaudeBarCore`.
2. `DisplaySnapshot` is an immutable `struct` (value type) containing everything the UI needs: `session: RateWindow?`, `weekly: RateWindow?`, `sonnet: RateWindow?`, `dailyRoutines: RateWindow?`, `extraUsage: ExtraUsage?`, `cost: ProviderCost?`, `plan: ClaudePlan`, `identity: (name: String?, email: String?)`, `updatedAt: Date`, `source: DataSource`, `error: UsageError?`, `isRefreshing: Bool`. One assignment to `AppState.snapshot` renders the entire UI.
3. Refresh is driven by a **cancellable `Task` using `Task.sleep`** — NOT a `Timer` or `DispatchSourceTimer` on main. The task loops: sleep → trigger fetch → update snapshot → repeat.
4. **TaskLocal `RefreshPhase`** enum: `startup`, `background`, `userInitiated`. Controls: (a) whether keychain prompts are allowed, (b) whether the 429 rate-limit gate is bypassed (user-initiated only), (c) whether notifications are posted.
5. **Coalescing guard:** if a fetch is already in-flight when a new trigger arrives, the in-flight fetch completes first, then one additional fetch runs. Excess concurrent triggers are dropped. No `async let` fan-out.
6. **Refresh triggers:** (a) App launch — `.startup` phase; (b) popover opens — `.userInitiated`; (c) timer tick — `.background`; (d) user presses ⌘R — `.userInitiated`. User-initiated clears keychain cooldowns and 429 gates.
7. **Timer interval** is read from `SettingsStore.refreshCadence` (default 5 min; valid values: manual / 1 / 2 / 5 / 15 / 30 min). When cadence is `manual`, only startup + user-triggered refreshes run.
8. **Stale icon** state: if `updatedAt` is more than 5 min ago (or if an error occurred), `DisplaySnapshot.isStale = true`. `StatusItemController` uses this to render the dimmed icon (AC7 of S2).
9. **Quota notifications (F10):** using `UNUserNotificationCenter`. Two notification categories:
   - **Depleted:** triggered when `remaining ≤ 0` (transition: was > 0). Body: `"Claude [Session/Weekly] quota exhausted"`.
   - **Restored:** triggered when `remaining > 0` after being depleted. Body: `"Claude [Session/Weekly] quota restored"`.
   - **Threshold warnings:** for each configured threshold (default `[50, 20]`, expressed as percent **remaining**) and for each window (session, weekly): fires once when `remaining` crosses below the threshold. Anti-spam: set of `(window, threshold)` pairs already fired; cleared when usage recedes above threshold. Body: `"Claude [Session/Weekly] at N% remaining"`.
10. Optional notification sound: `NSSound` named `"Glass"` when `SettingsStore.notificationSound == true`.
11. `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])` is called once at app launch. Notifications are silently skipped if permission denied.
12. `AppState` launches the `ClaudeBarWatchdog` helper at startup if it is present in `Contents/Helpers/ClaudeBarWatchdog` (for S6 — in this story, launch attempt is present but gracefully no-ops if binary absent).
13. **Anti-freeze (CRITICAL):** the refresh task runs entirely off MainActor. It calls `FetchPipeline.fetch()` as `Task.detached(priority: .utility)`. After receiving the result, it does `await MainActor.run { self.snapshot = newSnapshot }` — a single atomic assignment. The main thread is NEVER blocked waiting for network I/O.
14. `AppState` persists its timer task in a `Task` property; cancels it in `deinit` (or on `SettingsStore` change of cadence).
15. Tests: (a) coalescing: firing 3 simultaneous refresh triggers results in at most 2 fetch calls (1 in-flight + 1 pending); (b) phase propagation: user-initiated phase bypasses the 429 gate mock; (c) threshold notification fires once at crossing, not on every tick below threshold; (d) restored notification fires on recovery.

---

## Tasks

- [x] **T1 — DisplaySnapshot** (`Sources/ClaudeBar/App/DisplaySnapshot.swift`) — *adapted existing EXB-1.2 stub in the app target (path differs from task; the EXB-1.2 file already lived under `App/` and its consumers are app-only).*
  - [x] Define `struct DisplaySnapshot` with all fields from AC2 (added `cost`, `identity` struct, `isRefreshing`)
  - [x] Factory: `static func from(_ usage: UsageSnapshot, cost: ProviderCost?, isRefreshing: Bool) -> DisplaySnapshot`
  - [x] `isStale` computed: `Date().timeIntervalSince(updatedAt) > 300 || error != nil` (+ deterministic `isStale(now:)`)

- [x] **T2 — AppState** (`Sources/ClaudeBar/App/AppState.swift`)
  - [x] `@MainActor @Observable final class AppState` (203 lines < 300)
  - [x] `var snapshot: DisplaySnapshot?` (only public observable property)
  - [x] `settingsStore` injected reference (stub `SettingsStore` extended here; full in S5)
  - [x] `func triggerRefresh(_ phase: RefreshPhase)` — public entry, enforces coalescing (AC5)
  - [x] `func startRefreshTimer()` — `Task` + `Task.sleep` loop (AC3)
  - [x] `func stopRefreshTimer()` — cancels task
  - [x] On `settingsStore.refreshCadence` change: cancel + restart timer (via `onRefreshCadenceChange`)
  - [x] Launches watchdog helper (AC12) — `launchWatchdogIfPresent()`

- [x] **T3 — RefreshPhase + TaskLocal** — *adapted existing `RefreshPhase` in `Sources/ClaudeBarCore/OAuth/PromptPolicy.swift` (it already existed with `.background`/`.userInitiated`; added `.startup` rather than create a duplicate that would collide).*
  - [x] `enum RefreshPhase { case startup, background, userInitiated }` + `fetchMode` / `allowsNotifications`
  - [x] `@TaskLocal` declaration → `RefreshContext.phase`

- [x] **T4 — Coalescing guard** (in `AppState`)
  - [x] `private var fetchInFlight: Task<Void, Never>?`
  - [x] `private var pendingFetch: Bool = false`
  - [x] Logic implemented in `triggerRefresh` / `completeFetch` (drains exactly one pending fetch). `FetchPipeline` actor also coalesces as the lower layer.

- [x] **T5 — Notification engine** (`Sources/ClaudeBar/Notifications/QuotaNotifier.swift`)
  - [x] `@MainActor final class QuotaNotifier`
  - [x] Tracks `firedThresholds: Set<ThresholdKey>` and `depletedWindows: Set<WindowKind>`
  - [x] `func evaluate(old:new:settings:)`
  - [x] Depleted/restored (AC9a/AC9b) + threshold anti-spam (AC9c) via pure `QuotaNotificationLogic`
  - [x] Posts via `UNUserNotificationCenter` (`SystemNotificationPoster`); `QuotaNotificationPosting` protocol enables headless tests
  - [x] Sound: `NSSound(named: "Glass")?.play()` when enabled (AC10)

- [x] **T6 — Authorization** (`Sources/ClaudeBar/App/ClaudeBarApp.swift`)
  - [x] `requestAuthorization(options: [.alert, .sound])` once at launch — fire and forget (AC11)
  - [x] `AppState.triggerRefresh(.startup)` at launch
  - [x] `AppState.startRefreshTimer()` at launch
  - [x] Watchdog launch + click→`.userInitiated` refresh hook

- [x] **T7 — Tests** (`Tests/ClaudeBarTests/AppStateTests.swift`) — *path differs from task: tests target the app module (`ClaudeBarTests`) because `AppState`/`QuotaNotifier`/`DisplaySnapshot` are app-target types, not Core.*
  - [x] Mock fetch with async delay
  - [x] Coalescing (AC15a) — 3 triggers → ≤ 2 fetches
  - [x] Phase propagation (AC15b) — `.userInitiated` reaches fetch + maps to gate-bypassing mode
  - [x] Threshold notifications (AC15c) — fires once on crossing, refires after recovery
  - [x] Depleted/restored (AC15d)
  - [x] **Single-tick double-crossing (QA §4 fix)** — `80 → 15` with `[50, 20]` delivers the most-severe (20%) warning; pure-logic guard mirrors reference (`crossedThreshold → 20`)

---

## Dev Notes

### Single-snapshot architecture
The original CodexBar had a `UsageStore` with 25+ extension files and `@Observable` on many individual properties, causing observation storms (every property mutation triggers a re-render). exímIABar solves this with ONE property:

```swift
@MainActor @Observable class AppState {
    var snapshot: DisplaySnapshot? = nil
}
```

One network response → one `UsageSnapshot` → one `DisplaySnapshot` → one assignment. SwiftUI diffing handles the rest.

### Task.sleep timer pattern
```swift
private var timerTask: Task<Void, Never>?

func startRefreshTimer() {
    timerTask?.cancel()
    timerTask = Task {
        while !Task.isCancelled {
            let interval = settingsStore.refreshCadence.intervalSeconds
            guard interval > 0 else {
                // manual mode — wait forever until cancelled
                try? await Task.sleep(for: .seconds(3600))
                continue
            }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { break }
            await triggerRefresh(.background)
        }
    }
}
```

### Off-main refresh
```swift
func performFetch(phase: RefreshPhase) async {
    // This entire function runs off-main
    await MainActor.run { snapshot = DisplaySnapshot.refreshing(snapshot) }
    let result = await Task.detached(priority: .utility) {
        return try? await FetchPipeline.shared.fetch(phase: phase)
    }.value
    await MainActor.run {
        snapshot = DisplaySnapshot.from(result, cost: nil, isRefreshing: false)
    }
}
```

### SettingsStore.refreshCadence
In this story, use a stub: `enum RefreshCadence { case manual, min1, min2, min5, min15, min30 }` with `var intervalSeconds: Double`. Full SettingsStore in S5. AppState observes it via `withObservationTracking` or property observation pattern.

### Threshold anti-spam semantics
Threshold `50` for `session` means: fire notification when `session.remaining` crosses below 50%. Fire once. If usage then recovers above 50% (e.g., after a reset), remove `(session, 50)` from the fired set — allow firing again next time it crosses down.

### Reference notification file
`_reference_codexbar/Sources/CodexBar/AppNotifications.swift` and `_reference_codexbar/Sources/CodexBar/QuotaWarningSettingsViews.swift` — adapt notification posting and threshold management.

### Watchdog launch
```swift
// In AppState.init or applicationDidFinishLaunching
let watchdogURL = Bundle.main.url(forAuxiliaryExecutable: "ClaudeBarWatchdog")
if let url = watchdogURL, FileManager.default.fileExists(atPath: url.path) {
    let process = Process()
    process.executableURL = url
    try? process.run()
}
```
If binary absent (S6 not yet built), `fileExists` returns false — no crash.

---

## Definition of Done

- [x] `swift build` succeeds with zero new warnings
- [x] App refreshes on launch and every 5 min (default cadence) — `os.Logger` output in `AppState`/`LiveUsageProvider`; startup + timer wired in `AppDelegate`
- [x] Coalescing test: 3 concurrent triggers → maximum 2 fetch calls (`coalescingCapsConcurrentTriggersAtTwo`)
- [x] `DisplaySnapshot` is correctly constructed from `UsageSnapshot` mock data (`factoryMapsAllFields`)
- [x] `AppState.snapshot` assignment is always on MainActor — fetch runs in `Task.detached(.utility)`; only `completeFetch` (MainActor) assigns
- [x] Quota threshold notification fires once when session drops below 50%, not on every tick (`thresholdFiresOnceOnCrossing`)
- [x] Notification sound respects `SettingsStore` toggle (`NotificationSettings.soundEnabled` gates `NSSound("Glass")`)

---

## Dev Agent Record

### Agent
@dev (Dex)

### File List
**New:**
- `Sources/ClaudeBar/Notifications/QuotaNotifier.swift` — `QuotaNotifier`, pure `QuotaNotificationLogic`, `NotificationSettings`, `WindowKind`, `ThresholdKey`, `QuotaNotificationPosting`, `SystemNotificationPoster`
- `Sources/ClaudeBar/App/LiveUsageProvider.swift` — wraps Core `CredentialsStore`/`UsageFetcher`/`FetchPipeline` into the `AppState.Fetch` closure
- `Tests/ClaudeBarTests/AppStateTests.swift` — coalescing, phase propagation, threshold/depleted/restored notification tests

**Modified:**
- `Sources/ClaudeBar/Notifications/QuotaNotifier.swift` — **QA §4 fix:** `QuotaNotificationLogic.crossedThreshold` now returns `crossed.min()` / `eligible.min()` (most-severe threshold) to match `_reference_codexbar/.../SessionQuotaNotifications.swift`. Fixes single-tick double-crossing suppressing the critical lower warning.
- `Tests/ClaudeBarTests/AppStateTests.swift` — **QA §4 fix:** added `singleTickDoubleCrossingFiresMostSevereThreshold` (end-to-end notifier) + `crossedThresholdReturnsMostSevereOnDoubleCrossing` (pure-logic, mirrors reference test).
- `Sources/ClaudeBar/App/AppState.swift` — full refresh loop, coalescing, off-main fetch, notification dispatch, watchdog launch (was EXB-1.2 stub)
- `Sources/ClaudeBar/App/DisplaySnapshot.swift` — reshaped to AC2 (13 fields, factory, refreshing helper)
- `Sources/ClaudeBar/App/SettingsStore.swift` — added `RefreshCadence`, quota thresholds, `notificationSound`, `onRefreshCadenceChange`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — wired authorization, watchdog, startup refresh, timer, click→user-initiated refresh
- `Sources/ClaudeBarCore/OAuth/PromptPolicy.swift` — added `.startup` to `RefreshPhase`; added `fetchMode`/`allowsNotifications`; added `RefreshContext` TaskLocal
- `Tests/ClaudeBarTests/DisplaySnapshotTests.swift` — migrated to new `DisplaySnapshot.from(_:)` factory + `isStale(now:)`

### IDS Decisions
- `RefreshPhase`: **ADAPTED** the existing enum in `PromptPolicy.swift` (added `.startup`) instead of creating a new `FetchPlan/RefreshPhase.swift` — a duplicate type would collide and break `UsageFetcher`/gates that already reference it.
- `DisplaySnapshot`/`AppState`/`SettingsStore`: **ADAPTED** the EXB-1.2 stubs in place.
- `FetchPipeline` coalescing: **REUSED** the existing actor-level coalescing; `AppState` adds the UI-facing layer.

### Deviations
1. **File paths.** T1/T3/T7 named Core paths; the actual `DisplaySnapshot`, `AppState`, `RefreshPhase` and their tests are app-target / pre-existing Core files. Kept them where the codebase already places them (app types stay in the app target; `RefreshPhase` reused in Core's `PromptPolicy.swift`). No functional impact.
2. **⌘R hotkey (AC6d).** The user-initiated refresh *path* is fully implemented and wired to the status-item click. A literal ⌘R key equivalent requires a menu/responder host that lands with the popover in **EXB-1.3** — there is no menu surface yet in S4. Deferred to S3 with the path ready.
3. **Cost (AC2 `cost`).** Field present and threaded as `nil` — the cost scan that populates it is EXB-1.7. No-op in this story by design.

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. No content changes required. | @po Pax |
| 2026-06-10 | 1.2 | Implemented all ACs. 66 tests pass (7 new). Status: Ready → InReview. | @dev Dex |
| 2026-06-10 | 1.3 | QA gate round 1 — verdict CONCERNS (1 non-blocking threshold-firing regression). | @qa Quinn |
| 2026-06-10 | 1.4 | QA §4 CONCERN resolved — `crossedThreshold` `.max()`→`.min()` (reference parity); added single-tick double-crossing tests. 68/68 pass, clean build. | @dev Dex |

---

## QA Results — rodada 1

**Reviewer:** Quinn (Guardian) · Test Architect
**Date:** 2026-06-10
**Commit reviewed:** `ab76646` (local, not pushed)
**Method:** Every claim re-verified against real source + independent clean build + full test run. Dev report trusted for nothing.

### Verdict: CONCERNS

15/15 ACs structurally implemented. Clean build (0 warnings, verified from a wiped `.build`), 66/66 tests pass (verified independently), anti-freeze contract holds, security contract airtight. **One genuine behavioral regression** in multi-threshold notification firing (non-blocking, edge-case) plus two justified spec deviations. None block the gate; the threshold bug should be fixed before release.

### 1. Acceptance Criteria — line-by-line

| AC | Verdict | Evidence |
|----|---------|----------|
| 1 — `@MainActor @Observable` AppState <300 lines, only `snapshot` public, fetch in Core | ✅ PASS | `AppState.swift` is **203 lines**; `@MainActor @Observable final class` (L16-18); sole observable `var snapshot` (L21), all others `@ObservationIgnored`; fetch logic injected via `Fetch` closure wired through `LiveUsageProvider`→Core. |
| 2 — Immutable `DisplaySnapshot` struct, all UI fields, single assignment renders UI | ⚠️ PASS (2 justified deviations) | `DisplaySnapshot.swift` — `struct … Sendable, Equatable` with all 13 fields. **Deviation:** `plan: ClaudePlan?` (AC spec'd non-optional) and `identity` modeled as a named `Identity` struct of optionals (AC spec'd a tuple). Both are *correct*: `ClaudePlan` has a failable `init?` so plan can be unresolved at Core; forcing non-optional would invent a default (Article IV violation). Tuple→struct is required for `Equatable`. Faithful propagation, not a defect. |
| 3 — Cancellable `Task` + `Task.sleep`, no `Timer`/`DispatchSourceTimer` on main | ✅ PASS | `startRefreshTimer()` L90-106: `Task { while !Task.isCancelled { … try? await Task.sleep(…) } }`. Grep: zero `Timer()`/`DispatchSourceTimer`/`DispatchSource.makeTimer` in `Sources/`. |
| 4 — TaskLocal `RefreshPhase` controls prompts / 429-gate / notifications | ✅ PASS | `PromptPolicy.swift` L18-45: `enum RefreshPhase {startup,background,userInitiated}` + `RefreshContext.$phase` TaskLocal (L43-45), `fetchMode` (L27-29), `allowsNotifications` (L34-36). Bound per-fetch in `AppState.startFetch` L124. |
| 5 — Coalescing: in-flight + 1 pending, excess dropped, no `async let` fan-out | ✅ PASS | `triggerRefresh` L78-82 (sets `pendingFetch`, returns), `completeFetch` drain L177-180 (exactly one). Core `FetchPipeline` actor adds a second coalescing layer. Grep: **zero `async let`** in repo. Test `coalescingCapsConcurrentTriggersAtTwo` passes (count ≤ 2). |
| 6 — Triggers: launch/.startup, popover/.userInitiated, timer/.background, ⌘R/.userInitiated; user-initiated clears cooldowns+429 | ⚠️ PASS (⌘R deferred, justified) | `ClaudeBarApp.swift`: startup L68, timer L69, click→`.userInitiated` L56-58. `triggerRefresh` clears `ClaudeOAuthKeychainAccessGate.clearDenied()` + `ClaudeOAuthUsageRateLimitGate.recordSuccess()` L73-76. **⌘R literal key-equivalent deferred to EXB-1.3** (no menu/responder host until popover lands) — the user-initiated *path* is fully wired. Acceptable per dev deviation #2. |
| 7 — Cadence from `SettingsStore` (default 5 min); manual = startup+user only | ✅ PASS | `SettingsStore.refreshCadence` default `.min5`; `RefreshCadence.intervalSeconds` maps 1/2/5/15/30; `manual`→0 → timer parks (L96-100). |
| 8 — `isStale` when >5 min old or error | ✅ PASS | `DisplaySnapshot.isStale` L84-86 (`>300s ‖ error != nil`) + deterministic `isStale(now:)` L89-91. |
| 9 — Quota notifications: depleted / restored / threshold anti-spam | ⚠️ PASS w/ CONCERN | Depleted/restored (`QuotaNotifier.evaluateWindow` L150-159) and copy strings exact ("Claude Session quota exhausted/restored") — verified by `depletedThenRestoredFires`. **CONCERN (see §4):** threshold firing diverges from reference on single-tick double-crossing. Single-threshold path correct. |
| 10 — Optional `NSSound("Glass")` when sound enabled | ✅ PASS | `playSoundIfEnabled` L226-229 — `(NSSound(named:"Glass") ?? NSSound(named:"Ping"))?.play()`, gated by `settings.soundEnabled`. Matches reference fallback. |
| 11 — `requestAuthorization([.alert,.sound])` once at launch, silent skip if denied | ✅ PASS | `SystemNotificationPoster.requestAuthorization` L310-321 with `[.alert,.sound]`; one-shot via `authorizationTask` memoization (L299-304); `post` silently returns when `!granted` L275-277. Called once in `applicationDidFinishLaunching` L49. |
| 12 — Watchdog launch from `Contents/Helpers/ClaudeBarWatchdog`, graceful no-op | ✅ PASS | `launchWatchdogIfPresent` L187-202 — guards on `fileExists`, logs+returns if absent, try/catch on `process.run()`. No crash path. |
| 13 — Anti-freeze: fetch off-MainActor via `Task.detached(.utility)`, single atomic assignment | ✅ PASS | `startFetch` L123 `Task.detached(priority:.utility)`; result hops back via `await self?.completeFetch(…)`; sole assignment `self.snapshot = newSnapshot` L138 on MainActor. Main thread never blocks on I/O. |
| 14 — Timer task persisted, cancelled in deinit / on cadence change | ✅ PASS | `timerTask` property L35; `deinit` cancels `timerTask` + `fetchInFlight` L60-64; cadence change → `onRefreshCadenceChange` restarts timer L55-57. |
| 15 — Tests: (a) coalescing ≤2, (b) phase propagation, (c) threshold fires once, (d) restored | ✅ PASS | All four in `AppStateTests.swift` + extras (`separateThresholdsFireIndependently`, `thresholdRefiresAfterRecovery`). All pass. *(Caveat: the single-tick double-crossing case that exposes §4 is NOT covered — see recommendation.)* |

### 2. Build — independently verified

Wiped `.build/` entirely and rebuilt from scratch:
```
[49/51] Linking ClaudeBar
[50/51] Applying ClaudeBar
Build complete! (6.10s)
```
**Zero warnings, zero errors.** `grep -iE "warning:|error:"` on full build output → empty. Confirms DoD "zero new warnings".

### 3. Tests — independently verified

```
✔ Test run with 66 tests in 9 suites passed after 1.792 seconds.
```
All 7 new EXB-1.4 tests pass. Notable: the Core suite includes `claudeCLIOwnerNeverCallsRefreshEndpoint()` — a security test that passes, directly corroborating the token-safety contract.

### 4. Anti-freeze — PASS

- Grep for main-thread blocking I/O (`DispatchSemaphore`, `Thread.sleep`, `.wait()`, `.sync {`, sync `Data(contentsOf:http…)`) in `Sources/ClaudeBar/` → **none**. The only sleeps are `await Task.sleep` inside the off-main timer `Task`.
- **No `NSMenu`** anywhere in `Sources/` — dropdown anti-freeze respected.
- Single observable property + `withObservationTracking` observer (`ClaudeBarApp.swift` L83-89) → one re-render per snapshot. No incremental observable mutation. The anti-freeze keystone is genuinely intact.

### 5. Security — PASS (airtight)

The "NEVER consume the CLI refresh token" contract was traced end-to-end, not taken on faith:
- The **fetch path** (`LiveUsageProvider` → `FetchPipeline.run` → `UsageFetcher.fetchUsage`) only issues `GET /api/oauth/usage` with `Authorization: Bearer <accessToken>` (`UsageFetcher.swift` L63-74). It **never** POSTs and **never** calls `RefreshCoordinator`.
- Token refresh lives exclusively in `RefreshCoordinator.refresh()`, which for `owner == .claudeCLI` returns `delegatedRefresh()` — spawns `claude /status` in a PTY and polls the keychain fingerprint; the OAuth refresh endpoint is POSTed **only** for `owner == .claudebar` (`RefreshCoordinator.swift` L73-122). The CLI refresh token is never sent over the wire from this app. Regression #1161 cannot recur on this code path.
- Verified by the passing `claudeCLIOwnerNeverCallsRefreshEndpoint()` test.

### 6. Fidelity vs `_reference_codexbar` — 1 REGRESSION FOUND (the CONCERN)

Comparing `QuotaNotifier.QuotaNotificationLogic.crossedThreshold` against the reference `SessionQuotaNotifications.swift` `QuotaWarningNotificationLogic.crossedThreshold`:

| | Reference | New impl |
|---|---|---|
| `crossedThreshold` return | `crossed.min()` / `eligible.min()` | `crossed.max()` / `eligible.max()` |
| `firedAfter(threshold:)` | marks `{ $0 >= threshold }` | marks `{ $0 >= threshold }` (same) |

The reference fires the **most severe** (smallest %) threshold crossed in a tick and marks every higher threshold as fired. The new code fires the **largest** % threshold and only marks `>= ` that one.

**Consequence (reproduced by execution):** with thresholds `[50, 20]`, if remaining plunges `80 → 15` in a **single** refresh interval (entirely plausible at a 5-min cadence):
- **New impl:** fires only the *50%* warning (labeled "at 15% remaining"), marks `{50}`. On every subsequent tick the *20%* warning is now ineligible (`previous 15 > 20` is false) → **the critical 20% warning is never delivered.**
- **Reference:** fires the *20%* warning and marks `{50, 20}` — user gets the most urgent signal.

The existing `separateThresholdsFireIndependently` test only crosses one threshold per tick (`80→45→15`), where both strategies behave identically — so the test suite does not catch this.

**Why CONCERN, not FAIL:** the depleted/restored path, single-threshold path, and gradual multi-tick path all work correctly; it is a fidelity divergence on a narrower (single-tick double-crossing) edge case, not a missing AC or a broken build. But it silently suppresses the *most important* warning, so it should be fixed before release.

### Required actions (for a future round / EXB follow-up — non-blocking for this gate)

1. **[CONCERN — fix recommended]** In `QuotaNotificationLogic.crossedThreshold`, change both `crossed.max()` and `eligible.max()` to `.min()` to match the reference (fire the most-severe threshold on a single-tick plunge). After the fix, `firedAfter` already marks all `>= ` thresholds, restoring reference parity.
2. **[CONCERN — test gap]** Add a test for the single-tick double-crossing case (`80 → 15` with `[50,20]`) asserting the 20% warning is the one delivered. This locks the fix and prevents regression.
3. **[INFO — no action]** `plan: ClaudePlan?` and the `Identity` struct are documented justified deviations from AC2's literal text; recommend the story text be reconciled (or left as-is with the deviation noted) — no code change needed.
4. **[INFO — no action]** ⌘R literal key-equivalent correctly deferred to EXB-1.3 with the user-initiated path ready; `cost` correctly threaded as `nil` pending EXB-1.7.

### Gate status

Status stays **InReview**. The two CONCERN items are advisory and can be addressed in a fast-follow within this epic (they touch only the pure `QuotaNotificationLogic` + a test) — they do not gate the structural completion of EXB-1.4. No code was modified by QA; only this section was added.

---

## Dev Resolution — QA §4 (CONCERN)

**Date:** 2026-06-10 · **Agent:** @dev (Dex)

Both required actions from QA §4 resolved:

1. **[Fix]** `QuotaNotificationLogic.crossedThreshold` — changed `crossed.max()` and `eligible.max()` to `.min()`, matching `_reference_codexbar/Sources/CodexBar/SessionQuotaNotifications.swift` (`crossed.min()` / `eligible.min()`). On a single-tick plunge the most-severe (smallest %) threshold now fires; `firedAfter(threshold:)` already marks every `>=` threshold, so the higher warnings are correctly suppressed without losing the critical one. Reference parity restored.

2. **[Test gap]** Added two regression tests to `AppStateTests.swift`:
   - `singleTickDoubleCrossingFiresMostSevereThreshold` — `80 → 15` with `[50, 20]` asserts the **20%** warning is delivered (`"Claude Session at 15% remaining"`) and the 50% banner is suppressed.
   - `crossedThresholdReturnsMostSevereOnDoubleCrossing` — pure-logic guard mirroring the reference test (`previousRemaining: 80, currentRemaining: 10 → 20`; cold-start `nil → 10 → 20`).

**Result:** Clean build (zero warnings). **68/68 tests pass** (66 + 2 new). Security test `claudeCLIOwnerNeverCallsRefreshEndpoint()` still green. Items §4.3 / §4.4 are INFO/no-action and remain as documented justified deviations.
