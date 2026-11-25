import Foundation
import Testing
@testable import ClaudeBarCore

/// Current-model pricing (Claude 5 family + 4.x): normalization, per-model prices, cache rates,
/// family-aware fallback for unknown IDs, and display names. Prices are USD per million tokens.
struct PricingCurrentModelsTests {
    private static func makePricing() -> Pricing {
        let suite = "PricingCurrentModelsTests.\(UUID().uuidString)"
        return Pricing(
            transport: PricingNeverTransport(),
            defaults: CostDefaults(UserDefaults(suiteName: suite)!),
            networkEnabled: false)
    }

    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-15 }

    // (model id as it appears in JSONL, input $/M, output $/M, cache read $/M)
    private static let expected: [(String, Double, Double, Double)] = [
        ("claude-fable-5-2", 8, 40, 0.20),
        ("claude-mythos-5-2", 8, 40, 0.8),
        ("claude-fable-5-1", 10, 50, 1.0),
        ("claude-fable-5", 10, 50, 1.0),
        ("claude-mythos-5-1", 10, 50, 1.0),
        ("claude-opus-5-5", 4, 20, 0.20),
        ("claude-opus-5", 5, 25, 0.5),
        ("claude-opus-4-8", 5, 25, 0.5),
        ("claude-opus-4-7", 5, 25, 0.5),
        ("claude-opus-4-6", 5, 25, 0.5),
        ("claude-opus-4-1", 15, 75, 1.5),
        ("claude-opus-4", 15, 75, 1.5),
        ("claude-sonnet-5-5", 2, 10, 0.10),
        ("claude-sonnet-5", 2, 10, 0.2),
        ("claude-sonnet-4-6", 3, 15, 0.3),
        ("claude-sonnet-4-5", 3, 15, 0.3),
        ("claude-sonnet-4", 3, 15, 0.3),
        ("claude-haiku-5-5", 0.10, 0.50, 0.01),
        ("claude-haiku-4-5", 1, 5, 0.1),
        ("claude-haiku-3-5", 0.8, 4, 0.08),
    ]

    @Test
    func everyCurrentModelHasItsPublishedPrice() async {
        let pricing = Self.makePricing()
        for (model, input, output, cacheRead) in Self.expected {
            let price = await pricing.tokenPrice(model: model)
            #expect(Self.close(price.input, input / 1e6), "input \(model)")
            #expect(Self.close(price.output, output / 1e6), "output \(model)")
            #expect(Self.close(price.cacheRead, cacheRead / 1e6), "cache read \(model)")
            #expect(Self.close(price.cacheWrite, input * 1.25 / 1e6), "cache write \(model)")
        }
    }

    @Test
    func datedAndProviderPrefixedIdsResolveToTheSamePrice() async {
        let pricing = Self.makePricing()
        let base = await pricing.tokenPrice(model: "claude-opus-5-5")
        for variant in [
            "claude-opus-5-5-20261001",
            "anthropic.claude-opus-5-5",
            "anthropic/claude-opus-5-5",
            "us.anthropic.claude-opus-5-5-20261001-v1:0",
            "claude-opus-5-5@20261001",
            "  Claude-Opus-5-5  ",
        ] {
            let got = await pricing.tokenPrice(model: variant)
            #expect(got == base, "\(variant)")
        }
    }

    @Test
    func normalizationUsesLongestKnownPrefix() {
        #expect(Pricing.normalize("claude-opus-4-8") == "claude-opus-4-8")
        #expect(Pricing.normalize("claude-opus-4-8-20260101") == "claude-opus-4-8")
        #expect(Pricing.normalize("claude-opus-4-20250514") == "claude-opus-4")
        #expect(Pricing.normalize("claude-opus-5-5") == "claude-opus-5-5")
        #expect(Pricing.normalize("claude-opus-5") == "claude-opus-5")
        #expect(Pricing.normalize("claude-fable-5-2") == "claude-fable-5-2")
        #expect(Pricing.normalize("claude-sonnet-5-5-20261001") == "claude-sonnet-5-5")
        #expect(Pricing.normalize("claude-haiku-5-5") == "claude-haiku-5-5")
        #expect(Pricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        // `claude-opus-4-8` must never be swallowed by `claude-opus-4`, nor `-5` by `-5-5`.
        #expect(Pricing.normalize("claude-opus-45") == "claude-opus-45")
    }

    @Test
    func unknownModelUsesTheCurrentModelOfItsFamily() async {
        let pricing = Self.makePricing()
        for (unknown, current) in [
            ("claude-opus-9-9", "claude-opus-5-5"),
            ("claude-haiku-7", "claude-haiku-5-5"),
            ("claude-fable-6", "claude-fable-5-2"),
            ("claude-sonnet-6", "claude-sonnet-5-5"),
            ("something-else", "claude-sonnet-5-5"),
        ] {
            let got = await pricing.tokenPrice(model: unknown)
            let want = await pricing.tokenPrice(model: current)
            #expect(got == want, "\(unknown) → \(current)")
        }
    }

    @Test
    func costIncludesCacheReadAndWrite() {
        let price = Pricing.fallbackTable["claude-opus-5-5"]!
        // 1M input $4 + 1M output $20 + 1M cache read $0.20 + 1M cache write $5.
        let cost = price.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        #expect(abs(cost - 29.20) < 1e-9)
    }

    @Test
    func displayNamesAreReadable() {
        #expect(Pricing.displayName(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(Pricing.displayName(for: "claude-fable-5-2-20261001") == "Fable 5.2")
        #expect(Pricing.displayName(for: "claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(Pricing.displayName(for: "claude-haiku-5-5") == "Haiku 5.5")
        #expect(Pricing.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(Pricing.displayName(for: "claude-3-5-sonnet") == "Sonnet 3.5")
        #expect(Pricing.displayName(for: "<synthetic>") == "<synthetic>")
    }

    @Test
    func oauthResponseToleratesFableWindowPresentOrAbsent() throws {
        let with = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_fable":{"utilization":33}}"#
        let without = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#
        let a = try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(with.utf8))
        let b = try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(without.utf8))
        #expect(a.sevenDayFable?.utilization == 33)
        #expect(b.sevenDayFable == nil)
        #expect(UsageSnapshot.from(a).fable?.utilization == 33)
        #expect(UsageSnapshot.from(b).fable == nil)
    }
}

private struct PricingNeverTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
