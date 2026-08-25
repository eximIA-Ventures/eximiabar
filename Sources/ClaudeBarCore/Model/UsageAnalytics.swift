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
    ///
    /// The head of the same roll-up `sessionTokenBuckets` counts, so the ten can be marked on the
    /// histogram without either view naming a session the other never saw.
    public let topSessions: [SessionUsageEntry]
    /// Per-`(day, project)` totals over the window (EXB-6.1), capped at the globally-ranked projects
    /// plus one aggregate row per day.
    ///
    /// `byProject` folds the date away, which answers "who spent most" and cannot answer "who *rose*
    /// this month". The grain was always in the archive — a bucket carries day and project in the
    /// same key — and was simply discarded at aggregation.
    ///
    /// Sorted by day ascending, then cost descending, then project. The aggregate row (`isOthers`)
    /// always sorts last within its day, whatever its size, so a stacked chart draws it as one
    /// stable band at one end instead of letting it wander through the stack.
    public let byDayProject: [DayProjectEntry]
    /// The projects that get a band of their own, in rank order, ranked over the **whole archive**.
    ///
    /// Global, not per-range, and that is the whole point. Ranked inside the selected range, dragging
    /// the handle would re-rank mid-gesture: the same colour would become a different project and a
    /// band would appear to grow when it had merely changed owner. Identity has to be stable for the
    /// height to mean anything. A project outside this list stays inside `isOthers` even on a day it
    /// dominates — the honest cost of a stable axis.
    public let rankedProjects: [String]
    /// How many distinct projects **in the selected range** were folded into the `isOthers` rows.
    ///
    /// Zero means nothing was folded and no aggregate row exists. Any other value is the cut stating
    /// itself: a top-N that does not say it is a top-N is an instrument that lies.
    public let otherProjectCount: Int
    /// Every project in the archive, mapped to its **global** rank by total volume — 0 is the
    /// largest. Range-independent, exactly like `rankedProjects`, of which it is the source.
    ///
    /// Exposed so a consumer that wants to cut at some other N — or to assign a colour to a project
    /// that did not make the eight — gets the *same* ordering the fold used instead of recomputing
    /// one over whatever is on screen. A rank derived from the slice re-orders under a drag, and the
    /// band a colour belongs to changes owner mid-gesture.
    public let projectRankByTotal: [String: Int]
    /// Distribution of session sizes: `sessionTokenBuckets[i]` is how many sessions fall in the
    /// half-open range `sessionTokenBucketEdges[i] ..< sessionTokenBucketEdges[i + 1]`.
    ///
    /// A top-ten answers "which sessions were dearest" and cannot answer "is the spend concentrated
    /// in a few sessions or spread across all of them" — the sessions it drops *are* the evidence for
    /// the second question. This keeps that evidence at a fixed 20 integers instead of one object per
    /// session, so the payload does not grow with an archive that never expires.
    ///
    /// The edges are **fixed and data-independent**. Deriving them from each range's own minimum and
    /// maximum would make the same bar mean a different thing at every drag position, and two periods
    /// would stop being comparable — a histogram whose axis moves is a chart that cannot be read.
    /// Empty buckets in the middle are kept for the same reason: a gap in the distribution is data,
    /// and compacting it would bend the axis.
    public let sessionTokenBuckets: [Int]
    /// Median session size in tokens, computed from the **exact** session totals, never from the
    /// histogram.
    ///
    /// A median read off log-spaced buckets is only accurate to a bucket width, and these are a
    /// factor of √10 apart — the answer would be wrong by up to 3×. For an even number of sessions
    /// this is the floor of the mean of the two central values. Zero when the window has no sessions.
    public let medianSessionTokens: Int
    /// How many sessions the window contains — the histogram's sample size, and the true total
    /// behind `sessions` whether or not that list was cut.
    ///
    /// Without it a caller cannot tell a flat distribution from a nearly empty one, since both draw
    /// as short bars.
    public let totalSessions: Int
    /// **Every** session in the window, sorted by cost descending — the same order, and the same
    /// numbers, that `topSessions` shows the head of and `sessionTokenBuckets` counts.
    ///
    /// Kept alongside the histogram rather than replaced by it. The histogram gives the *shape* at a
    /// fixed 20 integers however large the archive grows; this gives per-session identity, which is
    /// what a swarm needs to say *which* session the outlier was. Measured cost of keeping it: 0.43
    /// MB and ~7 ms of the fold at a synthesised two-year archive — affordable, and the reason it is
    /// not cut by default.
    ///
    /// When a caller does ask for a cut, `totalSessions` still reports the true total and
    /// `sessionsTruncated` says so out loud. A top-N that does not admit it is a top-N is an
    /// instrument that lies — and a cut ordered by cost is the *worst* cut for the question this
    /// list exists to answer, since it discards precisely the tail that says whether spend is
    /// concentrated or spread.
    public let sessions: [SessionUsageEntry]
    /// Per-month coverage over the selected range (EXB-6.1).
    ///
    /// Exists because a month-over-month comparison across an incomplete month is false by
    /// construction: on the 25th, August holds 25 days and July holds 31, so *every* project reads as
    /// having slowed down. The consumer needs to know which months are comparable before it draws a
    /// difference. Sorted by month ascending.
    public let monthCoverage: [MonthCoverage]
    /// Spend in the current calendar month, USD — the run-rate projection numerator (AC2).
    public let monthToDateCost: Double
    /// Total token volume (input + output + cache read + cache write) in the current calendar month
    /// (EXB-5.7).
    ///
    /// Exists because tokens are the dashboard's primary quantity — the plan is a subscription, not
    /// a per-token invoice — and the monthly projection is therefore a projection of *tokens*.
    /// Deriving it from `monthToDateCost` via the window's tokens÷cost ratio was wrong whenever the
    /// month's model mix differed from the window's, which is most months.
    public let monthToDateTokens: Int
    /// Days the archive can vouch for having watched (EXB-5.7).
    ///
    /// A day inside this set with no entry in `byDayModel` really had no usage. A day *outside* it is
    /// unknown — most likely its transcript was deleted before exímIABar ever read it. The dashboard
    /// draws the two differently instead of painting both as zero, which is the whole reason the
    /// aggregate stopped expiring.
    public let coveredDays: Set<Date>

    /// `true` when at least one project was folded into an aggregate row.
    ///
    /// Derived rather than stored: a flag somebody has to remember to set is a flag that eventually
    /// disagrees with the number beside it.
    public var projectsTruncated: Bool { self.otherProjectCount > 0 }

    /// `true` when `sessions` holds fewer rows than the window really contains.
    ///
    /// Derived rather than stored: a flag somebody has to remember to set is a flag that eventually
    /// disagrees with the array beside it.
    public var sessionsTruncated: Bool { self.sessions.count < self.totalSessions }

    /// The new dimensions are appended with defaults so every existing call site keeps compiling.
    ///
    /// `totalSessions` defaults to `nil`, not to `0`: a fixture that hands over sessions and says
    /// nothing about the total means "these are all of them", and defaulting to zero would make such
    /// a fixture claim a *negative* truncation. `nil` resolves to `sessions.count`.
    public init(
        byDayModel: [ModelCostEntry],
        byProject: [ProjectUsageEntry],
        heatmap: [[HeatmapBucket]],
        topSessions: [SessionUsageEntry],
        monthToDateCost: Double,
        monthToDateTokens: Int = 0,
        coveredDays: Set<Date> = [],
        byDayProject: [DayProjectEntry] = [],
        rankedProjects: [String] = [],
        otherProjectCount: Int = 0,
        projectRankByTotal: [String: Int] = [:],
        sessionTokenBuckets: [Int] = [],
        medianSessionTokens: Int = 0,
        sessions: [SessionUsageEntry] = [],
        totalSessions: Int? = nil,
        monthCoverage: [MonthCoverage] = [])
    {
        self.byDayModel = byDayModel
        self.byProject = byProject
        self.heatmap = heatmap
        self.topSessions = topSessions
        self.monthToDateCost = monthToDateCost
        self.monthToDateTokens = monthToDateTokens
        self.coveredDays = coveredDays
        self.byDayProject = byDayProject
        self.rankedProjects = rankedProjects
        self.otherProjectCount = otherProjectCount
        self.projectRankByTotal = projectRankByTotal
        self.sessionTokenBuckets = sessionTokenBuckets
        self.medianSessionTokens = medianSessionTokens
        self.sessions = sessions
        self.totalSessions = totalSessions ?? sessions.count
        self.monthCoverage = monthCoverage
    }

    // MARK: - Session histogram geometry

    /// How many projects get a band of their own before the rest are aggregated.
    ///
    /// Eight is a legibility ceiling, not a memory one: a stacked chart 760 pt wide cannot separate
    /// more bands than that, so a ninth series would be paid for and never seen.
    public static let maxRankedProjects = 8

    /// Number of buckets in `sessionTokenBuckets`.
    public static let sessionTokenBucketCount = 20

    /// The 21 boundaries of the 20 buckets, in tokens: 1, 3, 10, 31, 100, … up to 10¹⁰.
    ///
    /// Published rather than left implicit so the consumer draws the axis the fold actually used. A
    /// chart that re-derives its own edges is a chart that will one day disagree with the counts
    /// sitting on it.
    public static let sessionTokenBucketEdges: [Int] = (0...UsageAnalytics.sessionTokenBucketCount)
        .map { Int(pow(10.0, Double($0) / 2.0)) }

    /// Which bucket a session of `tokens` falls into — the single implementation of the binning.
    ///
    /// The consumer needs this to mark `topSessions` on the histogram. Exposing it is what stops a
    /// second, subtly different binning appearing at the drawing end: the mark and the bar underneath
    /// it would then be computed by two different rules.
    ///
    /// Buckets are √10 apart (`floor(2 · log₁₀ tokens)`). A session cannot hold zero tokens — the
    /// scan skips entries whose four counters are all zero — but the clamp is here anyway, because a
    /// `log` of zero is the kind of thing that reaches production through a caller, not through the
    /// fold.
    public static func sessionTokenBucketIndex(forTokens tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        let index = Int((2 * log10(Double(tokens))).rounded(.down))
        return Swift.min(Swift.max(index, 0), Self.sessionTokenBucketCount - 1)
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

/// One project's totals on one day (EXB-6.1) — the grain `ProjectUsageEntry` folds away.
///
/// `day` is start-of-day in the **local** time zone, identical to the bucket key it is copied from.
/// No date arithmetic happens here or at the fold: the day is carried through, never recomputed,
/// so there is nothing in this path that could drift from the archive's own bucketing.
public struct DayProjectEntry: Sendable, Equatable, Identifiable {
    /// Unique within a scan: the fold emits one row per `(day, project)` pair, plus at most one
    /// aggregate row per day.
    public var id: String { "\(self.day.timeIntervalSince1970)|\(self.project)" }
    public let day: Date
    /// The project basename (last path component of `cwd`), or "Unknown". **Empty on the aggregate
    /// row** — a real project name can never be empty (`projectName(fromCWD:)` returns "Unknown"
    /// instead), so the two can never be confused.
    public let project: String
    /// Total tokens (input + output + cache read + cache write) for the project on that day.
    public let totalTokens: Int
    public let costUSD: Double
    /// `true` on the row that carries every project outside `rankedProjects` for that day.
    ///
    /// This row is a **sum, not a remainder**: the nine rows of a day add up to that day's real
    /// total. Discarding the tail instead of aggregating it would make every total on the chart
    /// quietly smaller than the totals everywhere else in the panel.
    ///
    /// A boolean rather than a magic project name: the flag cannot be forged by a directory that
    /// happens to be called whatever the sentinel is.
    public let isOthers: Bool

    public init(
        day: Date,
        project: String,
        totalTokens: Int,
        costUSD: Double,
        isOthers: Bool = false)
    {
        self.day = day
        self.project = project
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.isOthers = isOthers
    }
}

/// How much of one calendar month the archive can vouch for, within the selected range (EXB-6.1).
///
/// The cascade that compares months needs this before it draws a single bar. On the 25th of a
/// 31-day month, an unguarded month-over-month difference reports every project as having slowed
/// down — not because anything slowed, but because the month is six days short. That is the same
/// shape of defect as a percentage taken against an incomplete denominator, and it is invisible
/// precisely because every bar agrees with every other bar.
public struct MonthCoverage: Sendable, Equatable, Identifiable {
    public var id: Date { self.month }
    /// First day of the month, local time zone.
    public let month: Date
    /// Days the calendar says this month has — 28, 29, 30 or 31.
    public let daysInMonth: Int
    /// Days of this month that fall inside the selected range. Lower than `daysInMonth` when the
    /// range clips the month, which is a fact about the *selection*, not about the archive.
    public let daysInRange: Int
    /// Days of this month the archive was watching. Lower than `daysInRange` when history is
    /// genuinely missing — a transcript deleted before exímIABar ever read it.
    public let daysCovered: Int

    /// `true` only when every day of the calendar month is both selected and vouched for.
    ///
    /// Deliberately measured against `daysInMonth` and not against days elapsed: the question this
    /// answers is "may I compare this month with a whole one", and a month still in progress may
    /// not.
    public var isComplete: Bool { self.daysCovered == self.daysInMonth }

    public init(month: Date, daysInMonth: Int, daysInRange: Int, daysCovered: Int) {
        self.month = month
        self.daysInMonth = daysInMonth
        self.daysInRange = daysInRange
        self.daysCovered = daysCovered
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
