import Foundation
import Testing
@testable import ClaudeBarCore

/// The Dashboard's cost caveat says the estimate **includes cache**. This holds the code to it: a
/// fixture whose only tokens are cache reads/writes must cost more than zero, at the table's cache
/// rates, on the Dashboard's analytics path (not only the popover's scan).
struct DashboardCachePricingCoherenceTests {
    @Test
    func dashboardAnalyticsPricesCacheTokens() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let obj: [String: Any] = [
            "type": "assistant", "requestId": "r1", "timestamp": fmt.string(from: now), "cwd": "/x/p",
            "sessionId": "s1",
            "message": ["id": "m1", "model": "claude-sonnet-4",
                        "usage": ["input_tokens": 0, "output_tokens": 0,
                                  "cache_read_input_tokens": 1_000_000,
                                  "cache_creation_input_tokens": 1_000_000]],
        ]
        try (String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n")
            .data(using: .utf8)!.write(to: dir.appendingPathComponent("s1.jsonl"))

        let defaults = CostDefaults(UserDefaults(suiteName: "exb-cache.\(UUID().uuidString)")!)
        let scanner = CostScanner(
            pricing: Pricing(transport: CacheCoherenceNeverTransport(), defaults: defaults, networkEnabled: false),
            defaults: defaults)
        let analytics = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        let cost = analytics.byDayModel.reduce(0) { $0 + $1.cost }
        let expected = Pricing.fallbackPrice(for: "claude-sonnet-4")
            .cost(input: 0, output: 0, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        #expect(expected > 0)
        #expect(abs(cost - expected) < 1e-9)
    }

    /// The caveat text must not claim the opposite of the test above, in either language.
    @Test
    func caveatDoesNotSayCacheIsUnpriced() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "pt-BR"] {
            let text = try String(
                contentsOf: root.appendingPathComponent("Sources/ClaudeBar/Resources/\(lang).lproj/Localizable.strings"),
                encoding: .utf8).lowercased()
            #expect(!text.contains("does not price cache"))
            #expect(!text.contains("não precifica tokens de cache"))
            let caveat = text.components(separatedBy: "\n").first { $0.hasPrefix("\"dashboard.cost.caveat\"") } ?? ""
            #expect(caveat.contains("cache"))
        }
    }
}

private struct CacheCoherenceNeverTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}
