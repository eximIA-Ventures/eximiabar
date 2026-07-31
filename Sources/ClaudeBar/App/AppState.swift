import ClaudeBarCore
import Foundation
import Observation
import os

/// The single source of UI truth (AC1).
///
/// `AppState` holds exactly ONE stored observable property — `workspace`, an immutable
/// `WorkspaceSnapshot`. One refresh cycle → one aggregate assembled off-MainActor → one assignment
/// here, **whatever the number of accounts**. This is the anti-freeze keystone: no `@Observable`
/// storm, no incremental mutation the UI can observe (AC2, invariant I3).
///
/// `snapshot` and `menuBarSnapshot` are **computed** reads of that one property (EXB-5.3 AC2). A
/// computed property is not storage: `withObservationTracking` registers the read of `workspace`
/// underneath and fires exactly once when `workspace` is reassigned. The rejected alternative —
/// `var snapshots: [AccountKey: DisplaySnapshot]` — is one property on paper and N observable
/// mutations per cycle in practice (AC2.4).
///
/// All fetch logic lives in `ClaudeBarCore` (the `Fetch` closure wraps the pipeline). The
/// refresh loop is a cancellable `Task` + `Task.sleep` (AC3) — never a `Timer` on main. Fetches
/// run off-MainActor; only the final `workspace` assignment hops back to the main actor (AC13).
@MainActor
@Observable
final class AppState {
    /// The whole multi-account workspace, or `nil` before the first refresh completes. The ONLY
    /// stored observable state (EXB-5.3 AC2.2) — every other stored property is
    /// `@ObservationIgnored`.
    var workspace: WorkspaceSnapshot?

    /// The reading of the account currently in focus in the popover. Computed, never stored.
    var snapshot: DisplaySnapshot? { self.workspace?.focused?.display }

    /// The reading of the live Claude account — what the menu-bar icon renders. Computed, never
    /// stored, and deliberately independent of the focus: switching accounts in the popover must
    /// not move the meter in the menu bar (AC4.7).
    var menuBarSnapshot: DisplaySnapshot? { self.workspace?.menuBar?.display }

    /// Performs one fetch cycle for the given phase, off-MainActor, returning the whole assembled
    /// workspace (Claude + Codex + archived panes) or `nil` when nothing could be produced. The
    /// fan-out lives in `LiveUsageProvider.makeFetch()` (AC6.17), never here.
    typealias Fetch = @Sendable (_ phase: RefreshPhase) async -> WorkspaceSnapshot?

    /// The pre-multi-account shape, kept for tests and any consumer that only knows one account
    /// (AC6.16). Wrapped into a single-account workspace by the convenience initializer.
    typealias DisplayFetch = @Sendable (_ phase: RefreshPhase) async -> DisplaySnapshot?

    #if DEBUG
    /// How many times `workspace` has been written since this `AppState` was built.
    ///
    /// Exists for one reason: T-I3. The invariant "one refresh cycle publishes the workspace exactly
    /// once, no matter how many accounts it holds" is only meaningful if it is *counted*, and every
    /// write funnels through `publish(_:)` so the count cannot drift from reality.
    /// `@ObservationIgnored` — a test counter must never become a second observable channel.
    @ObservationIgnored private(set) var workspaceAssignmentCount = 0
    #endif

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let notifier: QuotaNotifier
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// Off-main actor that records utilization samples and computes exhaustion forecasts (EXB-4.3).
    @ObservationIgnored private let predictor: ExhaustionPredictor
    @ObservationIgnored private let log = Logger(subsystem: CoreLog.subsystem, category: "appstate")

    /// The repeating refresh timer task (AC3 / AC14).
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// The currently in-flight fetch, for coalescing (AC5).
    @ObservationIgnored private var fetchInFlight: Task<Void, Never>?
    /// A single queued re-run requested while a fetch was in flight (AC5).
    @ObservationIgnored private var pendingFetch = false

    init(
        fetch: @escaping Fetch,
        settingsStore: SettingsStore,
        notifier: QuotaNotifier? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        predictor: ExhaustionPredictor = .shared,
        workspace: WorkspaceSnapshot? = nil)
    {
        self.fetch = fetch
        self.settingsStore = settingsStore
        self.notifier = notifier ?? QuotaNotifier()
        self.clock = clock
        self.predictor = predictor
        self.workspace = workspace

        // Restart the timer when the cadence changes (AC14).
        settingsStore.onRefreshCadenceChange = { [weak self] _ in
            self?.startRefreshTimer()
        }
    }

    /// Single-account convenience (AC6.16): a fetch that yields one `DisplaySnapshot` and an
    /// optional seed snapshot, wrapped into a one-account workspace. Consumers that predate
    /// multi-account keep working untouched — and any `AppState` built this way starts focused on
    /// its live account, like every other fresh construction (D-C).
    convenience init(
        displayFetch: @escaping DisplayFetch,
        settingsStore: SettingsStore,
        notifier: QuotaNotifier? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        predictor: ExhaustionPredictor = .shared,
        snapshot: DisplaySnapshot? = nil)
    {
        self.init(
            fetch: { phase in
                guard let display = await displayFetch(phase) else { return nil }
                return WorkspaceSnapshot.singleAccount(display, updatedAt: display.updatedAt)
            },
            settingsStore: settingsStore,
            notifier: notifier,
            clock: clock,
            predictor: predictor,
            workspace: snapshot.map { WorkspaceSnapshot.singleAccount($0, updatedAt: $0.updatedAt) })
    }

    deinit {
        // `Task.cancel()` is safe to call from any isolation (AC14).
        timerTask?.cancel()
        fetchInFlight?.cancel()
    }

    // MARK: - Public refresh entry point (AC5, AC6)

    /// Trigger a refresh in the given phase. Enforces coalescing: while a fetch is in flight a new
    /// trigger sets `pendingFetch` and returns; after the in-flight fetch completes, exactly one
    /// additional fetch runs. Excess concurrent triggers collapse into that single pending run.
    func triggerRefresh(_ phase: RefreshPhase) {
        // User-initiated refresh clears keychain cooldowns and the 429 gate (AC6).
        if phase == .userInitiated {
            ClaudeOAuthKeychainAccessGate.clearDenied()
            ClaudeOAuthUsageRateLimitGate.recordSuccess()
        }

        guard fetchInFlight == nil else {
            self.pendingFetch = true
            return
        }
        self.startFetch(phase)
    }

    // MARK: - Timer (AC3, AC7)

    /// Start (or restart) the repeating refresh timer. Cancellable `Task` + `Task.sleep`; never a
    /// `Timer`/`DispatchSourceTimer` on main (AC3). In `manual` cadence it idles until cancelled,
    /// running only startup + user-triggered refreshes (AC7).
    func startRefreshTimer() {
        self.timerTask?.cancel()
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.settingsStore.refreshCadence.intervalSeconds
                guard interval > 0 else {
                    // Manual mode: park until the task is cancelled (cadence change cancels it).
                    try? await Task.sleep(for: .seconds(3600))
                    continue
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                self.triggerRefresh(.background)
            }
        }
    }

    /// Cancel the repeating refresh timer.
    func stopRefreshTimer() {
        self.timerTask?.cancel()
        self.timerTask = nil
    }

    // MARK: - Coalesced fetch (AC5, AC13)

    private func startFetch(_ phase: RefreshPhase) {
        // Flip the spinner on without discarding the data already on screen. Archived panes are
        // untouched — nothing is ever fetched for them.
        self.publish(self.workspace?.refreshingLivePanes()
            ?? WorkspaceSnapshot.singleAccount(DisplaySnapshot.refreshing(nil)))

        let fetch = self.fetch
        let predictor = self.predictor
        let clock = self.clock
        // `Task.detached` so the fetch (network I/O, parsing) runs OFF the MainActor (AC13). The
        // whole aggregate — Claude and Codex fanned out concurrently inside `fetch`, plus the
        // archived panes read from the roster index — is assembled here; only the `completeFetch`
        // call below hops back to the main actor, for ONE assignment (AC3.5).
        self.fetchInFlight = Task.detached(priority: .utility) { [weak self] in
            let incoming = await RefreshContext.$phase.withValue(phase) {
                await fetch(phase)
            }
            // EXB-4.3 (T2): record one sample per active window and compute forecasts — all off the
            // MainActor, inside the predictor actor — then attach the forecasts before the single
            // main-actor assignment in `completeFetch`.
            let enriched = await Self.enrich(
                workspace: incoming,
                predictor: predictor,
                now: clock())
            await self?.completeFetch(enriched, phase: phase)
        }
    }

    /// Off-main: enrich the live **Claude** pane with forecasts and the sparkline.
    ///
    /// Only that pane, deliberately. `ExhaustionPredictor` keys its history by window id
    /// (`session`, `weekly`, …) with no account dimension, so feeding a second provider's
    /// utilization into it would interleave two unrelated series into one forecast. Extending the
    /// predictor per account is out of this story's scope; silently corrupting the Claude forecast
    /// is not an acceptable side effect of adding Codex.
    private static func enrich(
        workspace: WorkspaceSnapshot?,
        predictor: ExhaustionPredictor,
        now: Date) async -> WorkspaceSnapshot?
    {
        guard let workspace, let display = workspace.menuBar?.display else { return workspace }
        let enriched = await Self.enrich(display, predictor: predictor, now: now)
        return workspace.replacingDisplay(for: workspace.menuBarKey, with: enriched)
    }

    /// Off-main: feed each active window's utilization into the predictor and read back a forecast
    /// for it, returning a copy of `snapshot` with the forecasts attached (EXB-4.3 AC1/AC2/AC3).
    private static func enrich(
        _ snapshot: DisplaySnapshot,
        predictor: ExhaustionPredictor,
        now: Date) async -> DisplaySnapshot
    {
        let windows = snapshot.predictableWindows
        guard !windows.isEmpty else { return snapshot }

        var forecasts: [ExhaustionForecast] = []
        for entry in windows {
            await predictor.addSample(
                windowId: entry.id,
                timestamp: now,
                utilization: entry.window.utilization)
            let secondsUntilReset = entry.window.resetsAt
                .map { max(0, $0.timeIntervalSince(now)) } ?? .infinity
            let forecast = await predictor.forecast(
                windowId: entry.id,
                currentUtilization: entry.window.utilization,
                secondsUntilReset: secondsUntilReset)
            forecasts.append(forecast)
        }
        // EXB-4.4 (AC2): read back the recent session utilizations (now including the sample we just
        // added) so the menu-bar sparkline draws from the same rolling history the forecast uses — all
        // still inside the actor, off the MainActor.
        let sparkline = await predictor.recentUtilizations(
            windowId: RateWindowID.session,
            limit: SparklineRenderer.maxSamples)
        return snapshot.withForecasts(forecasts, sparklineSamples: sparkline)
    }

    /// Runs on the MainActor: publishes the new workspace, fires notifications, then drains a
    /// single pending fetch if one was queued during the in-flight fetch (AC5).
    private func completeFetch(_ incoming: WorkspaceSnapshot?, phase: RefreshPhase) {
        self.fetchInFlight = nil

        if let incoming {
            let previous = self.workspace
            let merged = self.merging(incoming, onto: previous)
            self.publish(merged) // single atomic assignment per cycle (AC2/AC3/AC13)

            // Notifications fire only for non-startup phases (AC4) — startup seeds baseline state.
            if phase.allowsNotifications {
                // AC4.8/AC4.10: the notifier receives the pane COLLECTION, never the focused pane
                // and never a single `DisplaySnapshot` — the Codex panel is not reachable from one.
                // It filters `lifecycle == .live` itself, so an archived pane can never notify
                // regardless of what this call site passes (AC4.11).
                self.notifier.evaluate(
                    panes: merged.accounts,
                    previous: previous,
                    settings: self.settingsStore.notificationSettings)
                // EXB-4.3 (AC5): predictive alert runs after the threshold notifier so it can defer
                // to a fixed-threshold alert already sent for the same window this cycle. Forecasts
                // exist only on the live Claude pane (see `enrich`).
                self.notifier.evaluatePredictive(
                    forecasts: merged.menuBar?.display?.forecasts ?? [],
                    enabled: self.settingsStore.predictiveAlertsEnabled
                        && self.settingsStore.notificationsEnabled)
            } else {
                // Seed baseline depleted/threshold state silently so the first real refresh
                // diffs against truth, not against the placeholder.
                self.notifier.evaluate(
                    panes: merged.accounts,
                    previous: nil,
                    settings: NotificationSettings(
                        thresholds: self.settingsStore.sessionThresholds,
                        soundEnabled: false,
                        enabled: false))
            }
        } else if let current = self.workspace {
            // No data: clear the spinner, keep the last good readings.
            self.publish(current.clearingRefreshing())
        }

        // Coalescing drain (AC5): run exactly one queued fetch, then stop.
        if self.pendingFetch {
            self.pendingFetch = false
            self.startFetch(.background)
        }
    }

    /// Reconcile the freshly assembled workspace with what is on screen.
    ///
    /// Two things are carried across: the error-merge on the live Claude pane (a failed fetch must
    /// never zero Session/Weekly — EXB rate-limit fix) and the popover focus, which is session
    /// state that survives refreshes but nothing else (D-C).
    private func merging(
        _ incoming: WorkspaceSnapshot,
        onto previous: WorkspaceSnapshot?) -> WorkspaceSnapshot
    {
        var merged = incoming

        // A fetch error arrives as the `errorOnly` sentinel (no usage windows). Merge it onto the
        // last good reading so Session/Weekly are PRESERVED — the error only appends its line and
        // marks the data stale. `previous` here is the in-flight refreshing placeholder, which
        // already carries the prior windows. The `?? previous?.menuBar` fallback covers the cycle
        // where identity resolution failed and the pane fell back to the opaque key: there is only
        // ever one live Claude account, so its previous reading is the right one either way.
        if let display = incoming.menuBar?.display, display.isErrorOnly {
            let previousDisplay = previous?.pane(for: incoming.menuBarKey)?.display
                ?? previous?.menuBar?.display
            merged = merged.replacingDisplay(
                for: incoming.menuBarKey,
                with: display.mergingError(onto: previousDisplay))
        }

        // Keep the account the user is looking at in focus across refreshes. `withFocus` is a no-op
        // for a key that no longer exists, so a removed account falls back to the live one.
        if let previousFocus = previous?.focusedKey {
            merged = merged.withFocus(previousFocus)
        }
        return merged
    }

    /// The one funnel every write to `workspace` goes through (T-I3 counts it here).
    private func publish(_ next: WorkspaceSnapshot?) {
        #if DEBUG
        self.workspaceAssignmentCount += 1
        #endif
        self.workspace = next
    }

    // MARK: - Focus (AC5 — D-C)

    /// Move the popover focus to another account. **No fetch, no I/O**: the data is already in
    /// memory, so this is one atomic reassignment of the aggregate (AC5.14). The new focus lives
    /// only in memory — a relaunch always reopens on the live Claude account (D-C).
    func focusAccount(_ key: AccountKey) {
        guard let workspace = self.workspace else { return }
        let next = workspace.withFocus(key)
        guard next != workspace else { return }
        self.publish(next)
    }

    // MARK: - Watchdog (AC12)

    /// Launch the watchdog helper if it is present in `Contents/Helpers/ClaudeBarWatchdog`.
    /// Gracefully no-ops when the binary is absent (S6 not yet built) — no crash (AC12).
    func launchWatchdogIfPresent() {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "ClaudeBarWatchdog"),
              FileManager.default.fileExists(atPath: url.path)
        else {
            self.log.debug("watchdog helper absent; skipping launch")
            return
        }
        let process = Process()
        process.executableURL = url
        do {
            try process.run()
            self.log.info("watchdog helper launched")
        } catch {
            self.log.error("watchdog launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
