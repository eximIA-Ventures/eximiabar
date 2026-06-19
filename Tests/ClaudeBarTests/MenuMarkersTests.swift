import Foundation
import Testing
@testable import ClaudeBar

/// AC5 — bar marker geometry: warning dashes (which flip with `showUsed`) and the weekly workday
/// pace dashes. Pure and stateless; pins the contract the popover relies on. Ported semantics from
/// the reference `MenuCardQuotaWarningMarkers`.
struct MenuMarkersTests {
    // MARK: - Warning markers flip with consumed/remaining

    /// `showUsed == false` → bar shows remaining → a "50% remaining" threshold sits at 50.
    @Test
    func warningMarkersOnRemainingBarUseThresholdDirectly() {
        #expect(MenuMarkers.warningMarkerPercents(thresholds: [50, 20], showUsed: false) == [50, 20])
    }

    /// `showUsed == true` → bar shows consumed → "50% remaining" sits at `100-50`, "20%" at `100-20`.
    @Test
    func warningMarkersOnConsumedBarInvertThreshold() {
        #expect(MenuMarkers.warningMarkerPercents(thresholds: [50, 20], showUsed: true) == [50, 80])
    }

    /// Edge thresholds (0 / 100) would sit on the bar's ends → dropped, in both fill directions.
    @Test
    func warningMarkersDropEdgeValues() {
        #expect(MenuMarkers.warningMarkerPercents(thresholds: [0, 100, 50], showUsed: false) == [50])
        #expect(MenuMarkers.warningMarkerPercents(thresholds: [0, 100], showUsed: true) == [])
    }

    @Test
    func warningMarkersEmptyForNoThresholds() {
        #expect(MenuMarkers.warningMarkerPercents(thresholds: [], showUsed: true) == [])
    }

    // MARK: - Workday markers: weekly only, evenly spaced

    @Test
    func workdayMarkersFiveDaySpacing() {
        #expect(MenuMarkers.workdayMarkerPercents(workDays: 5, isWeekly: true) == [20, 40, 60, 80])
    }

    @Test
    func workdayMarkersSevenDaySpacing() {
        let markers = MenuMarkers.workdayMarkerPercents(workDays: 7, isWeekly: true)
        #expect(markers.count == 6)
        #expect(abs(markers[0] - 100.0 / 7.0) < 1e-9)
        #expect(abs(markers[5] - 600.0 / 7.0) < 1e-9)
    }

    @Test
    func workdayMarkersOffOrNonWeeklyOrOutOfRangeAreEmpty() {
        #expect(MenuMarkers.workdayMarkerPercents(workDays: nil, isWeekly: true) == [])
        #expect(MenuMarkers.workdayMarkerPercents(workDays: 5, isWeekly: false) == [])
        #expect(MenuMarkers.workdayMarkerPercents(workDays: 1, isWeekly: true) == [])
        #expect(MenuMarkers.workdayMarkerPercents(workDays: 8, isWeekly: true) == [])
    }

    // MARK: - Merge of warning + workday

    /// Turning warning markers off still leaves the workday pace dashes on the weekly bar.
    @Test
    func mergeHidesWarningWhenToggledOffButKeepsWorkday() {
        let merged = MenuMarkers.markerPercents(
            thresholds: [50, 20], showWarningMarkers: false, showUsed: true,
            workdayMarkers: .fiveDay, isWeekly: true)
        #expect(merged == [20, 40, 60, 80])
    }

    /// On the weekly bar both sets draw, merged and sorted left→right. Consumed bar warnings are
    /// `[50, 80]`; five-day workday is `[20, 40, 60, 80]`.
    @Test
    func mergeSortsWarningAndWorkdayTogether() {
        let merged = MenuMarkers.markerPercents(
            thresholds: [50, 20], showWarningMarkers: true, showUsed: true,
            workdayMarkers: .fiveDay, isWeekly: true)
        #expect(merged == [20, 40, 50, 60, 80, 80])
        #expect(merged == merged.sorted())
    }

    /// Off the weekly bar the workday dashes are suppressed; only the warning dashes remain.
    @Test
    func mergeWarningOnlyWhenNotWeekly() {
        let merged = MenuMarkers.markerPercents(
            thresholds: [50, 20], showWarningMarkers: true, showUsed: false,
            workdayMarkers: .fiveDay, isWeekly: false)
        #expect(merged == [50, 20])
    }
}
