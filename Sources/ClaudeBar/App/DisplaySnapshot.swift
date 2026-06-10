import ClaudeBarCore
import Foundation

/// The single immutable value the UI layer renders from.
///
/// `AppState` publishes exactly one `DisplaySnapshot` per refresh cycle (anti-freeze rule:
/// one immutable snapshot, no `@Observable` storm). The full mapping from `UsageSnapshot`
/// (network/credential model) to `DisplaySnapshot` (presentation model) lands in EXB-1.4;
/// for this story we keep it a thin pass-through plus the derived `isStale` / `hasError`
/// flags the icon needs.
struct DisplaySnapshot: Sendable, Equatable {
    /// 5-hour session window.
    let session: RateWindow
    /// 7-day weekly window, or `nil` when the payload carried no `seven_day` data.
    let weekly: RateWindow?
    /// Pace delta in percentage points (positive = ahead of an even burn). `nil` if unknown.
    let pace: Double?
    /// `true` when the last successful fetch is older than the staleness threshold (5 min).
    let isStale: Bool
    /// `true` when the snapshot carries a terminal error.
    let hasError: Bool
    /// When the underlying data was produced.
    let updatedAt: Date

    init(
        session: RateWindow,
        weekly: RateWindow?,
        pace: Double? = nil,
        isStale: Bool = false,
        hasError: Bool = false,
        updatedAt: Date)
    {
        self.session = session
        self.weekly = weekly
        self.pace = pace
        self.isStale = isStale
        self.hasError = hasError
        self.updatedAt = updatedAt
    }
}

extension DisplaySnapshot {
    /// Staleness threshold: a snapshot whose data is older than this is rendered dimmed.
    static let stalenessThreshold: TimeInterval = 5 * 60

    /// Build a presentation snapshot from a core `UsageSnapshot`, deriving staleness from `now`.
    ///
    /// A `weekly` window with zero data is treated as "absent" only if its `resetsAt` is `nil`
    /// AND utilization is 0 — otherwise it is a real window. The richer mapping (pace, plan,
    /// daily routines) is completed in EXB-1.4; here we map the fields the icon consumes.
    init(usage: UsageSnapshot, now: Date = Date()) {
        let stale = now.timeIntervalSince(usage.updatedAt) > Self.stalenessThreshold
        self.init(
            session: usage.session,
            weekly: usage.weekly,
            pace: nil,
            isStale: stale,
            hasError: usage.error != nil,
            updatedAt: usage.updatedAt)
    }
}
