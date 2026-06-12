import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-3.2 — analytics scan (`scanAnalytics`). Builds temp JSONL fixtures with known `cwd`,
/// `sessionId`, cache tokens and timestamps, then asserts project derivation, the cache-token split,
/// heatmap weekday/hour bucketing, and top-session roll-up. Network-disabled `Pricing` forces the
/// fallback table so cost is deterministic.
struct CostScannerAnalyticsTests {
    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exbanalytics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeDefaults() -> CostDefaults {
        CostDefaults(UserDefaults(suiteName: "exbanalytics.\(UUID().uuidString)")!)
    }

    /// `Pricing` pinned to the hardcoded fallback table (no network). `networkEnabled: false` means
    /// the stub transport is never invoked, so any canned response works.
    private static func fallbackPricing(_ defaults: CostDefaults) -> Pricing {
        Pricing(
            transport: StubTransport(error: URLError(.notConnectedToInternet)),
            defaults: defaults,
            networkEnabled: false)
    }

    /// Build one assistant JSONL line with `cwd`, `sessionId`, cache tokens and an explicit timestamp.
    private static func line(
        messageId: String,
        requestId: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cwd: String?,
        sessionId: String?,
        timestamp: String) -> String
    {
        var obj: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": timestamp,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheWrite,
                ],
            ],
        ]
        if let cwd { obj["cwd"] = cwd }
        if let sessionId { obj["sessionId"] = sessionId }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// ISO8601 timestamp for a specific local wall-clock instant (so weekday/hour are deterministic).
    private static func localTimestamp(year: Int, month: Int, day: Int, hour: Int) -> (String, Date) {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour; comps.minute = 0
        let date = Calendar.current.date(from: comps)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = .current
        return (fmt.string(from: date), date)
    }

    private static func write(_ lines: [String], to dir: URL, name: String) throws {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
    }

    // MARK: - Project derivation (AC6)

    @Test
    func projectNameFromCWDUsesLastPathComponent() {
        #expect(CostScanner.projectName(fromCWD: "/Users/hugo/Dev/eximia/eximiabar") == "eximiabar")
        #expect(CostScanner.projectName(fromCWD: "/tmp/MyProject/") == "MyProject")
        #expect(CostScanner.projectName(fromCWD: nil) == "Unknown")
        #expect(CostScanner.projectName(fromCWD: "   ") == "Unknown")
    }

    @Test
    func scanGroupsByProjectFromCWD() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let (ts, _) = Self.localTimestamp(
            year: Calendar.current.component(.year, from: now),
            month: Calendar.current.component(.month, from: now),
            day: Calendar.current.component(.day, from: now),
            hour: 10)

        let alpha = Self.line(
            messageId: "a", requestId: "1", model: "claude-sonnet-4",
            input: 100, output: 100, cwd: "/work/alpha", sessionId: "s1", timestamp: ts)
        let beta = Self.line(
            messageId: "b", requestId: "2", model: "claude-sonnet-4",
            input: 50, output: 50, cwd: "/work/beta", sessionId: "s2", timestamp: ts)
        try Self.write([alpha, beta], to: dir, name: "session.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        let names = Set(a.byProject.map(\.project))
        #expect(names == ["alpha", "beta"])
        // alpha (200 tokens) sorts before beta (100) — higher cost.
        #expect(a.byProject.first?.project == "alpha")
        #expect(a.byProject.first?.totalTokens == 200)
    }

    // MARK: - Cache-token split (AC4)

    @Test
    func scanCapturesCacheTokenSplit() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let (ts, _) = Self.localTimestamp(
            year: Calendar.current.component(.year, from: now),
            month: Calendar.current.component(.month, from: now),
            day: Calendar.current.component(.day, from: now),
            hour: 9)

        let entry = Self.line(
            messageId: "m", requestId: "r", model: "claude-sonnet-4",
            input: 1_000, output: 500, cacheRead: 4_000, cacheWrite: 200,
            cwd: "/work/proj", sessionId: "s1", timestamp: ts)
        try Self.write([entry], to: dir, name: "session.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        #expect(a.byDayModel.count == 1)
        let row = a.byDayModel[0]
        #expect(row.inputTokens == 1_000)
        #expect(row.outputTokens == 500)
        #expect(row.cacheReadTokens == 4_000)
        #expect(row.cacheWriteTokens == 200)
        // Project tokens include cache tokens (1000 + 500 + 4000 + 200 = 5700).
        #expect(a.byProject.first?.totalTokens == 5_700)
    }

    // MARK: - Heatmap bucketing (AC7)

    @Test
    func scanBucketsHeatmapByWeekdayAndHour() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // A fixed recent Wednesday at 14:00 local. Use a date within the window relative to `now`.
        // 2025-06-11 is a Wednesday → weekday component 4 → heatmap index 3.
        let (ts, date) = Self.localTimestamp(year: 2025, month: 6, day: 11, hour: 14)
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let hour = Calendar.current.component(.hour, from: date)
        // Scan as-of the same day so the entry is in-window.
        let now = Calendar.current.date(byAdding: .hour, value: 6, to: date)!

        let entry = Self.line(
            messageId: "m", requestId: "r", model: "claude-sonnet-4",
            input: 300, output: 200, cacheRead: 0, cacheWrite: 0,
            cwd: "/work/proj", sessionId: "s1", timestamp: ts)
        try Self.write([entry], to: dir, name: "session.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(a.heatmap.count == 7)
        #expect(a.heatmap[0].count == 24)
        // The bucket for the entry's weekday/hour carries all 500 tokens; everything else is zero.
        #expect(a.heatmap[weekday][hour].tokens == 500)
        let totalElsewhere = a.heatmap.flatMap { $0 }
            .filter { !($0.weekday == weekday && $0.hour == hour) }
            .reduce(0) { $0 + $1.tokens }
        #expect(totalElsewhere == 0)
    }

    // MARK: - Top sessions (AC8)

    @Test
    func scanRollsUpTopSessionsByCost() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let y = Calendar.current.component(.year, from: now)
        let m = Calendar.current.component(.month, from: now)
        let d = Calendar.current.component(.day, from: now)
        let (ts, _) = Self.localTimestamp(year: y, month: m, day: d, hour: 11)

        // Session s1: two opus entries (expensive). Session s2: one sonnet entry (cheaper).
        let s1a = Self.line(
            messageId: "1a", requestId: "ra", model: "claude-opus-4",
            input: 10_000, output: 5_000, cwd: "/work/big", sessionId: "s1", timestamp: ts)
        let s1b = Self.line(
            messageId: "1b", requestId: "rb", model: "claude-sonnet-4",
            input: 1_000, output: 500, cwd: "/work/big", sessionId: "s1", timestamp: ts)
        let s2 = Self.line(
            messageId: "2a", requestId: "rc", model: "claude-sonnet-4",
            input: 100, output: 50, cwd: "/work/small", sessionId: "s2", timestamp: ts)
        try Self.write([s1a, s1b, s2], to: dir, name: "session.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        #expect(a.topSessions.count == 2)
        let top = a.topSessions[0]
        #expect(top.sessionId == "s1")
        #expect(top.project == "big")
        // Dominant model is the one with the most cost in the session — opus here.
        #expect(top.dominantModel == "claude-opus-4")
        // s1 totals: input 11000 + output 5500 = 16500 tokens.
        #expect(top.totalTokens == 16_500)
        #expect(a.topSessions[1].sessionId == "s2")
    }

    // MARK: - Window filter

    @Test
    func scanExcludesEntriesOutsideWindow() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()

        let cal = Calendar.current
        // In-window (today) and out-of-window (40 days ago) entries.
        let todayTs: String = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: now)
        }()
        let oldTs: String = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: cal.date(byAdding: .day, value: -40, to: now)!)
        }()

        let fresh = Self.line(
            messageId: "f", requestId: "1", model: "claude-sonnet-4",
            input: 100, output: 100, cwd: "/work/proj", sessionId: "s1", timestamp: todayTs)
        let stale = Self.line(
            messageId: "o", requestId: "2", model: "claude-sonnet-4",
            input: 999, output: 999, cwd: "/work/proj", sessionId: "s2", timestamp: oldTs)
        try Self.write([fresh, stale], to: dir, name: "session.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // Only the fresh entry (200 tokens) survives the 30-day window.
        #expect(a.byProject.count == 1)
        #expect(a.byProject.first?.totalTokens == 200)
    }
}
