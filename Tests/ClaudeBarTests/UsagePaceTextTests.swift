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

    /// On-pace enriches the status with the pace point: "On pace - 50%" and "Lasts until reset".
    /// The pace number now lives in the bottom line (no floating label over the bar).
    @Test
    func onPaceStrings() {
        let now = Date()
        // 50% elapsed → expectedUsedPercent ≈ 50.
        let detail = UsagePaceText.detail(for: pace(utilization: 50, elapsedFraction: 0.5, now: now), now: now)
        #expect(detail.primary == "On pace - 50%")
        #expect(detail.secondary == "Lasts until reset")
        #expect(detail.isReserve == false)
    }

    /// Deficit enriches "N% in deficit" with the pace point: "55% in deficit - 25%", red stripe.
    @Test
    func deficitStrings() {
        let now = Date()
        // 25% elapsed, 80% used → delta +55, expectedUsedPercent ≈ 25.
        let detail = UsagePaceText.detail(for: pace(utilization: 80, elapsedFraction: 0.25, now: now), now: now)
        #expect(detail.primary == "55% in deficit - 25%")
        #expect(detail.isReserve == false)
        // Burning ahead → projected run-out before reset.
        #expect(detail.secondary?.hasPrefix("Runs out in ") == true || detail.secondary == "Runs out now")
    }

    /// Slightly-ahead band (2 < |delta| ≤ 6) renders the number, not "On pace" — reference parity
    /// (`_reference_codexbar` `.slightlyAhead` → "N% in deficit"). Regression guard for the S3 fix.
    /// The pace point is appended: "5% in deficit - 50%".
    @Test
    func slightlyAheadShowsNumberNotOnPace() {
        let now = Date()
        // 50% elapsed, 55% used → delta +5, expectedUsedPercent ≈ 50.
        let detail = UsagePaceText.detail(for: pace(utilization: 55, elapsedFraction: 0.5, now: now), now: now)
        #expect(detail.primary == "5% in deficit - 50%")
        #expect(detail.isReserve == false)
    }

    /// Reserve enriches "N% in reserve" with the pace point: "45% in reserve - 75%", green stripe.
    @Test
    func reserveStrings() {
        let now = Date()
        // 75% elapsed, 30% used → delta -45, expectedUsedPercent ≈ 75.
        let detail = UsagePaceText.detail(for: pace(utilization: 30, elapsedFraction: 0.75, now: now), now: now)
        #expect(detail.primary == "45% in reserve - 75%")
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
