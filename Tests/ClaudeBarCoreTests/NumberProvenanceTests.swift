import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-6.1 — every number that is not a measurement says so.
struct NumberProvenanceCoreTests {
    // MARK: AC1 — positional CLI fallback is gated

    @Test
    func positionalReadingIsFlaggedAsPositional() {
        let sample = """
        Usage this cycle
        55% used
        This week so far
        22% used
        """
        let reading = ClaudeStatusProbe.parseUsageReading(rawOutput: sample)
        #expect(reading?.isPositional == true)
        #expect(reading?.session == 55)
        #expect(reading?.weekly == 22)
    }

    @Test
    func labelledReadingIsNotPositional() {
        let sample = """
        Current session
        40% used
        Current week (all models)
        10% used
        """
        #expect(ClaudeStatusProbe.parseUsageReading(rawOutput: sample)?.isPositional == false)
    }

    @Test
    func positionalValueAbove100IsRejectedNotClamped() {
        // The old path clamped 140 to 100 and showed a full meter that nobody measured.
        let sample = """
        Usage this cycle
        140% used
        This week so far
        22% used
        """
        #expect(ClaudeStatusProbe.parseUsageReading(rawOutput: sample) == nil)
    }

    @Test
    func positionalRejectsAmbiguousBufferWithTooManyPercentages() {
        let sample = (1...5).map { "line \($0): \($0 * 10)% something" }.joined(separator: "\n")
        #expect(ClaudeStatusProbe.parseUsageReading(rawOutput: sample) == nil)
    }

    @Test
    func labelledPanelWithManyPercentagesIsStillAccepted() {
        let sample = """
        Current session
        40% used
        Current week (all models)
        10% used
        Current week (Sonnet only)
        3% used
        Current week (Opus)
        7% used
        Extra 9% used
        """
        let reading = ClaudeStatusProbe.parseUsageReading(rawOutput: sample)
        #expect(reading?.session == 40)
        #expect(reading?.weekly == 10)
        #expect(reading?.isPositional == false)
    }

    @Test
    func positionalNeedsTwoValues() {
        #expect(ClaudeStatusProbe.parseUsageReading(rawOutput: "Something\n55% used") == nil)
    }

    // MARK: AC2 — cost priced by family is an estimate

    private static func line(_ id: String, model: String, input: Int, output: Int, at date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let obj: [String: Any] = [
            "type": "assistant", "requestId": "r-\(id)", "timestamp": fmt.string(from: date),
            "message": ["id": "m-\(id)", "model": model,
                        "usage": ["input_tokens": input, "output_tokens": output]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private static func scan(_ lines: [String]) async throws -> ProviderCost {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb61-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("s.jsonl"))
        let defaults = CostDefaults(UserDefaults(suiteName: "exb61.\(UUID().uuidString)")!)
        let pricing = Pricing(transport: ProvenanceNeverTransport(), defaults: defaults, networkEnabled: false)
        let scanner = CostScanner(pricing: pricing, defaults: defaults)
        return await scanner.scan(directories: [dir], costDays: 30, now: Date())
    }

    @Test
    func priceSourceClassification() {
        #expect(Pricing.fallbackSource(for: "claude-sonnet-4-20250514") == .table)
        #expect(Pricing.fallbackSource(for: "claude-opus-9-9") == .family)
        #expect(Pricing.fallbackSource(for: "gpt-unknown") == .fallbackDefault)
        #expect(Pricing.PriceSource.family.isEstimate)
        #expect(!Pricing.PriceSource.table.isEstimate)
        #expect(!Pricing.PriceSource.catalog.isEstimate)
    }

    @Test
    func inventedModelLightsTheEstimateMarker() async throws {
        let now = Date()
        let cost = try await Self.scan([
            Self.line("a", model: "claude-sonnet-4", input: 3_000, output: 1_000, at: now),
            Self.line("b", model: "claude-opus-9-9", input: 1_000, output: 0, at: now),
        ])
        #expect(cost.isEstimated)
        #expect(cost.estimatedTokens == 1_000)
        #expect(abs(cost.estimatedShare - 0.2) < 1e-9)
    }

    @Test
    func knownModelsOnlyDoNotLightTheMarker() async throws {
        let cost = try await Self.scan([
            Self.line("a", model: "claude-sonnet-4", input: 3_000, output: 1_000, at: Date()),
        ])
        #expect(!cost.isEstimated)
        #expect(cost.estimatedShare == 0)
    }

    // MARK: AC3.2 — the placeholder identity never reaches the roster

    @Test
    func placeholderIdentityIsNeverRecorded() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb61-roster-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountRosterStore(supportDirectory: directory, legacyKeychainService: nil)
        let placeholder = AccountIdentity(key: AccountKey(provider: .claude, identifier: "live"), email: "")
        let outcome = await store.captureIfIdentityChanged(
            current: placeholder,
            credentials: ClaudeOAuthCredentials(
                accessToken: "token", refreshToken: nil, expiresAt: nil,
                scopes: [], rateLimitTier: nil, subscriptionType: "max"))
        guard case .skipped = outcome else {
            Issue.record("placeholder identity must be skipped, got \(outcome)")
            return
        }
        #expect(await store.roster().isEmpty)
        #expect(AccountKey(provider: .codex, identifier: " LIVE ").isPlaceholder)
        #expect(!AccountKey(provider: .claude, identifier: "a@b.com").isPlaceholder)
    }
}

private struct ProvenanceNeverTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
