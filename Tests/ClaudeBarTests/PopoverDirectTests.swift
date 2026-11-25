import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-6.2 AC3/AC4 — the action icon bar and the Ultra multiplier that is never invented.
@MainActor
struct PopoverDirectTests {
    @Test
    func iconBarKeepsEveryActionShortcutAndQuit() {
        let items = ActionSection.items(UsageCardActions())
        #expect(items.map(\.id) == ["refresh", "dashboard", "web", "status", "settings", "quit"])
        let tips = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.tooltip) })
        #expect(tips["refresh"]?.contains("⌘R") == true)
        #expect(tips["dashboard"]?.contains("⌘D") == true)
        #expect(tips["settings"]?.contains("⌘,") == true)
        #expect(tips["quit"]?.contains("⌘Q") == true)
        // No incident feed exists: the status page is offered, but muted.
        #expect(items.first { $0.id == "status" }?.muted == true)
        #expect(items.filter(\.muted).count == 1)
    }

    /// The Ultra price is not published in the code base, so there is no "N× your plan" to show.
    @Test
    func ultraHasNoInventedPrice() {
        #expect(ClaudePlan.ultra.approxMonthlyPriceUSD == nil)
        #expect(ClaudePlan.max.approxMonthlyPriceUSD != nil)
    }
}
