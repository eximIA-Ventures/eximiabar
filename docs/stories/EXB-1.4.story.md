# Story EXB-1.4: AppState + Refresh Loop + Notifications

**ID:** EXB-1.4
**Status:** Ready
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

- [ ] **T1 — DisplaySnapshot** (`Sources/ClaudeBarCore/Model/DisplaySnapshot.swift`)
  - [ ] Define `struct DisplaySnapshot` with all fields from AC2
  - [ ] Factory: `static func from(_ usage: UsageSnapshot, cost: ProviderCost?, isRefreshing: Bool) -> DisplaySnapshot`
  - [ ] `isStale: Bool` computed: `Date().timeIntervalSince(updatedAt) > 300 || error != nil`

- [ ] **T2 — AppState** (`Sources/ClaudeBar/App/AppState.swift`)
  - [ ] `@MainActor @Observable class AppState`
  - [ ] `var snapshot: DisplaySnapshot?`
  - [ ] `var settingsStore: SettingsStore` (reference — SettingsStore implemented in S5, stub here)
  - [ ] `func triggerRefresh(_ phase: RefreshPhase)` — public entry point; enforces coalescing (AC5)
  - [ ] `private func startRefreshTimer()` — creates `Task { while !Task.isCancelled { try await Task.sleep(...); await triggerRefresh(.background) } }`
  - [ ] `private func stopRefreshTimer()` — cancels task
  - [ ] On `settingsStore.refreshCadence` change: cancel and restart timer
  - [ ] Launches watchdog helper (AC12)

- [ ] **T3 — RefreshPhase + Coalescing** (`Sources/ClaudeBarCore/FetchPlan/RefreshPhase.swift`)
  - [ ] `enum RefreshPhase { case startup, background, userInitiated }`
  - [ ] `TaskLocal<RefreshPhase>` declaration

- [ ] **T4 — Coalescing guard** (in `AppState` or `FetchPipeline`)
  - [ ] `private var fetchInFlight: Task<Void, Never>?`
  - [ ] `private var pendingFetch: Bool = false`
  - [ ] Logic: if `fetchInFlight != nil` → set `pendingFetch = true`, return. After in-flight completes: if `pendingFetch` → run 1 more fetch, clear `pendingFetch`.

- [ ] **T5 — Notification engine** (`Sources/ClaudeBar/Notifications/QuotaNotifier.swift`)
  - [ ] `@MainActor class QuotaNotifier`
  - [ ] Tracks `firedThresholds: Set<ThresholdKey>` and `depletedWindows: Set<WindowKind>`
  - [ ] `func evaluate(old: DisplaySnapshot?, new: DisplaySnapshot, settings: NotificationSettings)`
  - [ ] Implements depleted/restored (AC9a/AC9b) and threshold anti-spam (AC9c)
  - [ ] Posts via `UNUserNotificationCenter.current().add(UNNotificationRequest(...))`
  - [ ] Sound: `NSSound(named: "Glass")?.play()` when enabled

- [ ] **T6 — Authorization** (`Sources/ClaudeBar/App/ClaudeBarApp.swift`)
  - [ ] At `applicationDidFinishLaunching`: `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }` — fire and forget
  - [ ] Start `AppState.triggerRefresh(.startup)`
  - [ ] Start refresh timer via `AppState.startRefreshTimer()`

- [ ] **T7 — Tests** (`Tests/ClaudeBarCoreTests/AppStateTests.swift`)
  - [ ] Mock `FetchPipeline` with an async delay
  - [ ] Test coalescing (AC15a)
  - [ ] Test phase propagation (AC15b)
  - [ ] Test threshold notifications (AC15c, AC15d)

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

- [ ] `swift build` succeeds with zero new warnings
- [ ] App refreshes on launch and every 5 min (default cadence) — verified by adding `os.Logger` output
- [ ] Coalescing test: 3 concurrent triggers → maximum 2 fetch calls
- [ ] `DisplaySnapshot` is correctly constructed from `UsageSnapshot` mock data
- [ ] `AppState.snapshot` assignment is always on MainActor (Thread Sanitizer clean)
- [ ] Quota threshold notification fires once when session drops below 50%, not on every tick
- [ ] Notification sound respects `SettingsStore` toggle

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. No content changes required. | @po Pax |
