import SwiftUI
import Testing
@testable import ClaudeBar

/// The v2.2.0 opt-in "eximIA Meter" skin is a pure colour swap: only the healthy `< 70` band and the
/// brand accent change; the attention/critical bands stay shared. These assert that routing on plain
/// `Color` values — no SwiftUI rendering, so no headless trap.
@Suite("Popover theme palette")
struct PopoverThemeTests {
    @Test func accentDiffersByTheme() {
        #expect(DesignTokens.accent(for: .classic) != DesignTokens.accent(for: .meter))
        #expect(DesignTokens.accent(for: .classic) == DesignTokens.brand)
        #expect(DesignTokens.accent(for: .meter) == DesignTokens.meterAccent)
    }

    @Test func themeRawValuesAreStableForPersistence() {
        #expect(PopoverTheme.classic.rawValue == "classic")
        #expect(PopoverTheme.meter.rawValue == "meter")
        #expect(PopoverTheme(rawValue: "meter") == .meter)
        #expect(PopoverTheme.allCases.count == 2)
    }
}
