import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-6.1 AC4 — a number that is estimated or scraped never reaches the screen bare.
@MainActor
struct NumberProvenanceUITests {
    private static func snapshot(source: DataSource) -> DisplaySnapshot {
        DisplaySnapshot(
            session: RateWindow(utilization: 40, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 10, resetsAt: nil, windowMinutes: 10080),
            updatedAt: Date(),
            source: source)
    }

    @Test
    func cliSnapshotIsApproximateAndOAuthIsNot() {
        #expect(Self.snapshot(source: .cli).isApproximate)
        #expect(!Self.snapshot(source: .oauth).isApproximate)
    }

    /// Fails if any menu-bar or popover rendering of a CLI reading drops the `~`.
    @Test
    func cliReadingAlwaysCarriesTildeOnEverySurface() {
        let snap = Self.snapshot(source: .cli)
        let approx = snap.isApproximate
        let menu = MenuBarContentText.percentRemaining(session: snap.primaryWindow, approximate: approx)
        let brand = MenuBarDisplayText.displayText(session: snap.primaryWindow, pace: nil, approximate: approx)
        let brandPace = MenuBarDisplayText.displayText(session: snap.primaryWindow, pace: 5, approximate: approx)
        let headline = MetricRow.headlineText(value: 60, approximate: approx)
        for text in [menu, brand, brandPace, headline] {
            #expect(text?.contains("~") == true, "bare CLI number: \(text ?? "nil")")
        }
        #expect(MenuBarContentText.percentRemaining(session: snap.primaryWindow) == "60%")
        #expect(MetricRow.headlineText(value: 60, approximate: false) == "60%")
    }

    @Test
    func estimatedCostAlwaysCarriesTilde() {
        let estimated = ProviderCost(today: 1.5, last30Days: 20, todayTokens: 10, last30DaysTokens: 100,
                                     estimatedTokens: 12)
        let measured = ProviderCost(today: 1.5, last30Days: 20, todayTokens: 10, last30DaysTokens: 100)
        #expect(MenuBarContentText.costToday(cost: estimated)?.hasPrefix("~") == true)
        #expect(MenuBarContentText.costToday(cost: measured)?.hasPrefix("~") == false)
        #expect(PopoverCostSection.amount(estimated.last30Days, estimated: estimated.isEstimated).hasPrefix("~"))
        #expect(PopoverCostSection.estimateFootnote(for: estimated)?.contains("12") == true)
        #expect(PopoverCostSection.estimateFootnote(for: measured) == nil)
    }

    @Test
    func headerNamesTheMenuBarAccountOnlyWhenFocusDiffers() {
        let live = AccountIdentity(key: AccountKey(provider: .claude, identifier: "a@x.com"),
                                   email: "a@x.com", displayName: "Alice")
        let other = AccountIdentity(key: AccountKey(provider: .claude, identifier: "b@x.com"), email: "b@x.com")
        let workspace = WorkspaceSnapshot(
            accounts: [
                .init(identity: live, lifecycle: .live, display: nil, status: .live),
                .init(identity: other, lifecycle: .archived, display: nil, status: .archivedValid),
            ],
            menuBarKey: live.key,
            updatedAt: Date())
        #expect(UsageCardView.menuBarAccountLabel(for: workspace) == nil)
        #expect(UsageCardView.menuBarAccountLabel(for: workspace.withFocus(other.key)) == "Alice")
        #expect(UsageCardView.menuBarAccountLabel(for: nil) == nil)
    }
}
