import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for the `DisplaySnapshot` presentation mapping (EXB-1.2 — derived stale/error flags).
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
        let snap = DisplaySnapshot(usage: usage(updatedAt: now), now: now)
        #expect(!snap.isStale)
    }

    /// A snapshot older than the 5-minute threshold is stale.
    @Test
    func oldSnapshotIsStale() {
        let now = Date()
        let old = now.addingTimeInterval(-(DisplaySnapshot.stalenessThreshold + 1))
        let snap = DisplaySnapshot(usage: usage(updatedAt: old), now: now)
        #expect(snap.isStale)
    }

    /// An attached error surfaces as `hasError`.
    @Test
    func errorFlagPropagates() {
        let now = Date()
        let snap = DisplaySnapshot(usage: usage(updatedAt: now, error: .networkError("timeout")), now: now)
        #expect(snap.hasError)
    }
}
