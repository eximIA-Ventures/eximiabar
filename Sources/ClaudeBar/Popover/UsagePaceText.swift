import ClaudeBarCore
import Foundation

/// Maps a `UsagePace` to the pace line shown under a usage bar.
///
/// EXB-6.2 AC1 replaced the AC13 wording ("45% in reserve - 30%") with the decision it implies:
/// primary `"At this pace, runs out ~Thu 11h"` / `"~10% left at reset"`; the expected-use number
/// moved to the tooltip of the tick on the bar. Secondary keeps `"Lasts until reset"` /
/// `"Runs out in Xd Yh"` / `"Runs out now"`.
enum UsagePaceText {
    struct Detail {
        /// Primary line, in the language of a decision (EXB-6.2 AC1): "At this pace, runs out ~Thu
        /// 11h" when the burn empties the window before the reset, otherwise "~10% left at reset".
        let primary: String
        /// Secondary line: the run-out projection, or `nil` when there is nothing to project.
        let secondary: String?
        /// The expected used percent — drives the bar's pace tick position.
        let pacePercent: Double
        /// `true` when the stripe should be green (reserve), `false` when red (deficit).
        let isReserve: Bool
        /// Tooltip of the pace tick: the "expected" number no longer lives in the text (AC1.3).
        let expectedTooltip: String
        /// `true` when the projection empties the window before the reset (drives the red state).
        let runsOutBeforeReset: Bool
    }

    /// Build the pace detail for a computed pace.
    static func detail(for pace: UsagePace, now: Date = .init(), calendar: Calendar = .current) -> Detail {
        Detail(
            primary: self.primaryLabel(for: pace, calendar: calendar),
            secondary: self.secondaryLabel(for: pace, now: now),
            pacePercent: pace.expectedUsedPercent,
            isReserve: pace.reserve > 0,
            expectedTooltip: L("popover.pace.expected_tooltip", Int(pace.expectedUsedPercent.rounded())),
            runsOutBeforeReset: pace.projectedRunOut != nil)
    }

    /// Percent left at the reset if the observed burn rate holds (0–100). Linear: the use observed so
    /// far, scaled by window length over elapsed time (`actual × 100 / expected`).
    static func projectedLeftAtReset(for pace: UsagePace) -> Int {
        guard pace.expectedUsedPercent > 0 else { return Int(pace.percentRemaining.rounded()) }
        let projectedUse = pace.actualUsedPercent * 100 / pace.expectedUsedPercent
        return Int(max(0, min(100, 100 - projectedUse)).rounded())
    }

    /// `"Thu 11h"` — localized short weekday plus the hour of `date`.
    static func dayHour(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = L("popover.weekday.\(parts.weekday ?? 1)")
        return L("popover.pace.day_hour", weekday, parts.hour ?? 0)
    }

    private static func primaryLabel(for pace: UsagePace, calendar: Calendar) -> String {
        if let runOut = pace.projectedRunOut {
            return L("popover.pace.runs_out_at", self.dayHour(runOut, calendar: calendar))
        }
        return L("popover.pace.left_at_reset", self.projectedLeftAtReset(for: pace))
    }

    private static func secondaryLabel(for pace: UsagePace, now: Date) -> String? {
        if pace.lastsUntilReset {
            return L("popover.pace.lasts_until_reset")
        }
        guard let runOut = pace.projectedRunOut else { return nil }
        let remaining = runOut.timeIntervalSince(now)
        if remaining <= 0 {
            return L("popover.pace.runs_out_now")
        }
        return L("popover.pace.runs_out_in", self.durationText(seconds: remaining))
    }

    /// Format a positive interval as `"Xd Yh"`, dropping a zero day component when under a day and
    /// falling back to `"now"` for sub-minute intervals. Matches AC13 wording (`Runs out in Xd Yh`).
    static func durationText(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return L("popover.pace.duration_now") }

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 {
            return L("popover.pace.duration_days_hours", days, hours)
        }
        if hours > 0 {
            return L("popover.pace.duration_hours_minutes", hours, minutes)
        }
        return L("popover.pace.duration_minutes", minutes)
    }
}
