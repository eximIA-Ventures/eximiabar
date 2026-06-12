import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-3.2 — analytics dashboard builder (`DashboardData.build(from: UsageAnalytics, ...)`) and the
/// CSV export. Covers (AC13): run-rate projection, the stacked-token day axis, project/heatmap/session
/// pass-through, and the CSV format. All deterministic via injected `now`.
struct DashboardAnalyticsTests {
    private func day(_ offset: Int, from now: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
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

    // MARK: - Run-rate projection (AC2)

    @Test
    func monthProjectionScalesMonthToDateToFullMonth() {
        // Mid-month: 2025-06-15 12:00 → 15 days elapsed, 30-day month. $150 MTD → $300 projection.
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 15; comps.hour = 12
        let now = Calendar.current.date(from: comps)!

        let projection = DashboardData.monthProjection(monthToDateCost: 150.0, now: now)
        // (150 / 15) * 30 = 300.
        #expect(abs(projection - 300.0) < 0.0001)
    }

    @Test
    func monthProjectionOnFirstDayProjectsFullMonth() {
        // First day of a 31-day month: 1 day elapsed → projection = MTD × 31.
        var comps = DateComponents()
        comps.year = 2025; comps.month = 1; comps.day = 1; comps.hour = 9
        let now = Calendar.current.date(from: comps)!

        let projection = DashboardData.monthProjection(monthToDateCost: 10.0, now: now)
        #expect(abs(projection - 310.0) < 0.0001)
    }

    @Test
    func monthProjectionWiredThroughBuild() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 10; comps.hour = 12 // 10 days elapsed, 30-day month
        let now = Calendar.current.date(from: comps)!

        let analytics = UsageAnalytics(
            byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cost: 5.0)],
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 100.0)

        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)
        // (100 / 10) * 30 = 300.
        #expect(abs(data.monthProjection - 300.0) < 0.0001)
    }

    // MARK: - Average daily (AC2)

    @Test
    func averageDailyIsPeriodCostOverSpan() {
        let now = Date()
        let analytics = UsageAnalytics(
            byDayModel: [
                model("claude-sonnet-4", day(0, from: now), input: 10, output: 10, cost: 3.0),
                model("claude-sonnet-4", day(1, from: now), input: 10, output: 10, cost: 4.0),
            ],
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .sevenDays, now: now)
        // total 7.0 over a 7-day span → 1.0 average.
        #expect(abs(data.averageDailyCost - 1.0) < 0.0001)
    }

    // MARK: - Stacked tokens day axis (AC4)

    @Test
    func dayAxisCarriesCacheTokenSplit() {
        let now = Date()
        let analytics = UsageAnalytics(
            byDayModel: [
                model("claude-sonnet-4", day(0, from: now),
                      input: 100, output: 50, cacheRead: 4_000, cacheWrite: 200, cost: 1.0),
                // Two rows on the same day fold their cache split together.
                model("claude-opus-4", day(0, from: now),
                      input: 50, output: 25, cacheRead: 1_000, cacheWrite: 100, cost: 2.0),
            ],
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .sevenDays, now: now)
        let today = data.dailyCosts.last
        #expect(today?.inputTokens == 150)
        #expect(today?.outputTokens == 75)
        #expect(today?.cacheReadTokens == 5_000)
        #expect(today?.cacheWriteTokens == 300)
        // `tokens` (the legacy combined input+output) excludes cache, matching the popover semantics.
        #expect(today?.tokens == 225)
    }

    // MARK: - Pass-through (AC6/AC7/AC8)

    @Test
    func projectHeatmapAndSessionsPassThrough() {
        let now = Date()
        var heatmap = UsageAnalytics.emptyHeatmap()
        heatmap[3][14] = HeatmapBucket(weekday: 3, hour: 14, tokens: 999)
        let project = ProjectUsageEntry(project: "alpha", costUSD: 5.0, totalTokens: 1_000)
        let session = SessionUsageEntry(
            sessionId: "s1", date: day(0, from: now), project: "alpha",
            dominantModel: "claude-opus-4", totalTokens: 1_000, costUSD: 5.0)

        let analytics = UsageAnalytics(
            byDayModel: [model("claude-opus-4", day(0, from: now), input: 10, output: 10, cost: 5.0)],
            byProject: [project],
            heatmap: heatmap,
            topSessions: [session],
            monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)
        #expect(data.byProject == [project])
        #expect(data.heatmap[3][14].tokens == 999)
        #expect(data.topSessions == [session])
    }

    // MARK: - CSV export (AC9)

    @Test
    func csvExportHeaderAndRows() {
        let now = Date()
        let analytics = UsageAnalytics(
            byDayModel: [
                model("claude-sonnet-4", day(0, from: now),
                      input: 100, output: 50, cacheRead: 4_000, cacheWrite: 200, cost: 1.2345),
            ],
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .sevenDays, now: now)
        let csv = data.csvExport()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Header.
        #expect(lines.first == "date,cost_usd,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens")
        // One row per day in the 7-day axis.
        #expect(lines.count == 8) // header + 7 days
        // Today's row carries the values; cost to 4 decimals.
        let todayRow = lines.last!
        #expect(todayRow.contains("1.2345"))
        #expect(todayRow.hasSuffix(",1.2345,100,50,4000,200"))
        // A zero-usage day is still present with zeros.
        let zeroRows = lines.dropFirst().filter { $0.hasSuffix(",0.0000,0,0,0,0") }
        #expect(zeroRows.count == 6)
    }

    @Test
    func csvDateColumnIsISO8601FullDate() {
        let now = Date()
        let analytics = UsageAnalytics(
            byDayModel: [model("claude-sonnet-4", day(0, from: now), input: 1, output: 1, cost: 0.5)],
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 0)
        let data = DashboardData.build(from: analytics, period: .sevenDays, now: now)
        let csv = data.csvExport()
        let lastRow = csv.split(separator: "\n").map(String.init).last!
        // First column matches YYYY-MM-DD.
        let dateField = String(lastRow.split(separator: ",").first!)
        #expect(dateField.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
    }
}
