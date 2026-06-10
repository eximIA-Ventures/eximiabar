import Foundation

/// Fetches a usage snapshot by scraping the `claude` CLI `/usage` panel (AC7 of the epic; T5).
///
/// This is the `.cli` source the planner falls back to after OAuth fails. It wraps a long-lived
/// ``CLISession`` (the actor that guarantees at most one `claude` process is alive) and maps the
/// parsed `(session, weekly)` utilization into a ``UsageSnapshot`` with `source == .cli`.
///
/// - Note: the existing `FetchStrategy` in this module is a plain plan-descriptor value (data
///   source + availability), not a behavioural protocol — so this type is a standalone fetcher,
///   not a conformance. The pipeline routes to it via an injected closure (see `FetchPipeline`).
public struct CLIFetchStrategy: Sendable {
    /// Where the `claude` binary lives (resolved from Settings or PATH by the caller).
    public let claudePath: String
    public let session: CLISession
    public let timeout: TimeInterval

    public var dataSource: DataSource { .cli }

    public init(claudePath: String, session: CLISession = CLISession(), timeout: TimeInterval = 45) {
        self.claudePath = claudePath
        self.session = session
        self.timeout = timeout
    }

    /// Runs the CLI probe and maps the result to a `.cli` snapshot.
    ///
    /// `phase` is accepted for signature symmetry with the OAuth path; the CLI probe behaves the
    /// same regardless of phase (there is no rate-limit gate or keychain prompt on this path).
    public func fetch(phase: RefreshPhase, now: Date = Date()) async throws -> UsageSnapshot {
        let (sessionUtil, weeklyUtil) = try await self.session.fetchUsage(
            claudePath: self.claudePath,
            timeout: self.timeout)
        return Self.snapshot(sessionUtil: sessionUtil, weeklyUtil: weeklyUtil, now: now)
    }

    /// Maps utilization percentages (0–100, percent used) into a `.cli` snapshot. Pure + testable.
    static func snapshot(sessionUtil: Double, weeklyUtil: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            session: RateWindow(utilization: sessionUtil, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: weeklyUtil, resetsAt: nil, windowMinutes: 10080),
            sonnet: nil,
            dailyRoutines: nil,
            extraUsage: nil,
            plan: nil,
            identity: nil,
            updatedAt: now,
            source: .cli,
            error: nil)
    }
}
