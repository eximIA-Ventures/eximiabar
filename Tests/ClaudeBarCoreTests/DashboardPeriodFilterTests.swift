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
/// BUG 2 (multi-second freeze) was originally fixed by a modification-date floor that skipped files
/// written before the window, and this suite pinned that floor's arithmetic. EXB-5.7 removed the
/// floor — with the persisted archive it would have made old logs permanently un-ingestable — so the
/// freeze is now prevented by not *re*-reading unchanged files instead. That contract lives in
/// `CostScannerIncrementalAnalyticsTests.wideningThePeriodAfterANarrowScanReadsNoBytes`; what remains
/// here of BUG 2 is the end-to-end check that entry timestamps, not file mtimes, decide what counts.
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

    // MARK: - BUG 2: what decides whether an entry counts

    /// End-to-end: what a file's *entries* say is what counts, regardless of the file's mtime.
    ///
    /// **This assertion was inverted by EXB-5.7 and the inversion is deliberate.** It used to prove
    /// that a file whose mtime fell below the window floor was skipped unread — the pre-filter that
    /// made BUG 2's multi-second freeze survivable. The scan no longer has that floor: with the
    /// persisted archive, a log older than the floor could never be ingested *at all*, and on a
    /// fresh install that is exactly the history Claude Code's retention is busy deleting. Skipping
    /// is now decided by `(size, mtime)` against the cache, so an already-ingested old file still
    /// costs a `stat` and nothing more — the freeze is fixed by not re-reading, not by not reading.
    ///
    /// The perf contract BUG 2 cared about is pinned instead by
    /// `CostScannerIncrementalAnalyticsTests.wideningThePeriodAfterANarrowScanReadsNoBytes`, which
    /// proves an unchanged file is never opened.
    ///
    /// Note the fixture is a deliberate impossibility — the original called it that too. A file with
    /// a 200-day-old mtime cannot contain entries dated today; mtime is always at least the newest
    /// entry. Given the contradiction, trusting the entry timestamps is the defensible reading.
    @Test
    func entryTimestampsDecideRegardlessOfFileModificationDate() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let cal = Calendar.current

        // Recent file: in-window entry, freshly written → scanned.
        let recentURL = dir.appendingPathComponent("recent.jsonl")
        let recentLine = Self.line(messageId: "r", requestId: "1", input: 50, output: 50, timestamp: Self.iso(now))
        try (recentLine + "\n").data(using: .utf8)!.write(to: recentURL)

        // Back-dated file: mtime 200 days old, but its entries claim today. Under the archive the
        // entries decide, so its 19 998 tokens count.
        let staleURL = dir.appendingPathComponent("stale.jsonl")
        let staleLine = Self.line(messageId: "s", requestId: "2", input: 9999, output: 9999, timestamp: Self.iso(now))
        try (staleLine + "\n").data(using: .utf8)!.write(to: staleURL)
        let oldDate = cal.date(byAdding: .day, value: -200, to: now)!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleURL.path)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let a = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        let total = a.byDayModel.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        #expect(total == 20_098)
        #expect(a.byProject.first?.totalTokens == 20_098)

        // The window still filters on the *entry* timestamp: an entry genuinely dated 200 days ago
        // is excluded from a 7-day window even though its file was written moments ago.
        let backdatedEntry = dir.appendingPathComponent("backdated-entry.jsonl")
        let oldLine = Self.line(
            messageId: "o", requestId: "3", input: 7, output: 7, timestamp: Self.iso(oldDate))
        try (oldLine + "\n").data(using: .utf8)!.write(to: backdatedEntry)
        let b = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)
        #expect(b.byDayModel.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } == 20_098)
    }
}
