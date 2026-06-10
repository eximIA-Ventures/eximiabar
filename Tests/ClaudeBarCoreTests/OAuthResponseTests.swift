import Foundation
import Testing
@testable import ClaudeBarCore

/// AC17 (a–c): utilization passthrough, centavo division, resets_at parsing.
/// Fixtures ported from
/// `_reference_codexbar/Tests/CodexBarTests/ClaudeOAuthTests.swift:69-128` and
/// `ClaudeUsageTests.swift`.
struct OAuthResponseTests {
    // MARK: AC17a — utilization passthrough (12.5 → remaining 87.5)

    @Test
    func utilizationIsUsedAsPercentageNotMultiplied() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 5 }
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response, rateLimitTier: "claude_pro")

        #expect(snapshot.session.utilization == 12.5)
        #expect(snapshot.session.remaining == 87.5)
        #expect(snapshot.session.windowMinutes == 300)
        #expect(snapshot.weekly.utilization == 30)
        #expect(snapshot.weekly.remaining == 70)
        #expect(snapshot.weekly.windowMinutes == 10080)
        #expect(snapshot.sonnet?.utilization == 5)
        #expect(snapshot.session.resetsAt != nil)
        #expect(snapshot.plan == .pro)
    }

    @Test
    func planResolvesFromSubscriptionTypeWhenTierGeneric() throws {
        let json = """
        { "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" } }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(
            response,
            rateLimitTier: "default_claude_ai",
            subscriptionType: "pro")
        #expect(snapshot.plan == .pro)
    }

    @Test
    func sessionFallbackCascadeUsesSevenDayWhenFiveHourMissing() throws {
        // five_hour absent → falls back to seven_day (AC9 cascade).
        let json = """
        {
          "seven_day": { "utilization": 42, "resets_at": "2025-12-31T00:00:00.000Z" }
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response)
        #expect(snapshot.session.utilization == 42)
        #expect(snapshot.session.windowMinutes == 300)
    }

    @Test
    func ignoresDesignAndOmeletteWindowsSilently() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": { "utilization": 44, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29 },
          "iguana_necktie": { "utilization": 99 }
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        // Probe fields are decoded but not surfaced as windows.
        #expect(response.iguanaNecktie != nil)
        let snapshot = UsageSnapshot.from(response)
        // Session stays at five_hour, unaffected by design/omelette.
        #expect(snapshot.session.utilization == 12.5)
    }

    @Test
    func routinesNullKeyRendersZeroBar() throws {
        // Key present but null → 0% window (AC9).
        let json = """
        {
          "five_hour": { "utilization": 12.5 },
          "seven_day_routines": null
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response)
        #expect(snapshot.dailyRoutines != nil)
        #expect(snapshot.dailyRoutines?.utilization == 0)
    }

    @Test
    func routinesAbsentKeyMeansNilWindow() throws {
        let json = """
        { "five_hour": { "utilization": 12.5 } }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response)
        #expect(snapshot.dailyRoutines == nil)
    }

    // MARK: AC17b — extra_usage centavo division

    @Test
    func extraUsageDividesCentavosByOneHundred() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2050,
            "used_credits": 325
          }
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response)
        #expect(snapshot.extraUsage?.isEnabled == true)
        #expect(snapshot.extraUsage?.monthlyLimit == 20.5)
        #expect(snapshot.extraUsage?.usedCredits == 3.25)
        #expect(snapshot.extraUsage?.currency == "USD")
    }

    @Test
    func extraUsageHonorsExplicitCurrency() throws {
        let json = """
        {
          "five_hour": { "utilization": 1 },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 520,
            "currency": "usd"
          }
        }
        """
        let response = try UsageFetcher.decode(Data(json.utf8))
        let snapshot = UsageSnapshot.from(response)
        #expect(snapshot.extraUsage?.monthlyLimit == 20)
        #expect(snapshot.extraUsage?.usedCredits == 5.2)
        #expect(snapshot.extraUsage?.currency == "USD")
    }

    // MARK: AC17c — resets_at with and without fractional seconds

    @Test
    func resetsAtParsesWithFractionalSeconds() {
        let date = ISO8601Decoder.date(from: "2025-12-25T12:00:00.000Z")
        #expect(date != nil)
    }

    @Test
    func resetsAtParsesWithoutFractionalSeconds() {
        let date = ISO8601Decoder.date(from: "2025-12-31T00:00:00Z")
        #expect(date != nil)
    }

    @Test
    func resetsAtBothFormatsResolveToSameInstant() {
        let withFraction = ISO8601Decoder.date(from: "2025-12-25T12:00:00.000Z")
        let withoutFraction = ISO8601Decoder.date(from: "2025-12-25T12:00:00Z")
        #expect(withFraction == withoutFraction)
    }

    @Test
    func resetsAtNilOnEmptyOrGarbage() {
        #expect(ISO8601Decoder.date(from: nil) == nil)
        #expect(ISO8601Decoder.date(from: "") == nil)
        #expect(ISO8601Decoder.date(from: "not-a-date") == nil)
    }

    // MARK: Credential parsing (from ClaudeOAuthTests.swift:7-53)

    @Test
    func parsesCredentialsFile() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "test-refresh",
            "expiresAt": 4102444800000,
            "scopes": ["usage:read"],
            "rateLimitTier": "default_claude_max_20x",
            "subscriptionType": "pro"
          }
        }
        """
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "test-token")
        #expect(creds.refreshToken == "test-refresh")
        #expect(creds.scopes == ["usage:read"])
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.subscriptionType == "pro")
        #expect(creds.isExpired == false)
    }

    @Test
    func missingAccessTokenThrows() {
        let json = """
        { "claudeAiOauth": { "accessToken": "", "refreshToken": "r" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func missingOAuthBlockThrows() {
        let json = """
        { "other": { "accessToken": "nope" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func missingExpiryTreatedAsExpired() {
        let creds = ClaudeOAuthCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil)
        #expect(creds.isExpired == true)
    }
}
