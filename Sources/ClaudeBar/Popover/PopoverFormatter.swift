import Foundation

/// Small formatting helpers for the popover card. The reference relied on `CodexBarCore`'s
/// `UsageFormatter`; exímIABar keeps a focused local helper so the popover has no hidden
/// dependency on reference-only formatting code.
enum PopoverFormatter {
    /// The reset line for a window (AC5/AC9). `nil` when there is no reset date.
    ///
    /// - `absolute == true`  → `"Renova HH:mm"`, in the **local** time zone, honouring the system's
    ///   12h/24h preference (the original `jm` clock).
    /// - `absolute == false` → `"Renova em 2h 15m"`, a live countdown to the reset.
    ///
    /// `absolute` is driven by `SettingsStore.showAbsoluteReset` (the "Renovação como relógio"
    /// toggle); before AC5 was wired this argument did not exist and the bar always showed the clock.
    static func resetText(
        for resetsAt: Date?,
        absolute: Bool = true,
        now: Date = .init(),
        calendar: Calendar = .current) -> String?
    {
        guard let resetsAt else { return nil }
        if absolute {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.timeZone = .autoupdatingCurrent
            formatter.calendar = calendar
            // `jm` lets the system choose 12h vs 24h based on the user's locale/region preference.
            formatter.setLocalizedDateFormatFromTemplate("jm")
            return L("popover.resets", formatter.string(from: resetsAt))
        }
        return L("popover.resets_relative", resetCountdown(until: resetsAt, now: now))
    }

    /// The bare `"2h 15m"` / `"1d 3h"` / `"45m"` countdown fragment until `until`, floored at `"1m"`
    /// so a reset that is essentially now still reads as `"1m"` rather than `"0m"`. Split out so it is
    /// unit-testable in isolation and so the surrounding "Renova em …" sentence stays in the
    /// `.strings` table. Shows at most the two largest non-zero units (mirrors the reference).
    static func resetCountdown(until: Date, now: Date = .init()) -> String {
        let seconds = max(0, until.timeIntervalSince(now))
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// `"Updated Xm ago"` for the header status line (AC7). Buckets seconds/minutes/hours/days.
    static func updatedText(from updatedAt: Date, now: Date = .init()) -> String {
        let interval = max(0, now.timeIntervalSince(updatedAt))
        if interval < 45 {
            return L("popover.updated_just_now")
        }
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 {
            return L("popover.updated_minutes_ago", max(1, minutes))
        }
        let hours = Int((interval / 3_600).rounded())
        if hours < 24 {
            return L("popover.updated_hours_ago", hours)
        }
        let days = Int((interval / 86_400).rounded())
        return L("popover.updated_days_ago", days)
    }

    /// `"$222.00"` style currency for the extra-usage / cost lines (AC15/AC16).
    static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// The full localized forecast line for a window (EXB-4.3 AC4 §12), e.g.
    /// `"At current pace, runs out in ~2h 15m"` / `"…~45min"`. Returns `nil` when there is no honest
    /// forecast (`minutesRemaining == nil`), so the caller renders nothing — no empty line (AC4 §13).
    ///
    /// - `< 1h`  → `"~Xmin"` (rounded to the nearest minute, floored at 1 so it never shows `~0min`).
    /// - `>= 1h` → `"~Xh Ym"`.
    static func forecastText(minutesRemaining: Double?) -> String? {
        guard let minutes = minutesRemaining, minutes.isFinite, minutes >= 0 else { return nil }
        return L("popover.forecast.line", forecastDuration(minutes: minutes))
    }

    /// The bare `~Xh Ym` / `~Xmin` duration fragment used inside the forecast line. Split out so it is
    /// unit-testable in isolation and so the surrounding sentence stays in the `.strings` table.
    static func forecastDuration(minutes: Double) -> String {
        let totalMinutes = max(1, Int(minutes.rounded()))
        if totalMinutes < 60 {
            return L("popover.forecast.minutes", totalMinutes)
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return L("popover.forecast.hours_minutes", hours, mins)
    }

    /// Compact token count: `"27K"` / `"5.4M"` / `"4.9B"` (AC16; EXB-3.7 AC7 adds the billions
    /// threshold so huge cache-token totals read as `"4.9B"`, never `"4888.6M"` or scientific notation).
    static func tokenCount(_ count: Int) -> String {
        let absCount = abs(count)
        if absCount >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if absCount >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if absCount >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
