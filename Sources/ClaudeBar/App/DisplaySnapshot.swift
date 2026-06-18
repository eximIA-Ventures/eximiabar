import ClaudeBarCore
import Foundation

/// The single immutable value the entire UI layer renders from.
///
/// `AppState` publishes exactly one `DisplaySnapshot` per refresh cycle — one network response →
/// one `UsageSnapshot` → one `DisplaySnapshot` → one assignment to `AppState.snapshot`. This is
/// the anti-freeze keystone: no `@Observable` storm, no incremental mutation observable to the UI.
///
/// Pure value semantics (`struct`, `Sendable`, `Equatable`). The richer shape introduced in
/// EXB-1.4 (AC2) carries everything the popover, icon and notifier need.
struct DisplaySnapshot: Sendable, Equatable {
    /// 5-hour session window.
    let session: RateWindow?
    /// 7-day weekly window.
    let weekly: RateWindow?
    /// Sonnet (or Opus) sub-window.
    let sonnet: RateWindow?
    /// Daily routines window.
    let dailyRoutines: RateWindow?
    /// Overage / extra-usage cap.
    let extraUsage: ExtraUsage?
    /// Today / 30-day monetary cost, if a cost scan has run (EXB-1.7).
    let cost: ProviderCost?
    /// Resolved subscription plan.
    let plan: ClaudePlan?
    /// Account identity (name / email), if known.
    let identity: Identity
    /// When the underlying data was produced.
    let updatedAt: Date
    /// Which source produced this snapshot.
    let source: DataSource
    /// A terminal error attached to a (possibly stale) snapshot, if any.
    let error: UsageError?
    /// `true` while a refresh is in flight (drives the spinner / dimmed-but-not-stale UI).
    let isRefreshing: Bool
    /// Per-window exhaustion forecasts (EXB-4.3 AC1). Empty until the predictor has enough samples;
    /// the popover renders a forecast line only for entries whose `minutesRemaining != nil`.
    let forecasts: [ExhaustionForecast]
    /// Recent session-window utilization samples (0–100), oldest-first, capped to the sparkline
    /// width (EXB-4.4 AC2). Empty until the predictor has any history; the `SparklineRenderer` draws a
    /// neutral flat line in that case. Sourced off-main from `ExhaustionPredictor.recentUtilizations`.
    let sparklineSamples: [Double]

    /// Identity pair, kept as a small value type so `DisplaySnapshot` stays `Equatable`.
    struct Identity: Sendable, Equatable {
        let name: String?
        let email: String?

        init(name: String? = nil, email: String? = nil) {
            self.name = name
            self.email = email
        }
    }

    init(
        session: RateWindow?,
        weekly: RateWindow?,
        sonnet: RateWindow? = nil,
        dailyRoutines: RateWindow? = nil,
        extraUsage: ExtraUsage? = nil,
        cost: ProviderCost? = nil,
        plan: ClaudePlan? = nil,
        identity: Identity = Identity(),
        updatedAt: Date,
        source: DataSource = .oauth,
        error: UsageError? = nil,
        isRefreshing: Bool = false,
        forecasts: [ExhaustionForecast] = [],
        sparklineSamples: [Double] = [])
    {
        self.session = session
        self.weekly = weekly
        self.sonnet = sonnet
        self.dailyRoutines = dailyRoutines
        self.extraUsage = extraUsage
        self.cost = cost
        self.plan = plan
        self.identity = identity
        self.updatedAt = updatedAt
        self.source = source
        self.error = error
        self.isRefreshing = isRefreshing
        self.forecasts = forecasts
        self.sparklineSamples = sparklineSamples
    }
}

extension DisplaySnapshot {
    /// Staleness threshold (AC8): a snapshot whose data is older than this is rendered dimmed.
    static let stalenessThreshold: TimeInterval = 5 * 60

    /// `true` when the last successful fetch is older than the staleness threshold (5 min) OR an
    /// error is attached (AC8). The icon (S2) uses this to render the dimmed state.
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > Self.stalenessThreshold || error != nil
    }

    /// Variant of `isStale` evaluated against an injected `now` (deterministic for tests).
    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.stalenessThreshold || error != nil
    }

    /// `true` when the snapshot carries a terminal error. Kept for the icon's error styling.
    var hasError: Bool { error != nil }

    /// Pace delta (percentage points). Not yet derived in S4; reserved for the popover (S3).
    var pace: Double? { nil }

    /// Build a presentation snapshot from a core `UsageSnapshot` (AC2 factory).
    ///
    /// - Parameters:
    ///   - usage: the core model produced by the fetch pipeline.
    ///   - cost: optional monetary cost from a local JSONL scan (EXB-1.7); `nil` in S4.
    ///   - isRefreshing: whether a refresh is still in flight when this snapshot is published.
    static func from(
        _ usage: UsageSnapshot,
        cost: ProviderCost? = nil,
        isRefreshing: Bool = false) -> DisplaySnapshot
    {
        DisplaySnapshot(
            session: usage.session,
            weekly: usage.weekly,
            sonnet: usage.sonnet,
            dailyRoutines: usage.dailyRoutines,
            extraUsage: usage.extraUsage,
            cost: cost,
            plan: usage.plan,
            identity: Identity(name: usage.identity?.name, email: usage.identity?.email),
            updatedAt: usage.updatedAt,
            source: usage.source,
            error: usage.error,
            isRefreshing: isRefreshing)
    }

    /// Returns a copy of `previous` (or an empty placeholder) flagged as refreshing — used to flip
    /// the spinner on at the start of a refresh without discarding the data already on screen.
    static func refreshing(_ previous: DisplaySnapshot?) -> DisplaySnapshot {
        guard let previous else {
            return DisplaySnapshot(session: nil, weekly: nil, updatedAt: .distantPast, isRefreshing: true)
        }
        return DisplaySnapshot(
            session: previous.session,
            weekly: previous.weekly,
            sonnet: previous.sonnet,
            dailyRoutines: previous.dailyRoutines,
            extraUsage: previous.extraUsage,
            cost: previous.cost,
            plan: previous.plan,
            identity: previous.identity,
            updatedAt: previous.updatedAt,
            source: previous.source,
            error: previous.error,
            isRefreshing: true,
            forecasts: previous.forecasts,
            sparklineSamples: previous.sparklineSamples)
    }

    /// Returns a copy of this snapshot with `forecasts` (and optionally `sparklineSamples`) replaced —
    /// used by `AppState` to attach the predictor's output after the off-main fetch produced the base
    /// snapshot (EXB-4.3 AC1/T2, EXB-4.4 AC2). Passing `sparklineSamples == nil` preserves the
    /// existing samples so callers that only want forecasts don't clear the sparkline.
    func withForecasts(
        _ forecasts: [ExhaustionForecast],
        sparklineSamples: [Double]? = nil) -> DisplaySnapshot
    {
        DisplaySnapshot(
            session: session,
            weekly: weekly,
            sonnet: sonnet,
            dailyRoutines: dailyRoutines,
            extraUsage: extraUsage,
            cost: cost,
            plan: plan,
            identity: identity,
            updatedAt: updatedAt,
            source: source,
            error: error,
            isRefreshing: isRefreshing,
            forecasts: forecasts,
            sparklineSamples: sparklineSamples ?? self.sparklineSamples)
    }

    /// The forecast for `windowId`, if one exists. The popover uses this to attach the line under
    /// the matching metric row (EXB-4.3 AC4).
    func forecast(for windowId: String) -> ExhaustionForecast? {
        forecasts.first { $0.windowId == windowId }
    }

    /// A window paired with its stable predictor id.
    struct PredictableWindow: Sendable, Equatable {
        let id: String
        let window: RateWindow
    }

    /// The windows present in this snapshot that the predictor should sample, each with its stable
    /// id (EXB-4.3 AC1 §1). Absent windows are simply not included.
    var predictableWindows: [PredictableWindow] {
        var result: [PredictableWindow] = []
        if let session { result.append(.init(id: RateWindowID.session, window: session)) }
        if let weekly { result.append(.init(id: RateWindowID.weekly, window: weekly)) }
        if let sonnet { result.append(.init(id: RateWindowID.sonnet, window: sonnet)) }
        if let dailyRoutines {
            result.append(.init(id: RateWindowID.dailyRoutines, window: dailyRoutines))
        }
        return result
    }
}
