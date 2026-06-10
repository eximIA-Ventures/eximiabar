import ClaudeBarCore
import Foundation

/// Builds the status-item title string for the F2 "brand icon + %" display mode (AC13).
///
/// Behaviour (per EXB-1.2 AC13, adapted from CodexBar's `MenuBarDisplayText`):
/// - Returns `" 87%"` — a leading space (separating it from the brand icon) followed by the
///   session **remaining** percentage, rounded to a whole number.
/// - When a positive `pace` is supplied, the percentage and the pace are joined with a middle dot:
///   `"87% · +5%"`. Note: this combined form carries no leading space, matching the AC literal.
/// - Returns `nil` when there is no session window to describe.
enum MenuBarDisplayText {
    /// - Parameters:
    ///   - session: the session window whose `remaining` percentage is shown.
    ///   - pace: pace delta in percentage points; only rendered when strictly greater than 0.
    static func displayText(session: RateWindow?, pace: Double?) -> String? {
        guard let session else { return nil }

        let remaining = Int(min(100, max(0, session.remaining)).rounded())

        if let pace, pace > 0 {
            let paceValue = Int(pace.rounded())
            return "\(remaining)% · +\(paceValue)%"
        }

        return " \(remaining)%"
    }
}
