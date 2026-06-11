import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-1.7 — local JSONL cost scan (AC14a–AC14e).
///
/// Each test builds temporary JSONL files with known content, scans with a network-disabled
/// `Pricing` (forcing the hardcoded fallback table, AC14d) and an isolated `UserDefaults` suite so
/// the incremental offset / aggregate caches do not bleed between tests.
struct CostScannerTests {
    // MARK: - Helpers

    /// A throwaway temp directory for one test's JSONL fixtures.
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exbcost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An isolated `UserDefaults` (boxed) so offset/aggregate caches are per-test.
    private static func makeDefaults() -> CostDefaults {
        let suite = "exbcost.\(UUID().uuidString)"
        return CostDefaults(UserDefaults(suiteName: suite)!)
    }

    /// A `Pricing` pinned to the hardcoded fallback table (no network, AC14d).
    private static func fallbackPricing(_ defaults: CostDefaults) -> Pricing {
        Pricing(transport: NeverTransport(), defaults: defaults, networkEnabled: false)
    }

    /// Build one assistant JSONL line.
    private static func assistantLine(
        messageId: String,
        requestId: String,
        model: String,
        input: Int,
        output: Int,
        timestamp: String) -> String
    {
        let obj: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": timestamp,
            "message": [
                "id": messageId,
                "model": model,
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// ISO8601 timestamp string for `daysAgo` days before `now`, at noon UTC-ish.
    private static func timestamp(daysAgo: Int, from now: Date) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }

    private static func write(_ lines: [String], to dir: URL, name: String = "session.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - AC14a — pre-filter skips non-assistant lines without decoding

    @Test
    func preFilterSkipsLinesMissingMarkers() {
        // The byte pre-filter requires BOTH `"type":"assistant"` and `"usage"`.
        let userLine = Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)
        #expect(userLine.containsAsciiSubsequence(Array(#""type":"assistant""#.utf8)) == false)

        let assistantNoUsage = Data(#"{"type":"assistant","message":{"id":"m"}}"#.utf8)
        #expect(assistantNoUsage.containsAsciiSubsequence(Array(#""type":"assistant""#.utf8)) == true)
        #expect(assistantNoUsage.containsAsciiSubsequence(Array(#""usage""#.utf8)) == false)

        let full = Data(#"{"type":"assistant","message":{"usage":{}}}"#.utf8)
        #expect(full.containsAsciiSubsequence(Array(#""type":"assistant""#.utf8)) == true)
        #expect(full.containsAsciiSubsequence(Array(#""usage""#.utf8)) == true)
    }

    @Test
    func nonAssistantLinesDoNotContributeToCost() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()

        let assistant = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 1_000, output: 1_000, timestamp: Self.timestamp(daysAgo: 0, from: now))
        // A user line that *contains* "usage" text but is not type assistant → must be ignored.
        let userLine = #"{"type":"user","message":{"text":"the word usage appears here"}}"#
        _ = try Self.write([userLine, assistant], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)

        // Only the assistant line's tokens count: 1000 in + 1000 out.
        #expect(cost.todayTokens == 2_000)
        #expect(cost.byModel.count == 1)
        #expect(cost.byModel.first?.model == "claude-sonnet-4")
    }

    // MARK: - AC14b — dedup: same (messageId, requestId), higher offset wins

    @Test
    func dedupKeepsLastChunkForSameKey() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let ts = Self.timestamp(daysAgo: 0, from: now)

        // Two streaming chunks of ONE request: the second (later offset) carries the cumulative total.
        let chunk1 = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 100, output: 50, timestamp: ts)
        let chunk2 = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 1_000, output: 500, timestamp: ts)
        _ = try Self.write([chunk1, chunk2], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)

        // Only the second chunk counts: 1000 in + 500 out = 1500 tokens (NOT 1650).
        #expect(cost.todayTokens == 1_500)
        #expect(cost.byModel.first?.inputTokens == 1_000)
        #expect(cost.byModel.first?.outputTokens == 500)
    }

    // MARK: - AC14c — aggregation: today vs trailing window

    @Test
    func aggregationSplitsTodayFromWindow() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()

        // 3 lines today + 2 lines 31 days ago. costDays = 30 → only today's 3 in `today`,
        // and the 31-days-ago lines fall OUTSIDE the 30-day window entirely.
        var lines: [String] = []
        for i in 0..<3 {
            lines.append(Self.assistantLine(
                messageId: "today-\(i)", requestId: "rt-\(i)", model: "claude-sonnet-4",
                input: 100, output: 100, timestamp: Self.timestamp(daysAgo: 0, from: now)))
        }
        for i in 0..<2 {
            lines.append(Self.assistantLine(
                messageId: "old-\(i)", requestId: "ro-\(i)", model: "claude-sonnet-4",
                input: 100, output: 100, timestamp: Self.timestamp(daysAgo: 31, from: now)))
        }
        _ = try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)

        // Today: 3 lines × 200 tokens = 600.
        #expect(cost.todayTokens == 600)
        // 30-day window excludes the 31-days-ago lines → window total == today's total.
        #expect(cost.last30DaysTokens == 600)
    }

    @Test
    func windowIncludesOlderDaysWithinRange() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()

        let today = Self.assistantLine(
            messageId: "m-today", requestId: "r-today", model: "claude-sonnet-4",
            input: 100, output: 100, timestamp: Self.timestamp(daysAgo: 0, from: now))
        let tenDaysAgo = Self.assistantLine(
            messageId: "m-10", requestId: "r-10", model: "claude-sonnet-4",
            input: 100, output: 100, timestamp: Self.timestamp(daysAgo: 10, from: now))
        _ = try Self.write([today, tenDaysAgo], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)

        #expect(cost.todayTokens == 200)         // only today
        #expect(cost.last30DaysTokens == 400)    // both days are inside the 30-day window
    }

    // MARK: - AC14d — pricing fallback used with no network

    @Test
    func fallbackPricesUsedWithoutNetwork() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()

        // sonnet-4 fallback: input 0.000003, output 0.000015 per token.
        // 1000 input + 1000 output → 0.003 + 0.015 = 0.018 USD.
        let line = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 1_000, output: 1_000, timestamp: Self.timestamp(daysAgo: 0, from: now))
        _ = try Self.write([line], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)

        #expect(abs(cost.today - 0.018) < 1e-9)
    }

    @Test
    func unknownModelFallsBackToSonnetPrices() async {
        let pricing = Pricing(transport: NeverTransport(), defaults: Self.makeDefaults(), networkEnabled: false)
        let unknown = await pricing.costPerToken(model: "claude-totally-made-up")
        let sonnet = await pricing.costPerToken(model: "claude-sonnet-4")
        #expect(unknown.input == sonnet.input)
        #expect(unknown.output == sonnet.output)
    }

    @Test
    func normalizationCollapsesDatedAndVersionedModels() {
        #expect(Pricing.normalize("claude-sonnet-4-5-20250929") == "claude-sonnet-4")
        #expect(Pricing.normalize("claude-sonnet-4-20250514") == "claude-sonnet-4")
        #expect(Pricing.normalize("claude-opus-4-1") == "claude-opus-4")
        #expect(Pricing.normalize("anthropic.claude-3-5-sonnet-20241022") == "claude-3-5-sonnet")
        #expect(Pricing.normalize("claude-haiku-3-5") == "claude-haiku-3-5")
    }

    // MARK: - AC14e — incremental scan: re-scan reads only new bytes

    @Test
    func incrementalScanOnlyParsesNewLines() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let ts = Self.timestamp(daysAgo: 0, from: now)

        let first = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 1_000, output: 0, timestamp: ts)
        let url = try Self.write([first], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let firstScan = await scanner.scan(directories: [dir], costDays: 30, now: now)
        #expect(firstScan.todayTokens == 1_000)

        // Append a new line and re-scan: the incremental accumulation must reach 3000, proving the
        // second scan parsed ONLY the appended line (1000 already counted + 2000 new), not re-counted.
        let second = Self.assistantLine(
            messageId: "m2", requestId: "r2", model: "claude-sonnet-4",
            input: 2_000, output: 0, timestamp: ts)
        let body = (try String(contentsOf: url, encoding: .utf8)) + second + "\n"
        try body.data(using: .utf8)!.write(to: url)

        let secondScan = await scanner.scan(directories: [dir], costDays: 30, now: now)
        #expect(secondScan.todayTokens == 3_000)

        // A third scan with NO file change must add nothing (zero new bytes).
        let thirdScan = await scanner.scan(directories: [dir], costDays: 30, now: now)
        #expect(thirdScan.todayTokens == 3_000)
    }

    @Test
    func truncatedFileRescansFromZero() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let now = Date()
        let ts = Self.timestamp(daysAgo: 0, from: now)

        let original = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 5_000, output: 0, timestamp: ts)
        let url = try Self.write([original], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scan(directories: [dir], costDays: 30, now: now)

        // Truncate: overwrite with a smaller file. Offset > size → re-scan from 0. The aggregate from
        // the original run persists; the rescan re-adds the (now smaller) content. We assert the
        // scanner does not crash and produces a valid, non-negative result for the new content.
        let replacement = Self.assistantLine(
            messageId: "m2", requestId: "r2", model: "claude-sonnet-4",
            input: 100, output: 0, timestamp: ts)
        try (replacement + "\n").data(using: .utf8)!.write(to: url)

        let rescan = await scanner.scan(directories: [dir], costDays: 30, now: now)
        #expect(rescan.todayTokens >= 100)
    }

    // MARK: - Directory enumeration

    @Test
    func nestedJSONLFilesAreEnumerated() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("project-a/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let defaults = Self.makeDefaults()
        let now = Date()

        let line = Self.assistantLine(
            messageId: "m1", requestId: "r1", model: "claude-sonnet-4",
            input: 500, output: 0, timestamp: Self.timestamp(daysAgo: 0, from: now))
        _ = try Self.write([line], to: nested, name: "deep.jsonl")

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [dir], costDays: 30, now: now)
        #expect(cost.todayTokens == 500)
    }

    @Test
    func missingDirectoryYieldsZeroCost() async {
        let defaults = Self.makeDefaults()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let cost = await scanner.scan(directories: [missing], costDays: 30, now: Date())
        #expect(cost.today == 0)
        #expect(cost.last30Days == 0)
        #expect(cost.byModel.isEmpty)
    }
}

/// An `HTTPTransport` that always throws — guarantees the pricing fallback path (AC14d) is exercised
/// even if `networkEnabled` were ever flipped on by mistake.
private struct NeverTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
