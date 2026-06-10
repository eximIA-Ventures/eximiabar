import ClaudeBarCore
import Testing
@testable import ClaudeBar

/// Tests for the F2 brand-icon title string (EXB-1.2 AC13).
struct MenuBarDisplayTextTests {
    private func session(remaining: Double) -> RateWindow {
        RateWindow(utilization: 100 - remaining, resetsAt: nil, windowMinutes: 300)
    }

    /// AC13: no pace → leading-space percentage of the session *remaining*.
    @Test
    func percentOnlyHasLeadingSpace() {
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 87), pace: nil) == " 87%")
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 87.5), pace: 0) == " 88%")
    }

    /// AC13: positive pace → `"87% · +5%"` (no leading space, middle-dot separator).
    @Test
    func positivePaceUsesCombinedForm() {
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 87), pace: 5) == "87% · +5%")
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 87), pace: 4.6) == "87% · +5%")
    }

    /// AC13: zero or negative pace falls back to the percent-only form.
    @Test
    func nonPositivePaceFallsBackToPercent() {
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 50), pace: 0) == " 50%")
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 50), pace: -3) == " 50%")
    }

    /// Remaining is clamped to 0...100.
    @Test
    func percentageIsClamped() {
        #expect(MenuBarDisplayText.displayText(session: session(remaining: 150), pace: nil) == " 100%")
        #expect(MenuBarDisplayText.displayText(session: session(remaining: -20), pace: nil) == " 0%")
    }

    /// Nil session → nil string.
    @Test
    func nilSessionReturnsNil() {
        #expect(MenuBarDisplayText.displayText(session: nil, pace: 5) == nil)
    }
}
