import Foundation

/// Small formatting helpers for the popover card. The reference relied on `CodexBarCore`'s
/// `UsageFormatter`; exímIABar keeps a focused local helper so the popover has no hidden
/// dependency on reference-only formatting code.
enum PopoverFormatter {
    /// `"Resets HH:mm"` for a window's reset date, in the **local** time zone, honouring the
    /// system's 12h/24h preference (AC9 / T4). Returns `nil` when there is no reset date.
    static func resetText(for resetsAt: Date?, now: Date = .init(), calendar: Calendar = .current) -> String? {
        guard let resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.calendar = calendar
        // `jm` lets the system choose 12h vs 24h based on the user's locale/region preference.
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return "Resets \(formatter.string(from: resetsAt))"
    }

    /// `"Updated Xm ago"` for the header status line (AC7). Buckets seconds/minutes/hours/days.
    static func updatedText(from updatedAt: Date, now: Date = .init()) -> String {
        let interval = max(0, now.timeIntervalSince(updatedAt))
        if interval < 45 {
            return "Updated just now"
        }
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 {
            return "Updated \(max(1, minutes))m ago"
        }
        let hours = Int((interval / 3_600).rounded())
        if hours < 24 {
            return "Updated \(hours)h ago"
        }
        let days = Int((interval / 86_400).rounded())
        return "Updated \(days)d ago"
    }

    /// `"$222.00"` style currency for the extra-usage / cost lines (AC15/AC16).
    static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Compact token count: `"27K tokens"` / `"5.4M tokens"` (AC16).
    static func tokenCount(_ count: Int) -> String {
        let absCount = abs(count)
        if absCount >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if absCount >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
