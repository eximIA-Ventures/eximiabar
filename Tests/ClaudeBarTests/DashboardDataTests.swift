import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests the pure `DashboardData.build(from: UsageAnalytics, ...)` transformation (EXB-3.2) — the
/// zero-filled day axis, per-model fold + sort, and the today / 7-day / period summary windows. All
/// deterministic via injected `now`. Supersedes the EXB-2.3 `ProviderCost`-based builder.
struct DashboardDataTests {
    private func day(_ offset: Int, from now: Date) -> Date {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: -offset, to: todayStart)!
    }

    private func model(
        _ name: String,
        _ date: Date,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cost: Double) -> ModelCostEntry
    {
        ModelCostEntry(
            model: name, date: date,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            cost: cost)
    }

    private func analytics(byDayModel: [ModelCostEntry], monthToDate: Double = 0) -> UsageAnalytics {
        UsageAnalytics(
            byDayModel: byDayModel,
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: monthToDate)
    }

    // MARK: - Day axis

    @Test
    func dailyAxisIsZeroFilledAndAscending() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0),
            model("claude-opus-4", day(5, from: now), input: 120, output: 80, cost: 2.0),
        ])

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.dailyCosts.count == 30)
        let dates = data.dailyCosts.map(\.date)
        #expect(dates == dates.sorted())
        #expect(data.dailyCosts.last?.date == day(0, from: now))
        #expect(data.dailyCosts.last?.costUSD == 1.0)
        #expect(data.dailyCosts.last?.tokens == 100)
        let fiveAgo = data.dailyCosts.first { $0.date == day(5, from: now) }
        #expect(fiveAgo?.costUSD == 2.0)
        #expect(fiveAgo?.tokens == 200)
        let tenAgo = data.dailyCosts.first { $0.date == day(10, from: now) }
        #expect(tenAgo?.costUSD == 0)
        #expect(tenAgo?.tokens == 0)
    }

    @Test
    func dailyTokensMirrorsDailyCosts() {
        let now = Date()
        let a = analytics(byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0)])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        #expect(data.dailyTokens == data.dailyCosts)
        #expect(data.dailyCosts.count == 7)
    }

    // MARK: - Model breakdown

    @Test
    func modelBreakdownFoldsAndSortsByCostDesc() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 50, output: 50, cost: 1.0),
            model("claude-sonnet-4", day(1, from: now), input: 50, output: 50, cost: 1.0),
            model("claude-opus-4", day(0, from: now), input: 100, output: 100, cost: 4.0),
        ])

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.byModel.count == 2)
        #expect(data.byModel[0].model == "claude-opus-4")
        #expect(data.byModel[0].costUSD == 4.0)
        #expect(data.byModel[1].model == "claude-sonnet-4")
        #expect(data.byModel[1].inputTokens == 100)
        #expect(data.byModel[1].outputTokens == 100)
        #expect(data.byModel[1].costUSD == 2.0)
    }

    // MARK: - Summary windows

    @Test
    func summaryWindows() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0),   // today, in 7d
            model("claude-sonnet-4", day(3, from: now), input: 120, output: 80, cost: 2.0),  // in 7d
            model("claude-opus-4", day(20, from: now), input: 300, output: 200, cost: 7.0),  // outside 7d
        ])

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.todayCost == 1.0)
        #expect(data.todayTokens == 100)
        #expect(data.sevenDayCost == 3.0)
        #expect(data.sevenDayTokens == 300)
        // Period (30d) total folds the whole axis from the actual entries:
        // today (1.0/100) + day3 (2.0/200) + day20 (7.0/500) = 10.0/800.
        #expect(data.thirtyDayCost == 10.0)
        #expect(data.thirtyDayTokens == 800)
    }

    // MARK: - Empty

    @Test
    func emptyWhenNoModelEntries() {
        let now = Date()
        let a = analytics(byDayModel: [])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.isEmpty)
        #expect(data.byModel.isEmpty)
        #expect(data.dailyCosts.count == 30)
        #expect(data.dailyCosts.allSatisfy { $0.costUSD == 0 && $0.tokens == 0 })
    }

    @Test
    func ninetyDayPeriodSpansNinetyDays() {
        let now = Date()
        let a = analytics(byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 5, output: 5, cost: 1.0)])
        let data = DashboardData.build(from: a, period: .ninetyDays, now: now)
        #expect(data.dailyCosts.count == 90)
        #expect(data.dailyCosts.first?.date == day(89, from: now))
        #expect(data.dailyCosts.last?.date == day(0, from: now))
    }

    // MARK: - Per-card totals (EXB-3.6 AC14)

    @Test
    func periodTotalsSumTheWindow() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cacheRead: 10, cacheWrite: 5, cost: 1.0),
            model("claude-opus-4", day(3, from: now), input: 120, output: 80, cacheRead: 20, cacheWrite: 0, cost: 2.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        // totalCost = 1.0 + 2.0
        #expect(data.totalCost == 3.0)
        // totalTokens = (60+40+10+5) + (120+80+20+0) = 115 + 220 = 335
        #expect(data.totalTokens == 335)
        // Date range spans the full window: first = day −29, last = today.
        #expect(data.rangeStart == day(29, from: now))
        #expect(data.rangeEnd == day(0, from: now))
    }

    @Test
    func totalsAreZeroForEmptyPeriod() {
        let now = Date()
        let data = DashboardData.build(from: analytics(byDayModel: []), period: .sevenDays, now: now)
        #expect(data.totalCost == 0)
        #expect(data.totalTokens == 0)
        #expect(data.totalHeatmapTokens == 0)
        #expect(data.sortedModelNames.isEmpty)
    }

    // MARK: - Consistent model order for colour mapping (EXB-3.6 AC12)

    @Test
    func sortedModelNamesFollowCostDescending() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 50, output: 50, cost: 1.0),
            model("claude-opus-4", day(0, from: now), input: 100, output: 100, cost: 4.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        // The stable order the donut + table + colour scale all share: opus (costlier) first.
        #expect(data.sortedModelNames == ["claude-opus-4", "claude-sonnet-4"])
    }
}
