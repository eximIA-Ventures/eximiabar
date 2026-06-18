import ClaudeBarCore
import Foundation

/// Builds the trailing text the status item shows next to the icon for the text-bearing
/// `MenuBarContent` cases (EXB-4.4 AC1): `percentRemaining`, `timeUntilReset`, `costToday`.
///
/// Pure value logic, no AppKit — so it is unit-testable and safe to call from the off-main render
/// task. Each builder returns `nil` when there is nothing meaningful to show (the caller then renders
/// the icon alone), never an empty or placeholder string.
enum MenuBarContentText {
    /// `"87%"` — the session window's remaining percentage (whole number). `nil` when no session.
    static func percentRemaining(session: RateWindow?) -> String? {
        guard let session else { return nil }
        let remaining = Int(min(100, max(0, session.remaining)).rounded())
        return "\(remaining)%"
    }

    /// `"$1.23"` — today's spend, two decimals. `nil` when no cost scan has run.
    static func costToday(cost: ProviderCost?) -> String? {
        guard let cost else { return nil }
        return String(format: "$%.2f", cost.today)
    }

    /// `"2h34"` / `"45min"` — time until the session window resets. `nil` when the reset time is
    /// unknown or already in the past.
    static func timeUntilReset(session: RateWindow?, now: Date = Date()) -> String? {
        guard let resetsAt = session?.resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return formatTimeUntilReset(seconds)
    }

    /// Format a duration in seconds as a compact `"2h34"` / `"45min"` string (story Dev Notes).
    static func formatTimeUntilReset(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 {
            // Zero-pad the minutes so "2h4" never reads as "2h40".
            return "\(hours)h\(mins < 10 ? "0" : "")\(mins)"
        }
        return "\(totalMinutes)min"
    }
}
