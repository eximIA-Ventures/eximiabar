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
    ///
    /// Anti-freeze: pure value transformation (no I/O), safe from `Task.detached`.
    static func build(from analytics: UsageAnalytics, period: DashboardPeriod, now: Date = Date()) -> DashboardData {
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

        return DashboardData(
            period: period,
            dailyCosts: daily,
            byModel: byModel,
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
            monthProjection: projection)
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
