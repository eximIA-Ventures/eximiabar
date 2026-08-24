import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests the EXB-4.5 efficiency-insight fields on `DashboardData` — cache hit rate + estimated
/// savings, the today-vs-average delta, the peak hour from the heatmap, the busiest weekday, and the
/// top model by token volume. All deterministic via injected `now`, so no scan, network, or keychain
/// is touched.
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

    // MARK: - AC6 required: daily delta

    // EXB-5.7 §2: `dailyDeltaPositive` e `dailyDeltaNegative` viviam aqui comparando CUSTO contra
    // uma média de dias inteiros, e usavam `Date()` real. Com o delta prorrateado pela fração do dia,
    // ambos passariam a depender da hora em que a suíte roda. A cobertura determinística — inclusive
    // a fixture que INVERTE o sinal do badge — está em `DashboardDeltaTests`.

    @Test
    func dailyDeltaNilWhenNoUsageToday() {
        // Meio-dia fixo: fora da zona morta da primeira hora, para que a ausência de delta seja
        // mesmo "sem uso hoje" e não "cedo demais" (EXB-5.7 §2).
        let now = Calendar.current.date(
            byAdding: .hour, value: 12,
            to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_787_000_000)))!
        let a = analytics(byDayModel: [
            model("claude-sonnet-4", day(2, from: now), input: 50, output: 50, cost: 5.0),
        ])
        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)
        #expect(data.dailyDelta == nil)
        #expect(data.dailyDeltaState == .semUsoHoje)
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

}
