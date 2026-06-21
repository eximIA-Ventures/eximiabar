import Foundation
import Testing
@testable import ClaudeBar

/// AC5 — the reset line's countdown variant ("Renova em 2h 15m") added beside the absolute clock.
/// `resetCountdown` is the pure, locale-free fragment; pinned here so a refactor can't drift the
/// bucketing. The `resetText` cases assert only that the `absolute` flag changes the output, to stay
/// independent of the bundle's localized strings.
struct PopoverFormatterResetTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func countdownHoursAndMinutes() {
        let reset = now.addingTimeInterval(2 * 3600 + 15 * 60)
        #expect(PopoverFormatter.resetCountdown(until: reset, now: now) == "2h 15m")
    }

    @Test
    func countdownMinutesOnly() {
        #expect(PopoverFormatter.resetCountdown(until: now.addingTimeInterval(45 * 60), now: now) == "45m")
    }

    @Test
    func countdownDaysAndHours() {
        let reset = now.addingTimeInterval(24 * 3600 + 3 * 3600)
        #expect(PopoverFormatter.resetCountdown(until: reset, now: now) == "1d 3h")
    }

    @Test
    func countdownExactHourDropsZeroMinutes() {
        #expect(PopoverFormatter.resetCountdown(until: now.addingTimeInterval(3600), now: now) == "1h")
    }

    @Test
    func countdownExactDayDropsZeroHours() {
        #expect(PopoverFormatter.resetCountdown(until: now.addingTimeInterval(24 * 3600), now: now) == "1d")
    }

    /// A reset that is essentially now (or already past) still reads as "1m", never "0m".
    @Test
    func countdownFloorsAtOneMinute() {
        #expect(PopoverFormatter.resetCountdown(until: now, now: now) == "1m")
        #expect(PopoverFormatter.resetCountdown(until: now.addingTimeInterval(-60), now: now) == "1m")
    }

    @Test
    func resetTextHonoursAbsoluteFlag() {
        let reset = now.addingTimeInterval(2 * 3600 + 15 * 60)
        let absolute = PopoverFormatter.resetText(for: reset, absolute: true, now: now)
        let relative = PopoverFormatter.resetText(for: reset, absolute: false, now: now)
        #expect(absolute != nil)
        #expect(relative != nil)
        #expect(absolute != relative)
    }

    @Test
    func resetTextNilWhenNoDate() {
        #expect(PopoverFormatter.resetText(for: nil) == nil)
    }

    // MARK: - Metric percent line flips with showUsed (AC5)

    /// Consumed mode shows the utilization number ("9% consumido"), not the remaining ("91").
    @Test
    func metricTextUsesUtilizationWhenShowUsed() {
        let text = PopoverFormatter.metricPercentText(utilization: 9, remaining: 91, showUsed: true)
        #expect(text.contains("9"))
        #expect(!text.contains("91"))
    }

    @Test
    func metricTextUsesRemainingWhenNotShowUsed() {
        let text = PopoverFormatter.metricPercentText(utilization: 9, remaining: 91, showUsed: false)
        #expect(text.contains("91"))
    }

    /// The same window renders a different line depending on the toggle.
    @Test
    func metricTextFlipsWithToggle() {
        let used = PopoverFormatter.metricPercentText(utilization: 30, remaining: 70, showUsed: true)
        let left = PopoverFormatter.metricPercentText(utilization: 30, remaining: 70, showUsed: false)
        #expect(used != left)
    }
}
