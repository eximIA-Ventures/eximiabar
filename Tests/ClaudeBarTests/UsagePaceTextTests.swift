import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests the EXACT pace strings from AC13 and the popover formatters (EXB-1.3 T3/T4).
struct UsagePaceTextTests {
    private let weeklyMinutes = 10_080

    private func pace(utilization: Double, elapsedFraction: Double, now: Date) -> UsagePace {
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * (1 - elapsedFraction))
        let window = RateWindow(utilization: utilization, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        return UsagePace.compute(window: window, now: now)!
    }

    /// On-pace renders the exact "On pace" string and "Lasts until reset".
    @Test
    func onPaceStrings() {
        let now = Date()
        let detail = UsagePaceText.detail(for: pace(utilization: 50, elapsedFraction: 0.5, now: now), now: now)
        #expect(detail.primary == "On pace")
        #expect(detail.secondary == "Lasts until reset")
        #expect(detail.isReserve == false)
    }

    /// Deficit renders "N% in deficit" with an integer N and a red stripe.
    @Test
    func deficitStrings() {
        let now = Date()
        // 25% elapsed, 80% used → delta +55.
        let detail = UsagePaceText.detail(for: pace(utilization: 80, elapsedFraction: 0.25, now: now), now: now)
        #expect(detail.primary == "55% in deficit")
        #expect(detail.isReserve == false)
        // Burning ahead → projected run-out before reset.
        #expect(detail.secondary?.hasPrefix("Runs out in ") == true || detail.secondary == "Runs out now")
    }

    /// Reserve renders "N% in reserve" with a green stripe and "Lasts until reset".
    @Test
    func reserveStrings() {
        let now = Date()
        // 75% elapsed, 30% used → delta -45.
        let detail = UsagePaceText.detail(for: pace(utilization: 30, elapsedFraction: 0.75, now: now), now: now)
        #expect(detail.primary == "45% in reserve")
        #expect(detail.isReserve == true)
        #expect(detail.secondary == "Lasts until reset")
    }

    /// Duration text formats "Xd Yh" for multi-day, "Xh Ym" for sub-day, "now" for sub-minute.
    @Test
    func durationTextFormats() {
        #expect(UsagePaceText.durationText(seconds: 30) == "now")
        #expect(UsagePaceText.durationText(seconds: 90 * 60) == "1h 30m")
        #expect(UsagePaceText.durationText(seconds: (2 * 86_400) + (3 * 3_600)) == "2d 3h")
        #expect(UsagePaceText.durationText(seconds: 45 * 60) == "45m")
    }
}

/// Tests for `PopoverFormatter` (EXB-1.3 T4/AC9/AC16).
struct PopoverFormatterTests {
    @Test
    func resetTextNilWhenNoDate() {
        #expect(PopoverFormatter.resetText(for: nil) == nil)
    }

    @Test
    func resetTextHasResetsPrefix() {
        let text = PopoverFormatter.resetText(for: Date().addingTimeInterval(3_600))
        #expect(text?.hasPrefix("Resets ") == true)
    }

    @Test
    func updatedTextBuckets() {
        let now = Date()
        #expect(PopoverFormatter.updatedText(from: now, now: now) == "Updated just now")
        #expect(PopoverFormatter.updatedText(from: now.addingTimeInterval(-300), now: now) == "Updated 5m ago")
        #expect(PopoverFormatter.updatedText(from: now.addingTimeInterval(-7_200), now: now) == "Updated 2h ago")
        #expect(PopoverFormatter.updatedText(from: now.addingTimeInterval(-2 * 86_400), now: now) == "Updated 2d ago")
    }

    @Test
    func currencyFormat() {
        #expect(PopoverFormatter.currency(222) == "$222.00")
        #expect(PopoverFormatter.currency(0.08) == "$0.08")
    }

    @Test
    func tokenCountFormat() {
        #expect(PopoverFormatter.tokenCount(27_000) == "27K")
        #expect(PopoverFormatter.tokenCount(5_400_000) == "5.4M")
        #expect(PopoverFormatter.tokenCount(500) == "500")
    }
}
