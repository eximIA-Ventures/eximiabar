import ClaudeBarCore
import Foundation
import Observation
import os

/// The single source of UI truth (AC1).
///
/// `AppState` holds exactly ONE public observable property — `snapshot` — an immutable
/// `DisplaySnapshot`. One network response → one `UsageSnapshot` → one `DisplaySnapshot` → one
/// assignment here. This is the anti-freeze keystone: no `@Observable` storm, no incremental
/// mutation the UI can observe (AC2).
///
/// All fetch logic lives in `ClaudeBarCore` (the `Fetch` closure wraps the pipeline). The
/// refresh loop is a cancellable `Task` + `Task.sleep` (AC3) — never a `Timer` on main. Fetches
/// run off-MainActor; only the final `snapshot` assignment hops back to the main actor (AC13).
@MainActor
@Observable
final class AppState {
    /// The current snapshot, or `nil` before the first refresh completes (AC2). The ONLY public
    /// observable state.
    var snapshot: DisplaySnapshot?

    /// Performs one fetch for the given phase, off-MainActor. Returns the resulting
    /// `DisplaySnapshot`, or `nil` if no data could be produced. Injected so `AppState` keeps all
    /// network/credential logic in `ClaudeBarCore` and tests can substitute a mock (AC15).
    typealias Fetch = @Sendable (_ phase: RefreshPhase) async -> DisplaySnapshot?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let notifier: QuotaNotifier
    @ObservationIgnored private let clock: @Sendable () -> Date
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
        snapshot: DisplaySnapshot? = nil)
    {
        self.fetch = fetch
        self.settingsStore = settingsStore
        self.notifier = notifier ?? QuotaNotifier()
        self.clock = clock
        self.snapshot = snapshot

        // Restart the timer when the cadence changes (AC14).
        settingsStore.onRefreshCadenceChange = { [weak self] _ in
            self?.startRefreshTimer()
        }
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
        // Flip the spinner on without discarding the data already on screen.
        self.snapshot = DisplaySnapshot.refreshing(self.snapshot)

        let fetch = self.fetch
        // `Task.detached` so the fetch (network I/O, parsing) runs OFF the MainActor (AC13). Only
        // the `completeFetch` call below hops back to the main actor for the single assignment.
        self.fetchInFlight = Task.detached(priority: .utility) { [weak self] in
            let newSnapshot = await RefreshContext.$phase.withValue(phase) {
                await fetch(phase)
            }
            await self?.completeFetch(newSnapshot, phase: phase)
        }
    }

    /// Runs on the MainActor: publishes the new snapshot, fires notifications, then drains a
    /// single pending fetch if one was queued during the in-flight fetch (AC5).
    private func completeFetch(_ newSnapshot: DisplaySnapshot?, phase: RefreshPhase) {
        self.fetchInFlight = nil

        if let newSnapshot {
            let previous = self.snapshot
            self.snapshot = newSnapshot // single atomic assignment (AC2/AC13)

            // Notifications fire only for non-startup phases (AC4) — startup seeds baseline state.
            if phase.allowsNotifications {
                self.notifier.evaluate(
                    old: previous,
                    new: newSnapshot,
                    settings: self.settingsStore.notificationSettings)
            } else {
                // Seed baseline depleted/threshold state silently so the first real refresh
                // diffs against truth, not against the placeholder.
                self.notifier.evaluate(
                    old: nil,
                    new: newSnapshot,
                    settings: NotificationSettings(
                        thresholds: self.settingsStore.sessionThresholds,
                        soundEnabled: false,
                        enabled: false))
            }
        } else {
            // No data: clear the spinner, keep last good snapshot if any.
            if let current = self.snapshot, current.isRefreshing {
                self.snapshot = DisplaySnapshot(
                    session: current.session,
                    weekly: current.weekly,
                    sonnet: current.sonnet,
                    dailyRoutines: current.dailyRoutines,
                    extraUsage: current.extraUsage,
                    cost: current.cost,
                    plan: current.plan,
                    identity: current.identity,
                    updatedAt: current.updatedAt,
                    source: current.source,
                    error: current.error,
                    isRefreshing: false)
            }
        }

        // Coalescing drain (AC5): run exactly one queued fetch, then stop.
        if self.pendingFetch {
            self.pendingFetch = false
            self.startFetch(.background)
        }
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
