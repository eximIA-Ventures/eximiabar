import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for the `DisplaySnapshot` presentation mapping (EXB-1.4 — factory + derived stale/error).
struct DisplaySnapshotTests {
    private func usage(updatedAt: Date, error: UsageError? = nil) -> UsageSnapshot {
        UsageSnapshot(
            session: RateWindow(utilization: 20, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 40, resetsAt: nil, windowMinutes: 10080),
            sonnet: nil,
            dailyRoutines: nil,
            extraUsage: nil,
            plan: nil,
            identity: nil,
            updatedAt: updatedAt,
            source: .oauth,
            error: error)
    }

    /// A fresh snapshot (just updated) is not stale.
    @Test
    func freshSnapshotIsNotStale() {
        let now = Date()
        let snap = DisplaySnapshot.from(usage(updatedAt: now))
        #expect(!snap.isStale(now: now))
    }

    /// A snapshot older than the 5-minute threshold is stale.
    @Test
    func oldSnapshotIsStale() {
        let now = Date()
        let old = now.addingTimeInterval(-(DisplaySnapshot.stalenessThreshold + 1))
        let snap = DisplaySnapshot.from(usage(updatedAt: old))
        #expect(snap.isStale(now: now))
    }

    /// An attached error surfaces as `hasError` and forces staleness (AC8).
    @Test
    func errorFlagPropagates() {
        let now = Date()
        let snap = DisplaySnapshot.from(usage(updatedAt: now, error: .networkError("timeout")))
        #expect(snap.hasError)
        #expect(snap.isStale(now: now))
    }

    /// The factory copies every window and identity field across (AC2).
    @Test
    func factoryMapsAllFields() {
        let now = Date()
        let full = UsageSnapshot(
            session: RateWindow(utilization: 30, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 10, resetsAt: nil, windowMinutes: 10080),
            sonnet: RateWindow(utilization: 5, resetsAt: nil, windowMinutes: 300),
            dailyRoutines: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 1440),
            extraUsage: nil,
            plan: .max,
            identity: UsageSnapshot.Identity(name: "Hugo", email: "h@example.com"),
            updatedAt: now,
            source: .oauth,
            error: nil)
        let snap = DisplaySnapshot.from(full, isRefreshing: true)
        #expect(snap.session?.utilization == 30)
        #expect(snap.weekly?.utilization == 10)
        #expect(snap.sonnet?.utilization == 5)
        #expect(snap.dailyRoutines?.utilization == 0)
        #expect(snap.plan == .max)
        #expect(snap.identity.name == "Hugo")
        #expect(snap.identity.email == "h@example.com")
        #expect(snap.isRefreshing)
    }

    // MARK: - EXB rate-limit fix: error never zeroes the windows

    /// `errorOnly` carries the error and leaves every window `nil` — it is recognised as the
    /// sentinel and never fabricates `0%` windows (regression: a 429 used to zero Session/Weekly).
    @Test
    func errorOnlySentinelHasNoWindows() {
        let snap = DisplaySnapshot.errorOnly(.rateLimited(retryAfter: Date()))
        #expect(snap.isErrorOnly)
        #expect(snap.session == nil)
        #expect(snap.weekly == nil)
        #expect(snap.hasError)
    }

    /// A real snapshot (with windows) is NOT the error-only sentinel even when it carries an error.
    @Test
    func realSnapshotIsNotErrorOnly() {
        let snap = DisplaySnapshot.from(usage(updatedAt: Date(), error: .networkError("boom")))
        #expect(!snap.isErrorOnly)
    }

    /// Merging an error onto a prior good snapshot PRESERVES its windows and only swaps in the
    /// error + the observation time, clearing `isRefreshing`. This is the anti-zeroing keystone.
    @Test
    func mergingErrorPreservesPreviousWindows() {
        let previous = DisplaySnapshot.from(usage(updatedAt: Date(timeIntervalSince1970: 1_000)))
        let errorAt = Date(timeIntervalSince1970: 2_000)
        let merged = DisplaySnapshot
            .errorOnly(.rateLimited(retryAfter: errorAt), at: errorAt)
            .mergingError(onto: previous)

        #expect(merged.session?.utilization == 20)   // preserved, NOT zeroed
        #expect(merged.weekly?.utilization == 40)     // preserved, NOT zeroed
        #expect(merged.hasError)                       // error attached
        #expect(merged.updatedAt == errorAt)           // stamped at the failure
        #expect(!merged.isRefreshing)                  // spinner cleared
    }

    /// With no prior snapshot (error on the very first fetch) the sentinel is returned unchanged —
    /// there is nothing to preserve.
    @Test
    func mergingErrorWithoutPreviousReturnsSentinel() {
        let sentinel = DisplaySnapshot.errorOnly(.networkError("first"))
        let merged = sentinel.mergingError(onto: nil)
        #expect(merged.isErrorOnly)
        #expect(merged.session == nil)
    }

    /// The fresh local cost is carried forward through the error merge (a 429 still shows cost).
    @Test
    func mergingErrorPrefersFreshCost() {
        let previous = DisplaySnapshot.from(
            usage(updatedAt: Date()),
            cost: ProviderCost(today: 1, last30Days: 1, todayTokens: 0, last30DaysTokens: 0))
        let freshCost = ProviderCost(today: 9, last30Days: 99, todayTokens: 0, last30DaysTokens: 0)
        let merged = DisplaySnapshot.errorOnly(.networkError("x"))
            .mergingCost(freshCost)
            .mergingError(onto: previous)
        #expect(merged.cost?.today == 9)
    }
}

