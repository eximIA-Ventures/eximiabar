import ClaudeBarCore
import Foundation

/// One calendar day's roll-up for the dashboard charts (EXB-2.3 T4 / AC4–AC5).
///
/// `tokens` is the combined input + output count for the day — the tokens-per-day chart plots it
/// directly, the cost-per-day chart plots `costUSD`.
struct DashboardDailyEntry: Equatable, Sendable {
    /// Start-of-day in the user's local time zone.
    let date: Date
    /// Total spend for the day, USD.
    let costUSD: Double
    /// Total tokens (input + output) for the day.
    let tokens: Int
}

/// One model's 30-day totals for the breakdown table (EXB-2.3 T4 / AC6).
struct DashboardModelEntry: Equatable, Sendable, Identifiable {
    /// The normalized model identifier (e.g. `"claude-sonnet-4"`). Doubles as the row `id` — the
    /// builder folds per-`(day, model)` rows into one row per model, so model names are unique.
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

/// The fully-derived dashboard view model (EXB-2.3 T4).
///
/// Built off-MainActor from the `ProviderCost` that `CostScanner` already produces (EXB-1.7) — the
/// dashboard does **no** JSONL parsing of its own (it reuses the scanner's aggregation). `dailyCosts`
/// and `dailyTokens` share the same day axis (one entry per calendar day in the window, zero-filled
/// so the charts show a continuous 30-day span even on days with no usage).
struct DashboardData: Equatable, Sendable {
    /// Per-day cost + tokens, ascending by date, zero-filled across the full window (AC4/AC5).
    let dailyCosts: [DashboardDailyEntry]
    /// Alias of `dailyCosts` for the tokens chart — same day axis, same entries (AC5). Kept as a
    /// distinct property so each chart binds to an explicit array per the story's `DashboardData`
    /// shape, but the two are identical by construction.
    var dailyTokens: [DashboardDailyEntry] { dailyCosts }

    /// Per-model 30-day totals, sorted by cost descending (AC6).
    let byModel: [DashboardModelEntry]

    let todayCost: Double
    let todayTokens: Int
    let sevenDayCost: Double
    let sevenDayTokens: Int
    let thirtyDayCost: Double
    let thirtyDayTokens: Int

    /// `true` when the scan returned no priced entries at all → the empty state is shown (AC10).
    var isEmpty: Bool { byModel.isEmpty }
}

extension DashboardData {
    /// Build the dashboard view model from a `ProviderCost` (EXB-1.7).
    ///
    /// - `cost`: the scanner output. Its `byModel` carries per-`(day, model)` rows with priced
    ///   cost and token counts — everything the charts and table need, already parsed.
    /// - `windowDays`: how many trailing calendar days the day axis spans (the `costDays` setting,
    ///   AC4). The axis is zero-filled for that whole span so a sparse history still renders a full
    ///   30-day chart.
    /// - `now`: injected for deterministic day bucketing in tests.
    ///
    /// Anti-freeze: this is pure value transformation (no I/O), safe to call from `Task.detached`.
    static func build(from cost: ProviderCost, windowDays: Int, now: Date = Date()) -> DashboardData {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let span = max(1, windowDays)

        // --- Daily axis (AC4/AC5): one zero-filled entry per day across the window ---
        // Sum cost + tokens per calendar day from the scanner's per-(day, model) rows.
        var costByDay: [Date: Double] = [:]
        var tokensByDay: [Date: Int] = [:]
        for entry in cost.byModel {
            let day = calendar.startOfDay(for: entry.date)
            costByDay[day, default: 0] += entry.cost
            tokensByDay[day, default: 0] += entry.totalTokens
        }

        var daily: [DashboardDailyEntry] = []
        daily.reserveCapacity(span)
        // Walk oldest → newest so the chart's X axis is ascending.
        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            daily.append(DashboardDailyEntry(
                date: day,
                costUSD: costByDay[day] ?? 0,
                tokens: tokensByDay[day] ?? 0))
        }

        // --- Model breakdown (AC6): fold per-(day, model) rows into one row per model ---
        var byModelAcc: [String: (input: Int, output: Int, cost: Double)] = [:]
        for entry in cost.byModel {
            byModelAcc[entry.model, default: (0, 0, 0)].input += entry.inputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].output += entry.outputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].cost += entry.cost
        }
        let byModel = byModelAcc
            .map { model, totals in
                DashboardModelEntry(
                    model: model,
                    inputTokens: totals.input,
                    outputTokens: totals.output,
                    costUSD: totals.cost)
            }
            // Sort by cost desc, then model asc for a stable order (AC6).
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.model < $1.model }

        // --- Summary cards (AC7): today / last 7 / last 30 (window) totals ---
        let sevenDayEarliest = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var sevenDayCost = 0.0, sevenDayTokens = 0
        for entry in cost.byModel {
            let day = calendar.startOfDay(for: entry.date)
            if day >= sevenDayEarliest, day <= todayStart {
                sevenDayCost += entry.cost
                sevenDayTokens += entry.totalTokens
            }
        }

        return DashboardData(
            dailyCosts: daily,
            byModel: byModel,
            // `ProviderCost.today*` are already today's totals over the scan window (EXB-1.7).
            todayCost: cost.today,
            todayTokens: cost.todayTokens,
            sevenDayCost: sevenDayCost,
            sevenDayTokens: sevenDayTokens,
            // `last30Days*` are the window totals — the window is `costDays` (default 30).
            thirtyDayCost: cost.last30Days,
            thirtyDayTokens: cost.last30DaysTokens)
    }
}
