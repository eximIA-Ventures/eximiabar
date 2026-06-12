import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-3.7 — dashboard polish. Covers the pure, testable seams the visual polish rests on:
/// the K/M/B token formatter (with the new billions threshold), the per-`(day, model)` aggregation
/// behind the "Models per day" chart, the tokens-first KPI derivations (avg-daily + projected
/// tokens), and the X-axis tick stride per period. The interactive chart hover/highlight is visual
/// and validated by Hugo; these tests pin the data + formatting contracts those views consume.
struct DashboardPolishTests {
    private func day(_ offset: Int, from now: Date) -> Date {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: -offset, to: todayStart)!
    }

    private func model(
        _ name: String,
        _ date: Date,
        input: Int = 0,
        output: Int = 0,
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

    // MARK: - K/M/B formatting incl. the new billions threshold (AC7/AC20/AC21)

    @Test
    func tokenCountFormatsKMBWithBillionsThreshold() {
        // Below 1K → raw.
        #expect(DashboardFormat.tokenCount(0) == "0")
        #expect(DashboardFormat.tokenCount(999) == "999")
        // K / M.
        #expect(DashboardFormat.tokenCount(500_000) == "500.0K")
        #expect(DashboardFormat.tokenCount(1_000_000) == "1.0M")
        // The story's headline case: 4_888_600_000 must read "4.9B", never "4888.6M" or "4.9E9".
        #expect(DashboardFormat.tokenCount(4_888_600_000) == "4.9B")
        #expect(DashboardFormat.tokenCount(1_000_000_000) == "1.0B")
    }

    @Test
    func tokenCountBoundaryRollovers() {
        // Exact thresholds roll into the next unit, not the previous one.
        #expect(DashboardFormat.tokenCount(1_000) == "1.0K")
        #expect(DashboardFormat.tokenCount(999_999).hasSuffix("K"))
        #expect(DashboardFormat.tokenCount(999_999_999).hasSuffix("M"))
        #expect(DashboardFormat.tokenCount(1_000_000_000).hasSuffix("B"))
    }

    @Test
    func axisTokensRoutesThroughTokenCount() {
        // The axis label must share the same K/M/B ramp — no scientific notation on any axis.
        #expect(DashboardFormat.axisTokens(4_888_600_000) == "4.9B")
        #expect(DashboardFormat.axisTokens(2_500_000) == "2.5M")
    }

    @Test
    func popoverTokenCountGainsBillions() {
        // The shared popover formatter (used by the model/session tables) also gets the B threshold,
        // while keeping its historical K/M output for existing string-comparing tests.
        #expect(PopoverFormatter.tokenCount(27_000) == "27K")
        #expect(PopoverFormatter.tokenCount(5_400_000) == "5.4M")
        #expect(PopoverFormatter.tokenCount(4_888_600_000) == "4.9B")
    }

    // MARK: - Models-per-day aggregation (AC4/AC14)

    @Test
    func byDayByModelAggregatesVolumePerDayAndModel() {
        let now = Date()
        // 2 models × 3 distinct days → 6 (day, model) entries.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 10, output: 5, cacheRead: 3, cacheWrite: 2, cost: 1.0),
            model("claude-opus-4", day(0, from: now), input: 100, output: 50, cost: 2.0),
            model("claude-sonnet-4", day(1, from: now), input: 20, output: 10, cost: 1.0),
            model("claude-opus-4", day(1, from: now), input: 200, output: 100, cost: 2.0),
            model("claude-sonnet-4", day(2, from: now), input: 30, output: 15, cost: 1.0),
            model("claude-opus-4", day(2, from: now), input: 300, output: 150, cost: 2.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.byDayByModel.count == 6)
        // Volume = input + output + cacheRead + cacheWrite. Sonnet on day 0 = 10+5+3+2 = 20.
        let sonnetDay0 = data.byDayByModel.first { $0.date == day(0, from: now) && $0.modelName == "claude-sonnet-4" }
        #expect(sonnetDay0?.tokens == 20)
        // Ascending by date.
        let dates = data.byDayByModel.map(\.date)
        #expect(dates == dates.sorted())
    }

    @Test
    func byDayByModelFoldsRepeatedDayModelRows() {
        let now = Date()
        // Same (day, model) appearing twice (e.g. two sessions) folds into one summed entry.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 10, output: 0, cost: 0.5),
            model("claude-sonnet-4", day(0, from: now), input: 40, output: 0, cost: 0.5),
        ])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        #expect(data.byDayByModel.count == 1)
        #expect(data.byDayByModel.first?.tokens == 50)
    }

    @Test
    func byDayByModelIsEmptyForEmptyScan() {
        let now = Date()
        let data = DashboardData.build(from: analytics(byDayModel: []), period: .sevenDays, now: now)
        #expect(data.byDayByModel.isEmpty)
    }

    // MARK: - Tokens-first KPI derivations (AC6/AC16/AC19)

    @Test
    func periodTokensIsTheKPIPrimaryNumber() {
        let now = Date()
        // 7-day period; activity today only.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 60, output: 40, cost: 1.0),
        ])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        // The KPI cards lead with tokens; today's token count is the headline (input + output).
        #expect(data.todayTokens == 100)
        #expect(data.sevenDayTokens == 100)
        // Cost is the secondary line — present but not the headline.
        #expect(data.todayCost == 1.0)
    }

    @Test
    func projectedTokensScalesCostProjectionByRatio() {
        // 10_000 tokens cost $2 → ratio 5_000 tokens/$. A $4 projection ⇒ 20_000 projected tokens.
        let projected = DashboardData.projectedTokens(periodTokens: 10_000, periodCost: 2.0, projectedCost: 4.0)
        #expect(projected == 20_000)
    }

    @Test
    func projectedTokensIsZeroWithoutCost() {
        // No cost ⇒ no ratio ⇒ no projection (guards a divide-by-zero).
        #expect(DashboardData.projectedTokens(periodTokens: 1_000, periodCost: 0, projectedCost: 5.0) == 0)
    }

    // MARK: - X-axis tick stride per period (AC8)

    @Test
    func axisStridePerPeriodKeepsLabelsReadable() {
        // 7d → daily ticks; 30d → every 4 days; 90d → every 14 days.
        #expect(DashboardFormat.axisStride(for: .sevenDays) == 1)
        #expect(DashboardFormat.axisStride(for: .thirtyDays) == 4)
        #expect(DashboardFormat.axisStride(for: .ninetyDays) == 14)
        // 30d / stride-4 ⇒ ≤ 8 labels (never crowded enough to truncate).
        #expect(30 / DashboardFormat.axisStride(for: .thirtyDays) <= 10)
        #expect(90 / DashboardFormat.axisStride(for: .ninetyDays) <= 10)
    }
}
