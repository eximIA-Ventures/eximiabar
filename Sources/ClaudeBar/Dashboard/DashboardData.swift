import ClaudeBarCore
import Foundation
import os

/// One calendar day's roll-up for the dashboard charts (EXB-2.3 / EXB-3.2).
///
/// `tokens` is the combined input + output count for the day; the cost-per-day chart plots `costUSD`,
/// the stacked-tokens chart plots the four `cache*`/input/output components (EXB-3.2 AC4).
struct DashboardDailyEntry: Equatable, Sendable {
    /// Start-of-day in the user's local time zone.
    let date: Date
    /// Total spend for the day, USD.
    let costUSD: Double
    /// Total tokens (input + output) for the day. Kept as the historical "tokens per day" semantic.
    let tokens: Int
    /// Input tokens for the day (stacked-tokens chart, AC4).
    let inputTokens: Int
    /// Output tokens for the day (AC4).
    let outputTokens: Int
    /// Cache-read tokens for the day (AC4).
    let cacheReadTokens: Int
    /// Cache-write (creation) tokens for the day (AC4).
    let cacheWriteTokens: Int

    init(
        date: Date,
        costUSD: Double,
        tokens: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0)
    {
        self.date = date
        self.costUSD = costUSD
        self.tokens = tokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// One model's window totals for the breakdown table (EXB-2.3 / EXB-3.2 AC5).
struct DashboardModelEntry: Equatable, Sendable, Identifiable {
    /// The normalized model identifier — doubles as the row `id` (one row per model).
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

/// One `(day, model)` token-volume roll-up for the "Models per day" stacked chart (EXB-3.7 AC4).
///
/// `tokens` is the combined activity volume (input + output + cache read + cache write) for the day
/// and model — the same volume metric the heatmap uses, so a busy cache-heavy day reads as activity.
/// A value type so it is `Sendable` and the aggregation can run inside the off-main `Task.detached`
/// pipeline (anti-freeze invariant).
struct DailyModelEntry: Equatable, Sendable, Identifiable {
    /// Stable identity for `ForEach` — one entry per `(day, model)`.
    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(modelName)" }
    /// Start-of-day in the user's local time zone.
    let date: Date
    /// The normalized model identifier (matches `DashboardModelEntry.model`).
    let modelName: String
    /// Total token volume (input + output + cache read + cache write) for the `(day, model)`.
    let tokens: Int
}

/// The busiest weekday over the window (EXB-4.5 AC3): a named pair so `DashboardData` stays a flat
/// `Equatable`/`Sendable` value (tuples can't be optional stored properties with synthesized `==`).
struct BusiestDay: Equatable, Sendable {
    /// 0 = Sunday … 6 = Saturday (`Calendar.component(.weekday) - 1`).
    let dayOfWeek: Int
    /// Total spend for that weekday over the window, USD.
    let cost: Double
}

/// The window's top model by token volume (EXB-4.5 AC3 top-model card).
struct TopModel: Equatable, Sendable {
    /// The normalized model identifier (matches `DashboardModelEntry.model`).
    let name: String
    /// Total token volume (input + output + cache read + cache write) for the model.
    let tokens: Int
}

/// Per-token USD prices for the cache-savings estimate (EXB-4.5 AC1).
///
/// The dashboard cannot `await` the `Pricing` actor inside the pure `DashboardData.build`, so the
/// caller resolves the dominant model's `(input, output)` prices off-main (in the `Task.detached`
/// scan) and passes them in via this value type. `cacheRead` is derived from `input` using Claude's
/// documented **cache-read = 0.1 × base input** convention — the single place that ratio lives, so
/// the view never hardcodes a per-model price (AC4). A zeroed default keeps every existing
/// `DashboardData.build` call site (tests, in-process callers) compiling unchanged.
struct CachePricing: Equatable, Sendable {
    /// USD per output token (the "would-have-paid" price for re-sending cached context).
    let outputPerToken: Double
    /// USD per cache-read token (Claude prices cache reads at ~0.1× base input).
    let cacheReadPerToken: Double

    init(outputPerToken: Double = 0, cacheReadPerToken: Double = 0) {
        self.outputPerToken = outputPerToken
        self.cacheReadPerToken = cacheReadPerToken
    }

    /// Claude's cache-read multiplier vs. base input price (Anthropic prompt-caching pricing):
    /// a cache-read token costs ~10% of a base input token.
    static let cacheReadInputRatio = 0.1

    /// Build a `CachePricing` from the dominant model's base `(input, output)` per-token prices,
    /// deriving `cacheReadPerToken` via the documented `0.1 × input` ratio (AC1/AC4).
    static func claude(inputPerToken: Double, outputPerToken: Double) -> CachePricing {
        CachePricing(
            outputPerToken: outputPerToken,
            cacheReadPerToken: inputPerToken * cacheReadInputRatio)
    }
}

/// The fully-derived analytics dashboard view model (EXB-3.2).
///
/// Built off-MainActor from the `UsageAnalytics` the `CostScanner` produces (EXB-1.7 + EXB-3.2) — the
/// dashboard does **no** JSONL parsing of its own. `dailyCosts` is the zero-filled day axis shared by
/// the cost and stacked-tokens charts.
struct DashboardData: Equatable, Sendable {
    /// The period this data was built for (drives labels + CSV filename, AC1/AC9).
    let period: DashboardPeriod
    /// Per-day cost + token split, ascending by date, zero-filled across the full window (AC3/AC4).
    let dailyCosts: [DashboardDailyEntry]
    /// Alias for the tokens chart — same day axis (AC4).
    var dailyTokens: [DashboardDailyEntry] { dailyCosts }

    /// Per-model totals over the window, sorted by cost descending (AC5).
    let byModel: [DashboardModelEntry]
    /// Per-`(day, model)` token volume for the "Models per day" stacked chart (EXB-3.7 AC4). Ascending
    /// by date; one entry per `(day, model)` that has activity.
    let byDayByModel: [DailyModelEntry]
    /// Per-project totals over the window, sorted by cost descending (AC6).
    let byProject: [ProjectUsageEntry]
    /// Weekday × hour token-volume heatmap, 7 × 24 (AC7).
    let heatmap: [[HeatmapBucket]]
    /// Top 10 sessions by cost (AC8).
    let topSessions: [SessionUsageEntry]

    let todayCost: Double
    let todayTokens: Int
    let sevenDayCost: Double
    let sevenDayTokens: Int
    let thirtyDayCost: Double
    let thirtyDayTokens: Int
    /// Average daily spend over the selected period (AC2).
    let averageDailyCost: Double
    /// Current-month run-rate projection: `(month-to-date spend ÷ days elapsed) × days in month` (AC2).
    let monthProjection: Double
    /// Projected total tokens for the current month, derived from `monthProjection` using the period's
    /// tokens÷cost ratio (EXB-3.7 AC19). `0` when there is no cost to derive a ratio from.
    let projectedTokens: Int

    // MARK: - Efficiency insights (EXB-4.5)

    /// Cache hit rate over the window: `cacheReadTokens / (inputTokens + cacheReadTokens)`, `0…1`
    /// (AC1). `0` when there is no input/cache activity to divide by.
    let cacheHitRate: Double
    /// Estimated USD saved by serving cache reads instead of re-sending that context at output price
    /// (AC1): `cacheReadTokens × (outputPerToken − cacheReadPerToken)` for the dominant model. `0`
    /// when no `CachePricing` was supplied (e.g. tests) or there are no cache reads.
    let estimatedCacheSavings: Double
    /// Today's spend relative to the period's daily average (AC2): `(todayCost − avg) / avg`, signed.
    /// `nil` when there is no usage **today** in the window (the "Sem uso hoje" case, AC2-#7).
    let dailyDelta: Double?
    /// Busiest hour of day (0…23) by total token volume across the heatmap (AC3 peak-hour card).
    let peakHour: Int
    /// The weekday with the highest cost in the window (AC3 busiest-day card): `(0=Sun…6=Sat, cost)`.
    /// `nil` when the window has no spend.
    let busiestDay: BusiestDay?
    /// The model with the most token volume in the window (AC3 top-model card). `nil` when empty.
    let topModelByTokens: TopModel?

    /// `true` when the scan returned no priced entries at all → the empty state is shown.
    var isEmpty: Bool { byModel.isEmpty }

    // MARK: - Period totals (EXB-3.6 AC14)

    /// Total spend over the selected window — the highlight number on the cost card header.
    var totalCost: Double { dailyCosts.reduce(0) { $0 + $1.costUSD } }

    /// Total tokens (all four token types) over the window — the highlight number on the tokens card.
    var totalTokens: Int {
        dailyCosts.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
    }

    /// Total heatmap volume over the window — the highlight number on the heatmap card.
    var totalHeatmapTokens: Int { heatmap.flatMap { $0 }.reduce(0) { $0 + $1.tokens } }

    // MARK: - Period date range (EXB-3.6 AC13)

    /// The first day of the window (inclusive) — start of the section subtitle range.
    var rangeStart: Date? { dailyCosts.first?.date }
    /// The last day of the window (inclusive, normally today) — end of the section subtitle range.
    var rangeEnd: Date? { dailyCosts.last?.date }

    // MARK: - Consistent model → colour mapping (EXB-3.6 AC12)

    /// The window's models, ordered by cost descending (the donut/table order). The stable order is
    /// what makes the colour assignment consistent across the donut, the table, and any future
    /// per-model chart: model *N* always gets palette colour *N* for a given period.
    var sortedModelNames: [String] { byModel.map(\.model) }
}

extension DashboardData {
    /// Build the analytics dashboard view model from a `UsageAnalytics` scan (EXB-3.2).
    ///
    /// - `analytics`: the rich scan output (per-`(day, model)` rows with cache split, projects,
    ///   heatmap, sessions, month-to-date spend).
    /// - `period`: the selected period (its `.days` is the day-axis span).
    /// - `now`: injected for deterministic day bucketing in tests.
    /// - `cachePricing`: the dominant model's output / cache-read prices, resolved off-main by the
    ///   caller (EXB-4.5 AC1). Defaults to zero so existing call sites need no change.
    ///
    /// Anti-freeze: pure value transformation (no I/O), safe from `Task.detached`.
    static func build(
        from analytics: UsageAnalytics,
        period: DashboardPeriod,
        now: Date = Date(),
        cachePricing: CachePricing = CachePricing()) -> DashboardData
    {
        // AC8: instrument the pure aggregation so Instruments can see build vs. scan vs. apply.
        let signposter = CostScanner.perfSignposter
        let buildState = signposter.beginInterval("DashboardData.build", "period=\(period.days)d")
        defer { signposter.endInterval("DashboardData.build", buildState) }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let span = max(1, period.days)

        // --- Daily axis (AC3/AC4): one zero-filled entry per day, summing the token split ---
        struct DayAcc { var cost = 0.0; var input = 0; var output = 0; var cacheRead = 0; var cacheWrite = 0 }
        var byDay: [Date: DayAcc] = [:]
        for entry in analytics.byDayModel {
            let day = calendar.startOfDay(for: entry.date)
            byDay[day, default: DayAcc()].cost += entry.cost
            byDay[day]!.input += entry.inputTokens
            byDay[day]!.output += entry.outputTokens
            byDay[day]!.cacheRead += entry.cacheReadTokens
            byDay[day]!.cacheWrite += entry.cacheWriteTokens
        }

        var daily: [DashboardDailyEntry] = []
        daily.reserveCapacity(span)
        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let acc = byDay[day] ?? DayAcc()
            daily.append(DashboardDailyEntry(
                date: day,
                costUSD: acc.cost,
                tokens: acc.input + acc.output,
                inputTokens: acc.input,
                outputTokens: acc.output,
                cacheReadTokens: acc.cacheRead,
                cacheWriteTokens: acc.cacheWrite))
        }

        // --- Model breakdown (AC5): fold per-(day, model) into one row per model ---
        var byModelAcc: [String: (input: Int, output: Int, cost: Double)] = [:]
        for entry in analytics.byDayModel {
            byModelAcc[entry.model, default: (0, 0, 0)].input += entry.inputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].output += entry.outputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].cost += entry.cost
        }
        let byModel = byModelAcc
            .map { model, totals in
                DashboardModelEntry(model: model, inputTokens: totals.input, outputTokens: totals.output, costUSD: totals.cost)
            }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.model < $1.model }

        // --- Models-per-day (AC4): fold per-(day, model) token *volume* (in + out + cache r/w) ---
        // Sum activity volume per (startOfDay, model); emit ascending by date, model name as tiebreak.
        var byDayModelAcc: [Date: [String: Int]] = [:]
        for entry in analytics.byDayModel {
            let day = calendar.startOfDay(for: entry.date)
            let volume = entry.inputTokens + entry.outputTokens + entry.cacheReadTokens + entry.cacheWriteTokens
            byDayModelAcc[day, default: [:]][entry.model, default: 0] += volume
        }
        let byDayByModel: [DailyModelEntry] = byDayModelAcc
            .flatMap { day, models in
                models.map { DailyModelEntry(date: day, modelName: $0.key, tokens: $0.value) }
            }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.modelName < $1.modelName }

        // --- Summary windows (AC2): today / 7d / period totals from the day axis ---
        let sevenDayEarliest = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var todayCost = 0.0, todayTokens = 0
        var sevenDayCost = 0.0, sevenDayTokens = 0
        var periodCost = 0.0, periodTokens = 0
        for entry in daily {
            periodCost += entry.costUSD
            periodTokens += entry.tokens
            if entry.date == todayStart {
                todayCost += entry.costUSD
                todayTokens += entry.tokens
            }
            if entry.date >= sevenDayEarliest, entry.date <= todayStart {
                sevenDayCost += entry.costUSD
                sevenDayTokens += entry.tokens
            }
        }

        // --- Run-rate projection (AC2) ---
        let projection = Self.monthProjection(monthToDateCost: analytics.monthToDateCost, now: now, calendar: calendar)
        // Average daily over the selected period (clamped span).
        let averageDaily = periodCost / Double(span)

        // --- Projected tokens (AC19): scale the cost projection by the window's tokens÷cost ratio ---
        // Use the full token volume (all four types) so the ratio matches the tokens-first KPI numbers.
        let periodTokenVolume = daily.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
        let projectedTokens = Self.projectedTokens(periodTokens: periodTokenVolume, periodCost: periodCost, projectedCost: projection)

        // --- Efficiency insights (EXB-4.5) — all derived from the data already folded above (AC13) ---

        // AC1: cache hit rate = cacheRead ÷ (input + cacheRead) over the whole day axis.
        let totalInput = daily.reduce(0) { $0 + $1.inputTokens }
        let totalCacheRead = daily.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheHitRate = Self.cacheHitRate(input: totalInput, cacheRead: totalCacheRead)

        // AC1: dollars saved by serving cache reads vs. re-paying at output price.
        let estimatedCacheSavings = Double(totalCacheRead)
            * Swift.max(0, cachePricing.outputPerToken - cachePricing.cacheReadPerToken)

        // AC2: today vs. the period's daily average. `nil` when there is no usage today (AC2-#7).
        let dailyDelta = Self.dailyDelta(todayCost: todayCost, todayTokens: todayTokens, averageDailyCost: averageDaily)

        // AC3: busiest hour over the heatmap (argmax of token volume per hour).
        let peakHour = Self.peakHour(heatmap: analytics.heatmap)

        // AC3: busiest weekday by cost over the day axis (0=Sun…6=Sat).
        let busiestDay = Self.busiestDay(daily: daily, calendar: calendar)

        // AC3: top model by token volume (reuses the per-model fold; volume = all four token types).
        let topModelByTokens = Self.topModelByTokens(byDayModel: analytics.byDayModel)

        return DashboardData(
            period: period,
            dailyCosts: daily,
            byModel: byModel,
            byDayByModel: byDayByModel,
            byProject: analytics.byProject,
            heatmap: analytics.heatmap,
            topSessions: analytics.topSessions,
            todayCost: todayCost,
            todayTokens: todayTokens,
            sevenDayCost: sevenDayCost,
            sevenDayTokens: sevenDayTokens,
            thirtyDayCost: periodCost,
            thirtyDayTokens: periodTokens,
            averageDailyCost: averageDaily,
            monthProjection: projection,
            projectedTokens: projectedTokens,
            cacheHitRate: cacheHitRate,
            estimatedCacheSavings: estimatedCacheSavings,
            dailyDelta: dailyDelta,
            peakHour: peakHour,
            busiestDay: busiestDay,
            topModelByTokens: topModelByTokens)
    }

    // MARK: - Efficiency insight helpers (EXB-4.5) — pure, deterministic, unit-tested directly

    /// Cache hit rate (AC1): `cacheRead ÷ (input + cacheRead)`. Returns `0` when the denominator is
    /// zero (no input/cache activity) — never a NaN.
    static func cacheHitRate(input: Int, cacheRead: Int) -> Double {
        let denominator = input + cacheRead
        guard denominator > 0 else { return 0 }
        return Double(cacheRead) / Double(denominator)
    }

    /// Today-vs-average delta (AC2): `(todayCost − avg) / avg`, signed fraction. `nil` when there is
    /// no usage today (`todayTokens == 0` **and** `todayCost == 0`) or the average is zero — both map
    /// to the "Sem uso hoje" UI state rather than a misleading 0% or a divide-by-zero (AC2-#7).
    static func dailyDelta(todayCost: Double, todayTokens: Int, averageDailyCost: Double) -> Double? {
        guard todayTokens > 0 || todayCost > 0 else { return nil }
        guard averageDailyCost > 0 else { return nil }
        return (todayCost - averageDailyCost) / averageDailyCost
    }

    /// Peak hour of day (AC3): argmax of summed token volume per hour over the 7 × 24 heatmap.
    /// Returns `0` for an all-zero heatmap (a defined, stable default).
    static func peakHour(heatmap: [[HeatmapBucket]]) -> Int {
        var hourTotals = [Int](repeating: 0, count: 24)
        for day in heatmap {
            for bucket in day where bucket.hour >= 0 && bucket.hour < 24 {
                hourTotals[bucket.hour] += bucket.tokens
            }
        }
        // argmax; ties resolve to the earliest hour. All-zero → hour 0.
        return hourTotals.indices.max(by: { hourTotals[$0] < hourTotals[$1] }) ?? 0
    }

    /// Busiest weekday by cost (AC3) over the day axis. `nil` when no day has spend.
    static func busiestDay(daily: [DashboardDailyEntry], calendar: Calendar = .current) -> BusiestDay? {
        var costByDay: [Int: Double] = [:]
        for entry in daily where entry.costUSD > 0 {
            let dow = calendar.component(.weekday, from: entry.date) - 1 // 0 = Sun … 6 = Sat
            costByDay[dow, default: 0] += entry.costUSD
        }
        // Pick the max cost; ties resolve to the lower weekday index for determinism.
        guard let best = costByDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
        else { return nil }
        return BusiestDay(dayOfWeek: best.key, cost: best.value)
    }

    /// Top model by token volume (AC3): fold per-`(day, model)` rows by total volume (all four token
    /// types), then argmax. `nil` when there are no rows. Ties resolve to the lexicographically
    /// smaller model name for determinism.
    static func topModelByTokens(byDayModel: [ModelCostEntry]) -> TopModel? {
        var tokensByModel: [String: Int] = [:]
        for entry in byDayModel {
            let volume = entry.inputTokens + entry.outputTokens + entry.cacheReadTokens + entry.cacheWriteTokens
            tokensByModel[entry.model, default: 0] += volume
        }
        guard let best = tokensByModel.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
        else { return nil }
        return TopModel(name: best.key, tokens: best.value)
    }

    /// Projected monthly tokens (AC19): scale `projectedCost` by the window's tokens÷cost ratio.
    /// Returns `0` when the window has no cost (no ratio to project from).
    static func projectedTokens(periodTokens: Int, periodCost: Double, projectedCost: Double) -> Int {
        guard periodCost > 0 else { return 0 }
        let ratio = Double(periodTokens) / periodCost
        return Int((ratio * projectedCost).rounded())
    }

    /// Current-month run-rate projection (AC2): `(spent this month ÷ days elapsed) × days in month`.
    /// Days elapsed counts today as day 1; guards against a zero divisor.
    static func monthProjection(monthToDateCost: Double, now: Date, calendar: Calendar = .current) -> Double {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count
        else { return monthToDateCost }
        let elapsedComponent = calendar.dateComponents([.day], from: startOfMonth, to: now).day ?? 0
        let daysElapsed = max(1, elapsedComponent + 1)
        return (monthToDateCost / Double(daysElapsed)) * Double(daysInMonth)
    }

    /// Render the period's daily aggregate as CSV (AC9). Header + one row per day in the axis:
    /// `date,cost_usd,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens`.
    func csvExport() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        var lines = ["date,cost_usd,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens"]
        for entry in dailyCosts {
            let date = formatter.string(from: entry.date)
            let cost = String(format: "%.4f", entry.costUSD)
            lines.append("\(date),\(cost),\(entry.inputTokens),\(entry.outputTokens),\(entry.cacheReadTokens),\(entry.cacheWriteTokens)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
