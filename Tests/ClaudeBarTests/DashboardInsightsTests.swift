import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests the EXB-4.5 efficiency-insight fields on `DashboardData` — cache hit rate + estimated
/// savings, the today-vs-average delta, the peak hour from the heatmap, the busiest weekday, and the
/// top model by token volume. All deterministic via injected `now` and an explicit `CachePricing`, so
/// no scan, network, or keychain is touched.
struct DashboardInsightsTests {
    // MARK: - Fixtures

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

    private func analytics(
        byDayModel: [ModelCostEntry],
        heatmap: [[HeatmapBucket]] = UsageAnalytics.emptyHeatmap(),
        monthToDate: Double = 0) -> UsageAnalytics
    {
        UsageAnalytics(
            byDayModel: byDayModel,
            byProject: [],
            heatmap: heatmap,
            topSessions: [],
            monthToDateCost: monthToDate)
    }

    /// A 7×24 heatmap with a single non-zero bucket at `(weekday, hour)`.
    private func heatmap(weekday: Int, hour: Int, tokens: Int) -> [[HeatmapBucket]] {
        (0..<7).map { wd in
            (0..<24).map { hr in
                HeatmapBucket(weekday: wd, hour: hr, tokens: (wd == weekday && hr == hour) ? tokens : 0)
            }
        }
    }

    // MARK: - AC6 required: cache hit rate

    @Test
    func cacheHitRateZeroWhenNoCache() {
        let now = Date()
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 100, output: 50, cacheRead: 0, cost: 1.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        #expect(data.cacheHitRate == 0)
        #expect(data.estimatedCacheSavings == 0)
    }

    @Test
    func cacheHitRateCalculation() {
        let now = Date()
        // input total = 100, cacheRead total = 300 → 300 / (100 + 300) = 0.75.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 40, output: 10, cacheRead: 100, cost: 1.0),
            model("claude-sonnet-4", day(1, from: now), input: 60, output: 10, cacheRead: 200, cost: 1.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        #expect(abs(data.cacheHitRate - 0.75) < 1e-9)
    }

    @Test
    func estimatedCacheSavingsUsesDominantModelPricing() {
        let now = Date()
        // 1000 cache-read tokens; output $0.000015/tok, cacheRead $0.0000003/tok (0.1×input where
        // input = $0.000003). savings = 1000 × (0.000015 − 0.0000003) = 1000 × 0.0000147 = 0.0147.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cacheRead: 1000, cost: 1.0),
        ])
        let pricing = CachePricing.claude(inputPerToken: 0.000003, outputPerToken: 0.000015)
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now, cachePricing: pricing)
        #expect(abs(data.estimatedCacheSavings - 0.0147) < 1e-9)
    }

    // MARK: - AC6 required: daily delta

    @Test
    func dailyDeltaPositive() {
        let now = Date()
        // 30-day window. today cost = 4.0; other day = 2.0 → periodCost 6.0, avg = 6/30 = 0.2.
        // delta = (4.0 − 0.2) / 0.2 = 19.0 (i.e. +1900%).
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cost: 4.0),
            model("claude-sonnet-4", day(3, from: now), input: 10, output: 10, cost: 2.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        let delta = try! #require(data.dailyDelta)
        #expect(delta > 0)
        #expect(abs(delta - 19.0) < 1e-9)
    }

    @Test
    func dailyDeltaNegative() {
        let now = Date()
        // today cost = 1.0; another day = 9.0 → periodCost 10.0, avg = 10/30 ≈ 0.3333.
        // delta = (1.0 − 0.3333) / 0.3333 > 0 would be positive — to force a *negative* delta we make
        // today below the average: today 0.1, other days large.
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(0, from: now), input: 5, output: 5, cost: 0.1),
            model("claude-sonnet-4", day(1, from: now), input: 50, output: 50, cost: 5.0),
            model("claude-sonnet-4", day(2, from: now), input: 50, output: 50, cost: 5.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        let delta = try! #require(data.dailyDelta)
        #expect(delta < 0)
    }

    @Test
    func dailyDeltaNilWhenNoUsageToday() {
        let now = Date()
        // Only past days have usage; today is empty → delta is nil ("Sem uso hoje").
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(2, from: now), input: 50, output: 50, cost: 5.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        #expect(data.dailyDelta == nil)
    }

    // MARK: - AC6 required: peak hour

    @Test
    func peakHourFromHeatmap() {
        let now = Date()
        let hm = heatmap(weekday: 3, hour: 14, tokens: 9_999)
        let a = analytics(
            byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cost: 1.0)],
            heatmap: hm)
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        #expect(data.peakHour == 14)
    }

    @Test
    func peakHourZeroForEmptyHeatmap() {
        let now = Date()
        let a = analytics(byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cost: 1.0)])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        #expect(data.peakHour == 0)
    }

    // MARK: - Busiest day + top model (AC3)

    @Test
    func busiestDayIsHighestCostWeekday() {
        let now = Date()
        let target = day(0, from: now)
        let targetWeekday = Calendar.current.component(.weekday, from: target) - 1
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", target, input: 10, output: 10, cost: 8.0),          // biggest
            model("claude-sonnet-4", day(2, from: now), input: 10, output: 10, cost: 1.0),
        ])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        let busiest = try! #require(data.busiestDay)
        #expect(busiest.dayOfWeek == targetWeekday)
        #expect(abs(busiest.cost - 8.0) < 1e-9)
    }

    @Test
    func busiestDayNilWhenNoSpend() {
        let now = Date()
        let a = analytics(byDayModel: [])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        #expect(data.busiestDay == nil)
    }

    @Test
    func topModelByTokensCountsAllTokenTypes() {
        let now = Date()
        // opus volume = 10+10 = 20; sonnet volume = 5+5+1000(cacheRead) = 1010 → sonnet wins.
        let a = analytics(byDayModel: [
            model("claude-opus-4", day(0, from: now), input: 10, output: 10, cost: 5.0),
            model("claude-sonnet-4", day(0, from: now), input: 5, output: 5, cacheRead: 1000, cost: 1.0),
        ])
        let data = DashboardData.build(from: a, period: .sevenDays, now: now)
        let top = try! #require(data.topModelByTokens)
        #expect(top.name == "claude-sonnet-4")
        #expect(top.tokens == 1010)
    }

    // MARK: - CachePricing helper

    @Test
    func cachePricingDerivesCacheReadFromInputRatio() {
        let p = CachePricing.claude(inputPerToken: 0.00002, outputPerToken: 0.00010)
        #expect(p.outputPerToken == 0.00010)
        #expect(abs(p.cacheReadPerToken - 0.00002 * 0.1) < 1e-12)
    }

    @Test
    func cachePricingDefaultIsZeroed() {
        let p = CachePricing()
        #expect(p.outputPerToken == 0)
        #expect(p.cacheReadPerToken == 0)
    }
}
