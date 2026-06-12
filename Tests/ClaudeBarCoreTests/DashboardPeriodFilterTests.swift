import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-3.6 BUG 1 + BUG 2 regression suite.
///
/// BUG 1 ("period filter does nothing"): proves `scanAnalytics` returns *distinct* data for the
/// 7 / 30 / 90-day windows when the underlying entries span different windows — the data layer is
/// correct, so the production symptom was a UI/staleness issue (fixed in the controller), not a
/// filter bug. These tests pin the data-layer contract so a future regression of the filter itself
/// would fail here.
///
/// BUG 2 (multi-second freeze): proves the modification-date floor used by the analytics file
/// pre-filter is computed correctly so files written before the window are skipped without being
/// read.
struct DashboardPeriodFilterTests {
    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exbperiod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeDefaults() -> CostDefaults {
        CostDefaults(UserDefaults(suiteName: "exbperiod.\(UUID().uuidString)")!)
    }

    private static func fallbackPricing(_ defaults: CostDefaults) -> Pricing {
        Pricing(
            transport: StubTransport(error: URLError(.notConnectedToInternet)),
            defaults: defaults,
            networkEnabled: false)
    }

    /// One assistant JSONL line at an explicit ISO-8601 instant.
    private static func line(
        messageId: String,
        requestId: String,
        input: Int,
        output: Int,
        timestamp: String) -> String
    {
        let obj: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": timestamp,
            "cwd": "/work/proj",
            "sessionId": "s-\(messageId)",
            "message": [
                "id": messageId,
                "model": "claude-sonnet-4",
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - BUG 1: distinct data per period (AC1/AC2)

    /// Three entries at day 0, day −15, day −95. A 7-day window sees 1; a 30-day window sees 2; a
    /// 90-day window sees 2 (the −95 entry is always excluded). The counts MUST differ — proving the
    /// window parameter actually filters (not a hardcoded 30-day scan).
    @Test
    func scanReturnsDistinctDataPerPeriod() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let cal = Calendar.current

        let today = Self.iso(now)
        let fifteenAgo = Self.iso(cal.date(byAdding: .day, value: -15, to: now)!)
        let ninetyFiveAgo = Self.iso(cal.date(byAdding: .day, value: -95, to: now)!)

        let lines = [
            Self.line(messageId: "a", requestId: "1", input: 100, output: 100, timestamp: today),
            Self.line(messageId: "b", requestId: "2", input: 200, output: 200, timestamp: fifteenAgo),
            Self.line(messageId: "c", requestId: "3", input: 999, output: 999, timestamp: ninetyFiveAgo),
        ]
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("session.jsonl"))

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)

        let week = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)
        let month = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let quarter = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)

        // 7d: only today's entry.
        #expect(week.byDayModel.count == 1)
        // 30d: today + 15-days-ago.
        #expect(month.byDayModel.count == 2)
        // 90d: today + 15-days-ago (95-days-ago is still out of window).
        #expect(quarter.byDayModel.count == 2)

        // The contract the production bug violated: 90-day data is NOT identical to 7-day data.
        #expect(week.byDayModel.count != quarter.byDayModel.count)

        // Token totals grow with the window (different data, not a stale repeat).
        func totalTokens(_ a: UsageAnalytics) -> Int {
            a.byDayModel.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        }
        #expect(totalTokens(week) == 200)        // 100 + 100
        #expect(totalTokens(month) == 600)       // + 200 + 200
        #expect(totalTokens(quarter) == 600)     // 95-days-ago excluded
        #expect(totalTokens(week) != totalTokens(month))
    }

    // MARK: - BUG 2: modification-date floor (AC4 — fast path)

    /// The file floor is one day before the window's earliest day. A file modified before it cannot
    /// hold an in-window entry, so the analytics scan skips it unread.
    @Test
    func windowFileFloorIsOneDayBeforeEarliestDay() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 15))!
        let todayStart = cal.startOfDay(for: now)

        // 7-day window: earliest day is day −6; floor is day −7.
        let floor7 = CostScanner.windowFileFloor(window: 7, now: now)
        #expect(floor7 == cal.date(byAdding: .day, value: -7, to: todayStart))

        // 30-day window: floor is day −30.
        let floor30 = CostScanner.windowFileFloor(window: 30, now: now)
        #expect(floor30 == cal.date(byAdding: .day, value: -30, to: todayStart))

        // 90-day window: floor is day −90.
        let floor90 = CostScanner.windowFileFloor(window: 90, now: now)
        #expect(floor90 == cal.date(byAdding: .day, value: -90, to: todayStart))
    }

    /// End-to-end: a file whose mtime is well before the window contributes nothing, even though its
    /// (impossible) in-file timestamps are recent — proving the pre-filter drops it. A separate
    /// recent file still contributes. (Verifies the skip path doesn't lose real data.)
    @Test
    func staleFileIsSkippedRecentFileIsScanned() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let cal = Calendar.current

        // Recent file: in-window entry, freshly written → scanned.
        let recentURL = dir.appendingPathComponent("recent.jsonl")
        let recentLine = Self.line(messageId: "r", requestId: "1", input: 50, output: 50, timestamp: Self.iso(now))
        try (recentLine + "\n").data(using: .utf8)!.write(to: recentURL)

        // Stale file: even if it claimed a recent timestamp, an mtime 200 days old places it below the
        // 7-day floor → skipped unread. We back-date its mtime explicitly.
        let staleURL = dir.appendingPathComponent("stale.jsonl")
        let staleLine = Self.line(messageId: "s", requestId: "2", input: 9999, output: 9999, timestamp: Self.iso(now))
        try (staleLine + "\n").data(using: .utf8)!.write(to: staleURL)
        let oldDate = cal.date(byAdding: .day, value: -200, to: now)!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleURL.path)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        // Only the recent file's 100 tokens survive; the stale file (mtime −200d) was never read.
        let total = a.byDayModel.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        #expect(total == 100)
        #expect(a.byProject.first?.totalTokens == 100)
    }
}
