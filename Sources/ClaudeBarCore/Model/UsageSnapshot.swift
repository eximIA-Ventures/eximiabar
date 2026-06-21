import Foundation

/// The single immutable value type every downstream UI story consumes.
///
/// Pure value semantics (a `struct`, `Sendable`, `Equatable`) — no reference types,
/// no network or keychain access. Produced by `UsageFetcher` / the snapshot mapper.
public struct UsageSnapshot: Sendable, Equatable {
    /// Identity of the authenticated account, if known.
    public struct Identity: Sendable, Equatable {
        public let name: String
        public let email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    /// 5-hour session window (`windowMinutes == 300`).
    public let session: RateWindow
    /// 7-day weekly window (`windowMinutes == 10080`).
    public let weekly: RateWindow
    /// Sonnet sub-window (7-day Sonnet cap).
    public let sonnet: RateWindow?
    /// Opus sub-window (7-day Opus cap), if the API exposes it.
    public let opus: RateWindow?
    /// Daily routines window; present-but-null in the payload renders a 0% bar.
    public let dailyRoutines: RateWindow?
    /// Overage / extra usage cap, normalized to major units.
    public let extraUsage: ExtraUsage?
    /// Resolved subscription plan.
    public let plan: ClaudePlan?
    /// Account identity, if available.
    public let identity: Identity?
    /// When this snapshot was produced.
    public let updatedAt: Date
    /// Which source produced this snapshot.
    public let source: DataSource
    /// A terminal error attached to a (possibly stale) snapshot, if any.
    public let error: UsageError?

    public init(
        session: RateWindow,
        weekly: RateWindow,
        sonnet: RateWindow?,
        opus: RateWindow? = nil,
        dailyRoutines: RateWindow?,
        extraUsage: ExtraUsage?,
        plan: ClaudePlan?,
        identity: Identity? = nil,
        updatedAt: Date,
        source: DataSource,
        error: UsageError? = nil)
    {
        self.session = session
        self.weekly = weekly
        self.sonnet = sonnet
        self.opus = opus
        self.dailyRoutines = dailyRoutines
        self.extraUsage = extraUsage
        self.plan = plan
        self.identity = identity
        self.updatedAt = updatedAt
        self.source = source
        self.error = error
    }
}

public extension UsageSnapshot {
    /// An all-zero placeholder used before the first refresh completes.
    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            session: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 10080),
            sonnet: nil,
            opus: nil,
            dailyRoutines: nil,
            extraUsage: nil,
            plan: nil,
            identity: nil,
            updatedAt: .distantPast,
            source: .oauth,
            error: nil)
    }
}
