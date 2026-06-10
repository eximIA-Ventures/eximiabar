import Foundation

/// A single rate-limit window (e.g. the 5-hour session window or the 7-day weekly window).
///
/// `utilization` is the API value verbatim — a percentage in the range 0–100. It is NEVER
/// multiplied by 100. `remaining` is therefore `100 - utilization`.
public struct RateWindow: Sendable, Equatable {
    /// Percentage of the window consumed, 0–100 (used as-is from the API).
    public let utilization: Double
    /// When this window resets, if known.
    public let resetsAt: Date?
    /// Length of the window in minutes (session = 300, weekly = 10080).
    public let windowMinutes: Int

    public init(utilization: Double, resetsAt: Date?, windowMinutes: Int) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    /// Percentage remaining, 0–100.
    public var remaining: Double {
        100 - utilization
    }
}
