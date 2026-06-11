import ClaudeBarCore
import Foundation

/// Maps a `UsagePace` to the two pace lines shown under the Weekly bar (AC13).
///
/// Strings are the EXACT wording required by AC13 — ported from
/// `_reference_codexbar/Sources/CodexBar/UsagePaceText.swift:37-54`, NOT from the screenshot:
///
/// Left (primary):  `"On pace"` / `"N% in deficit"` / `"N% in reserve"`
/// Right (secondary): `"Lasts until reset"` / `"Runs out in Xd Yh"` / `"Runs out now"`
enum UsagePaceText {
    struct Detail {
        /// Primary line: the pace status (`On pace` / deficit / reserve).
        let primary: String
        /// Secondary line: the run-out projection, or `nil` when there is nothing to project.
        let secondary: String?
        /// The expected used percent — drives the bar's pace punch-out position.
        let pacePercent: Double
        /// `true` when the stripe should be green (reserve), `false` when red (deficit).
        let isReserve: Bool
    }

    /// Build the pace detail for a computed pace, or `nil` when there is no pace to show.
    static func detail(for pace: UsagePace, now: Date = .init()) -> Detail {
        Detail(
            primary: self.primaryLabel(for: pace),
            secondary: self.secondaryLabel(for: pace, now: now),
            pacePercent: pace.expectedUsedPercent,
            isReserve: pace.reserve > 0)
    }

    private static func primaryLabel(for pace: UsagePace) -> String {
        switch pace.status {
        case .onPace:
            return L("popover.pace.on_pace")
        case let .deficit(value):
            return L("popover.pace.deficit", Int(abs(value).rounded()))
        case let .reserve(value):
            return L("popover.pace.reserve", Int(abs(value).rounded()))
        }
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
