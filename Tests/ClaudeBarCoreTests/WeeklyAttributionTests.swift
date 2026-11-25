import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-6.3 — "what ate the week" from real-shaped transcript fixtures.
struct WeeklyAttributionTests {
    private static let since = Date(timeIntervalSince1970: 1_790_000_000)

    private static func stamp(_ offset: TimeInterval) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: since.addingTimeInterval(offset))
    }

    private static func line(
        id: String, cwd: String, input: Int, output: Int = 0,
        at offset: TimeInterval, sidechain: Bool = false, model: String = "claude-sonnet-4") -> String
    {
        let obj: [String: Any] = [
            "type": "assistant", "requestId": "r-\(id)", "timestamp": stamp(offset),
            "cwd": cwd, "isSidechain": sidechain,
            "message": ["id": "m-\(id)", "model": model,
                        "usage": ["input_tokens": input, "output_tokens": output]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
    }

    /// Main session in `web-app` (3000 in, plus a duplicate chunk and a line before the window),
    /// a sub-agent named by its `.meta.json` (`dev`, 1000 in, project `api`), and one named only by
    /// its file name (`qa-check`, 1000 in, project `api`). Same model everywhere, so the weight is
    /// proportional to tokens and the shares are exact.
    private static func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb63-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-x-web-app", isDirectory: true)
        try write([
            line(id: "old", cwd: "/Users/x/web-app", input: 99_000, at: -3600),     // before the window
            line(id: "a", cwd: "/Users/x/web-app", input: 1_000, at: 60),           // streamed chunk 1
            line(id: "a", cwd: "/Users/x/web-app", input: 2_000, at: 61),           // cumulative chunk wins
            line(id: "b", cwd: "/Users/x/web-app", input: 1_000, at: 120),
        ], to: project.appendingPathComponent("s1.jsonl"))
        let subagents = project.appendingPathComponent("s1/subagents", isDirectory: true)
        try write([line(id: "c", cwd: "/Users/x/api", input: 1_000, at: 200, sidechain: true)],
                  to: subagents.appendingPathComponent("agent-a1b2c3d4e5f6a7b8c.jsonl"))
        try #"{"agentType":"dev","name":"dev"}"#.data(using: .utf8)!
            .write(to: subagents.appendingPathComponent("agent-a1b2c3d4e5f6a7b8c.meta.json"))
        try write([line(id: "d", cwd: "/Users/x/api", input: 1_000, at: 300, sidechain: true)],
                  to: subagents.appendingPathComponent("agent-qa-check-0123456789abcdef.jsonl"))
        return root
    }

    @Test
    func splitsByProjectAndAgentWithDedupAndWindow() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let week = WeeklyAttributionScanner.scan(directories: [root], since: Self.since)

        let projects = Dictionary(uniqueKeysWithValues: week.byProject.map { ($0.name, $0.share) })
        #expect(abs((projects["web-app"] ?? 0) - 0.6) < 1e-9)   // 3000 of 5000 tokens
        #expect(abs((projects["api"] ?? 0) - 0.4) < 1e-9)

        let agents = Dictionary(uniqueKeysWithValues: week.byAgent.map { ($0.name, $0.share) })
        #expect(abs((agents[WeeklyAttribution.mainAgentName] ?? 0) - 0.6) < 1e-9)
        #expect(abs((agents["dev"] ?? 0) - 0.2) < 1e-9)
        #expect(abs((agents["qa-check"] ?? 0) - 0.2) < 1e-9)
        #expect(week.byAgent.count == 3)
        #expect(week.byAgent.first?.name == WeeklyAttribution.mainAgentName) // sorted by weight

        // The line before the window (99k tokens) and the superseded chunk are not counted.
        #expect(week.byProject.reduce(0) { $0 + $1.tokens } == 5_000)
    }

    @Test
    func slicesBecomePercentagePointsOfTheWeek() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let week = WeeklyAttributionScanner.scan(directories: [root], since: Self.since)
        let main = try #require(week.byAgent.first { $0.name == WeeklyAttribution.mainAgentName })
        #expect(abs(main.points(of: 50) - 30) < 1e-9)   // 60% of 50 p.p.
    }

    @Test
    func sidechainLineInAMainFileCountsAsUnnamedSubagent() {
        let line = Data(Self.line(id: "z", cwd: "/x/p", input: 10, at: 5, sidechain: true).utf8)
        let parsed = WeeklyAttributionScanner.parse(line, since: Self.since, fileAgent: nil)
        #expect(parsed?.entry.agent == WeeklyAttribution.unnamedSubagentName)
    }

    @Test
    func subagentNameFromFileStem() {
        #expect(WeeklyAttributionScanner.nameFromFileStem("agent-dev-fix-qa-0123456789abcdef") == "dev-fix-qa")
        #expect(WeeklyAttributionScanner.nameFromFileStem("agent-a57046da6fda64945") == nil)
        #expect(WeeklyAttributionScanner.nameFromFileStem("session") == nil)
    }

    @Test
    func emptyWeekWhenNothingSinceTheReset() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let week = WeeklyAttributionScanner.scan(directories: [root], since: Self.since.addingTimeInterval(86_400))
        #expect(week.isEmpty)
        #expect(week.byProject.isEmpty)
    }

    @Test
    func windowStartIsResetMinusSevenDays() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WeeklyAttribution.windowStart(resetsAt: reset) == reset.addingTimeInterval(-7 * 86_400))
    }
}

/// Opt-in timing over the real `~/.claude/projects` (EXB_BENCH_WEEK=1). Prints, never asserts a time.
struct WeeklyAttributionRealBench {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXB_BENCH_WEEK"] == "1"))
    func timeOverRealTranscripts() {
        let since = Date().addingTimeInterval(-7 * 86_400)
        let start = Date()
        let week = WeeklyAttributionScanner.scan(since: since)
        print("WEEK bench: \(String(format: "%.2f", Date().timeIntervalSince(start)))s, projects=\(week.byProject.count), agents=\(week.byAgent.count)")
        for s in week.byAgent.prefix(8) { print("WEEK agent \(s.name) \(String(format: "%.1f", s.share * 100))%") }
    }
}
