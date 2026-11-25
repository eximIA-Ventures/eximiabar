import Foundation
import Testing
@testable import ClaudeBar
@testable import ClaudeBarCore

/// Claude Ultra has no 5-hour limit: the usage response omits `five_hour` or sends it as `null`.
/// The session window must then be absent end to end, and the menu bar must lead with the next
/// available window instead of an empty 0% session.
struct UltraNoFiveHourWindowTests {
    private static func decode(_ json: String) throws -> OAuthUsageResponse {
        try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(json.utf8))
    }

    private static let weekly = #""seven_day":{"utilization":48,"resets_at":"2026-12-01T10:00:00Z"}"#

    @Test
    func missingFiveHourKeyLeavesNoSessionWindow() throws {
        let response = try Self.decode("{\(Self.weekly)}")
        #expect(response.fiveHour == nil)
        let usage = UsageSnapshot.from(response, rateLimitTier: nil, subscriptionType: nil)
        #expect(usage.session == nil)
        #expect(usage.weekly.utilization == 48)

        let display = DisplaySnapshot.from(usage)
        #expect(display.session == nil)
        #expect(display.primaryWindow == usage.weekly)
        #expect(display.secondaryWindow == nil)
        #expect(!display.predictableWindows.contains { $0.id == RateWindowID.session })
    }

    @Test
    func nullFiveHourLeavesNoSessionWindow() throws {
        let response = try Self.decode(#"{"five_hour":null,"# + Self.weekly + "}")
        #expect(response.fiveHour == nil)
        let display = DisplaySnapshot.from(UsageSnapshot.from(response))
        #expect(display.session == nil)
        #expect(display.primaryWindow?.utilization == 48)
        #expect(display.primaryWindow?.windowMinutes == 10080)
    }

    @Test
    func emptyFiveHourObjectIsTreatedAsAbsent() throws {
        let response = try Self.decode(#"{"five_hour":{"utilization":null,"resets_at":null},"# + Self.weekly + "}")
        #expect(UsageSnapshot.from(response).session == nil)
    }

    @Test
    func presentFiveHourStaysThePrimaryWindow() throws {
        let response = try Self.decode(#"{"five_hour":{"utilization":12,"resets_at":"2026-11-25T20:00:00Z"},"# + Self.weekly + "}")
        let display = DisplaySnapshot.from(UsageSnapshot.from(response))
        #expect(display.session?.utilization == 12)
        #expect(display.primaryWindow?.windowMinutes == 300)
        #expect(display.secondaryWindow?.utilization == 48)
    }

    @Test
    func ultraPlanIsResolvedWhenTheTierSaysSo() throws {
        let response = try Self.decode("{\(Self.weekly)}")
        let usage = UsageSnapshot.from(response, rateLimitTier: nil, subscriptionType: "ultra")
        #expect(usage.plan == .ultra)
    }
}
