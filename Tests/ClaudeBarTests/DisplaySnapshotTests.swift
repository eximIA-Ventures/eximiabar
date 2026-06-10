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
}
