import Foundation

/// Rich, per-entry analytics roll-up produced by `CostScanner.scanAnalytics(...)` (EXB-3.2).
///
/// The popover only needs `ProviderCost` (per-`(day, model)` totals). The analytics dashboard needs
/// finer dimensions — hour-of-day (heatmap), project (per-project breakdown), session (top-sessions),
/// and the cache-read / cache-write token split (stacked tokens chart). Rather than re-parse the
/// JSONL, `scanAnalytics` runs the **same** byte-level scan pipeline and accumulates into these value
/// types. Everything here is `Sendable` so the dashboard can `Task.detached` the scan and hop the
/// result back to `@MainActor` without a data race (anti-freeze invariant).
public struct UsageAnalytics: Sendable, Equatable {
    /// Per-`(day, model)` rows over the scan window — the same shape `ProviderCost.byModel` carries,
    /// now including the cache-token split. The dashboard folds these for the daily axis and the
    /// model breakdown.
    public let byDayModel: [ModelCostEntry]
    /// Per-project totals over the window, sorted by cost descending (AC6).
    public let byProject: [ProjectUsageEntry]
    /// Weekday × hour activity buckets (token volume), 7 × 24 (AC7). `heatmap[weekday][hour]`.
    public let heatmap: [[HeatmapBucket]]
    /// The most expensive sessions in the window, sorted by cost descending (AC8).
    public let topSessions: [SessionUsageEntry]
    /// Spend in the current calendar month, USD — the run-rate projection numerator (AC2).
    public let monthToDateCost: Double

    public init(
        byDayModel: [ModelCostEntry],
        byProject: [ProjectUsageEntry],
        heatmap: [[HeatmapBucket]],
        topSessions: [SessionUsageEntry],
        monthToDateCost: Double)
    {
        self.byDayModel = byDayModel
        self.byProject = byProject
        self.heatmap = heatmap
        self.topSessions = topSessions
        self.monthToDateCost = monthToDateCost
    }

    /// An empty 7 × 24 heatmap grid (weekday 0 = Sunday … 6 = Saturday).
    public static func emptyHeatmap() -> [[HeatmapBucket]] {
        (0..<7).map { weekday in
            (0..<24).map { hour in HeatmapBucket(weekday: weekday, hour: hour, tokens: 0) }
        }
    }

    /// `true` when the scan produced no priced rows at all.
    public var isEmpty: Bool { self.byDayModel.isEmpty }
}

/// One project's window totals for the per-project breakdown (AC6).
public struct ProjectUsageEntry: Sendable, Equatable, Identifiable {
    /// The project basename (last path component of `cwd`). Doubles as the row `id`; the builder
    /// folds per-project rows so names are unique within a scan.
    public var id: String { self.project }
    public let project: String
    public let costUSD: Double
    /// Total tokens (input + output + cache read + cache write) for the project.
    public let totalTokens: Int

    public init(project: String, costUSD: Double, totalTokens: Int) {
        self.project = project
        self.costUSD = costUSD
        self.totalTokens = totalTokens
    }
}

/// One weekday × hour activity bucket for the heatmap (AC7). `tokens` is total token volume.
public struct HeatmapBucket: Sendable, Equatable {
    /// 0 = Sunday … 6 = Saturday (`Calendar.component(.weekday) - 1`).
    public let weekday: Int
    /// 0 … 23 (local hour of day).
    public let hour: Int
    public let tokens: Int

    public init(weekday: Int, hour: Int, tokens: Int) {
        self.weekday = weekday
        self.hour = hour
        self.tokens = tokens
    }
}

/// One session's window totals for the top-sessions table (AC8).
public struct SessionUsageEntry: Sendable, Equatable, Identifiable {
    /// The session identifier (from the JSONL `sessionId`), or the file basename when absent.
    /// Doubles as the row `id` — unique per session.
    public var id: String { self.sessionId }
    public let sessionId: String
    /// First-seen timestamp for the session within the window.
    public let date: Date
    /// The project basename for the session.
    public let project: String
    /// The model that contributed the most cost in the session.
    public let dominantModel: String
    /// Total tokens (input + output + cache read + cache write).
    public let totalTokens: Int
    public let costUSD: Double

    public init(
        sessionId: String,
        date: Date,
        project: String,
        dominantModel: String,
        totalTokens: Int,
        costUSD: Double)
    {
        self.sessionId = sessionId
        self.date = date
        self.project = project
        self.dominantModel = dominantModel
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}
