import Foundation

/// The global period filter at the top of the analytics dashboard (EXB-3.2 AC1).
///
/// The raw value is the trailing-day window the scan covers. Changing the period re-derives the whole
/// dashboard (KPIs, charts, tables) from a `UsageAnalytics` scan for that window — the window
/// controller caches one `DashboardData` per period so a second selection of the same period does not
/// re-scan (AC12).
enum DashboardPeriod: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { self.rawValue }

    /// The number of trailing calendar days this period spans.
    var days: Int { self.rawValue }

    /// Localized segmented-control label (`"7d"` / `"30d"` / `"90d"`).
    var label: String {
        switch self {
        case .sevenDays: return L("dashboard.period.7d")
        case .thirtyDays: return L("dashboard.period.30d")
        case .ninetyDays: return L("dashboard.period.90d")
        }
    }

    /// Compact tag used in the CSV export filename suggestion (`"7d"` / `"30d"` / `"90d"`).
    var fileTag: String { "\(self.rawValue)d" }
}
