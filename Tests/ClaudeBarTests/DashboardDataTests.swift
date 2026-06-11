import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests the pure `DashboardData.build` transformation (EXB-2.3 T4) — zero-fill day axis, per-model
/// fold + sort, and the today / 7-day / 30-day summary windows. All deterministic via injected `now`.
struct DashboardDataTests {
    /// Local start-of-day `offset` days before `now`.
    private func day(_ offset: Int, from now: Date) -> Date {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: -offset, to: todayStart)!
    }

    private func model(_ name: String, _ date: Date, input: Int, output: Int, cost: Double) -> ModelCostEntry {
        ModelCostEntry(model: name, date: date, inputTokens: input, outputTokens: output, cost: cost)
    }

    // MARK: - Day axis (AC4/AC5)

    /// The daily axis is zero-filled across the full window, ascending by date, even when only a few
    /// days carry usage.
    @Test
    func dailyAxisIsZeroFilledAndAscending() {
        let now = Date()
        let cost = ProviderCost(
            today: 1.0, last30Days: 3.0, todayTokens: 100, last30DaysTokens: 300,
            byModel: [
                model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0),
                model("claude-opus-4", day(5, from: now), input: 120, output: 80, cost: 2.0),
            ])

        let data = DashboardData.build(from: cost, windowDays: 30, now: now)

        #expect(data.dailyCosts.count == 30)
        // Ascending by date.
        let dates = data.dailyCosts.map(\.date)
        #expect(dates == dates.sorted())
        // Last entry is today and carries today's roll-up.
        #expect(data.dailyCosts.last?.date == day(0, from: now))
        #expect(data.dailyCosts.last?.costUSD == 1.0)
        #expect(data.dailyCosts.last?.tokens == 100)
        // The day 5 ago carries its roll-up; an arbitrary empty day is zero.
        let fiveAgo = data.dailyCosts.first { $0.date == day(5, from: now) }
        #expect(fiveAgo?.costUSD == 2.0)
        #expect(fiveAgo?.tokens == 200)
        let tenAgo = data.dailyCosts.first { $0.date == day(10, from: now) }
        #expect(tenAgo?.costUSD == 0)
        #expect(tenAgo?.tokens == 0)
    }

    /// `dailyTokens` is identical to `dailyCosts` (same axis, AC5).
    @Test
    func dailyTokensMirrorsDailyCosts() {
        let now = Date()
        let cost = ProviderCost(
            today: 1.0, last30Days: 1.0, todayTokens: 100, last30DaysTokens: 100,
            byModel: [model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0)])

        let data = DashboardData.build(from: cost, windowDays: 7, now: now)
        #expect(data.dailyTokens == data.dailyCosts)
        #expect(data.dailyCosts.count == 7)
    }

    // MARK: - Model breakdown (AC6)

    /// Per-`(day, model)` rows fold into one row per model, summing tokens + cost, sorted by cost desc.
    @Test
    func modelBreakdownFoldsAndSortsByCostDesc() {
        let now = Date()
        let cost = ProviderCost(
            today: 0, last30Days: 6.0, todayTokens: 0, last30DaysTokens: 600,
            byModel: [
                // sonnet across two days → folds to one row.
                model("claude-sonnet-4", day(0, from: now), input: 50, output: 50, cost: 1.0),
                model("claude-sonnet-4", day(1, from: now), input: 50, output: 50, cost: 1.0),
                // opus single day, higher cost.
                model("claude-opus-4", day(0, from: now), input: 100, output: 100, cost: 4.0),
            ])

        let data = DashboardData.build(from: cost, windowDays: 30, now: now)

        #expect(data.byModel.count == 2)
        // Sorted by cost desc: opus (4.0) before sonnet (2.0).
        #expect(data.byModel[0].model == "claude-opus-4")
        #expect(data.byModel[0].costUSD == 4.0)
        #expect(data.byModel[1].model == "claude-sonnet-4")
        // Sonnet folded: input 100, output 100, cost 2.0.
        #expect(data.byModel[1].inputTokens == 100)
        #expect(data.byModel[1].outputTokens == 100)
        #expect(data.byModel[1].costUSD == 2.0)
    }

    // MARK: - Summary windows (AC7)

    /// Today / 7-day / 30-day summaries: today + 30d come straight from `ProviderCost`; 7d is computed.
    @Test
    func summaryWindows() {
        let now = Date()
        let cost = ProviderCost(
            today: 1.0, last30Days: 10.0, todayTokens: 100, last30DaysTokens: 1000,
            byModel: [
                model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0),   // today, in 7d
                model("claude-sonnet-4", day(3, from: now), input: 120, output: 80, cost: 2.0),  // in 7d
                model("claude-opus-4", day(20, from: now), input: 300, output: 200, cost: 7.0),  // outside 7d
            ])

        let data = DashboardData.build(from: cost, windowDays: 30, now: now)

        #expect(data.todayCost == 1.0)
        #expect(data.todayTokens == 100)
        // 7d window includes today (1.0/100) + day 3 (2.0/200) = 3.0/300; excludes day 20.
        #expect(data.sevenDayCost == 3.0)
        #expect(data.sevenDayTokens == 300)
        // 30d mirrors ProviderCost window totals.
        #expect(data.thirtyDayCost == 10.0)
        #expect(data.thirtyDayTokens == 1000)
    }

    // MARK: - Empty (AC10)

    /// A scan with no priced entries yields `isEmpty == true` and a still-zero-filled day axis.
    @Test
    func emptyWhenNoModelEntries() {
        let now = Date()
        let cost = ProviderCost(
            today: 0, last30Days: 0, todayTokens: 0, last30DaysTokens: 0, byModel: [])

        let data = DashboardData.build(from: cost, windowDays: 30, now: now)

        #expect(data.isEmpty)
        #expect(data.byModel.isEmpty)
        // The axis is still present (zero-filled) so the empty state — not a broken chart — is what
        // the view decides to show based on `isEmpty`.
        #expect(data.dailyCosts.count == 30)
        #expect(data.dailyCosts.allSatisfy { $0.costUSD == 0 && $0.tokens == 0 })
    }

    /// `windowDays` is clamped to a minimum of 1 so a degenerate setting still produces a valid axis.
    @Test
    func windowClampedToAtLeastOneDay() {
        let now = Date()
        let cost = ProviderCost(
            today: 1.0, last30Days: 1.0, todayTokens: 10, last30DaysTokens: 10,
            byModel: [model("claude-sonnet-4", day(0, from: now), input: 5, output: 5, cost: 1.0)])

        let data = DashboardData.build(from: cost, windowDays: 0, now: now)
        #expect(data.dailyCosts.count == 1)
        #expect(data.dailyCosts.first?.date == day(0, from: now))
    }
}
