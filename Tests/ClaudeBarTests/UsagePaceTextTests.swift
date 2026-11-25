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

    /// EXB-6.2 AC1: on pace → the decision is "how much is left at the reset", and the expected
    /// number moves to the tick's tooltip.
    @Test
    func onPaceSaysWhatIsLeftAtReset() {
        let now = Date()
        // 50% elapsed, 50% used → projected use at reset 100% → ~0% left.
        let detail = UsagePaceText.detail(for: pace(utilization: 50, elapsedFraction: 0.5, now: now), now: now)
        #expect(detail.primary == "~0% left at reset")
        #expect(detail.expectedTooltip == "Expected by now: 50%")
        #expect(detail.runsOutBeforeReset == false)
    }

    /// Deficit that empties the window before the reset → "runs out ~<day> <hour>h".
    @Test
    func deficitSaysWhenItRunsOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let p = pace(utilization: 80, elapsedFraction: 0.25, now: now)
        let detail = UsagePaceText.detail(for: p, now: now, calendar: calendar)
        let runOut = try! #require(p.projectedRunOut)
        #expect(detail.primary == "At this pace, runs out ~\(UsagePaceText.dayHour(runOut, calendar: calendar))")
        #expect(detail.runsOutBeforeReset)
        #expect(detail.isReserve == false)
    }

    @Test
    func dayHourIsLocalizedWeekdayPlusHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-26 11:30 UTC is a Thursday.
        let date = Date(timeIntervalSince1970: 1_795_692_600)
        #expect(UsagePaceText.dayHour(date, calendar: calendar) == "Thu 11h")
    }

    /// Reserve: "~N% left at reset" with N from the observed burn rate.
    @Test
    func reserveSaysWhatIsLeft() {
        let now = Date()
        // 75% elapsed, 30% used → projected 40% at reset → ~60% left.
        let detail = UsagePaceText.detail(for: pace(utilization: 30, elapsedFraction: 0.75, now: now), now: now)
        #expect(detail.primary == "~60% left at reset")
        #expect(detail.isReserve == true)
        #expect(detail.secondary == "Lasts until reset")
    }

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
