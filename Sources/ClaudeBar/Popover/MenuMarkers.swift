import Foundation

/// Pure geometry for the vertical dash markers drawn on the usage bars (AC5). Ported from
/// `_reference_codexbar/Sources/CodexBar/MenuCardQuotaWarningMarkers.swift`.
///
/// Two kinds of dashes share `UsageProgressBar.warningMarkerPercents`:
/// - **warning markers** at the configured quota thresholds, and
/// - **workday (pace) markers** evenly spaced across the weekly bar.
///
/// Positions are a percent of bar WIDTH (0…100), matching the fill that runs left→right. Because the
/// fill flips with `showUsed` (consumed vs remaining), the warning thresholds — stored as
/// percent-remaining — flip with it.
///
/// Stateless `static` functions: safe to call from a chart `body` (anti-freeze invariant).
enum MenuMarkers {
    /// Threshold dashes for one window. `thresholds` are percent-REMAINING (e.g. `[50, 20]`); on a
    /// consumed bar (`showUsed`) each maps to `100 - t`, otherwise to `t`. Edge values (≤0 or ≥100)
    /// are dropped so a dash never sits on the bar's edge.
    static func warningMarkerPercents(thresholds: [Int], showUsed: Bool) -> [Double] {
        thresholds
            .map { showUsed ? 100 - Double($0) : Double($0) }
            .filter { $0 > 0 && $0 < 100 }
    }

    /// Pace markers for the weekly bar only. For `workDays` in 2…7, draws a dash at the end of each
    /// elapsed workday: `day * 100 / workDays` for `day` in `1..<workDays`. Returns `[]` when off
    /// (`workDays == nil`), out of range, or the row is not the weekly one.
    static func workdayMarkerPercents(workDays: Int?, isWeekly: Bool) -> [Double] {
        guard isWeekly, let wd = workDays, wd >= 2, wd <= 7 else { return [] }
        return (1 ..< wd).map { Double($0) * 100.0 / Double(wd) }
    }

    /// The merged marker set for a single bar: warning dashes (when `showWarningMarkers`) plus the
    /// weekly workday dashes (when a workday count is set and this is the weekly row). When workday
    /// markers are present the union is sorted so the dashes render left→right.
    static func markerPercents(
        thresholds: [Int],
        showWarningMarkers: Bool,
        showUsed: Bool,
        workdayMarkers: WorkdayMarkers,
        isWeekly: Bool) -> [Double]
    {
        let warning = showWarningMarkers
            ? self.warningMarkerPercents(thresholds: thresholds, showUsed: showUsed)
            : []
        let workday = self.workdayMarkerPercents(workDays: workdayMarkers.days, isWeekly: isWeekly)
        let merged = warning + workday
        return workday.isEmpty ? merged : merged.sorted()
    }
}
