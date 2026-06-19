import Foundation
import Testing
@testable import ClaudeBar

/// AC5 — `SettingsStore` packages the four "Menu Content" toggles (plus thresholds) as one
/// `MenuDisplayOptions` value and fires `onMenuContentChange` whenever any of them flips, so the
/// open popover card rebuilds live instead of only on the next open.
@MainActor
struct MenuDisplayOptionsTests {
    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "exb.menudisplay.\(UUID().uuidString)")!)
    }

    @Test
    func optionsReflectStoreProperties() {
        let settings = store()
        settings.showUsed = false
        settings.showAbsoluteReset = false
        settings.showWarningMarkers = false
        settings.workdayMarkers = .fiveDay
        settings.sessionThresholds = [70, 30]
        settings.weeklyThresholds = [60, 25]

        let options = settings.menuDisplayOptions
        #expect(options.showUsed == false)
        #expect(options.showAbsoluteReset == false)
        #expect(options.showWarningMarkers == false)
        #expect(options.workdayMarkers == .fiveDay)
        #expect(options.sessionThresholds == [70, 30])
        #expect(options.weeklyThresholds == [60, 25])
    }

    /// Each of the five "Menu Content" mutations fires the rebuild callback exactly once.
    @Test
    func togglingAnyMenuContentPrefFiresCallback() {
        let settings = store()
        var count = 0
        settings.onMenuContentChange = { count += 1 }

        settings.showUsed.toggle()
        settings.showAbsoluteReset.toggle()
        settings.showWarningMarkers.toggle()
        settings.workdayMarkers = .sevenDay
        settings.weeklyThresholds = [40, 10]

        #expect(count == 5)
    }

    @Test
    func defaultsMatchShippingExpectations() {
        let options = MenuDisplayOptions.default
        #expect(options.showUsed == true)
        #expect(options.showAbsoluteReset == true)
        #expect(options.showWarningMarkers == true)
        #expect(options.workdayMarkers == .off)
        #expect(options.sessionThresholds == [50, 20])
        #expect(options.weeklyThresholds == [50, 20])
    }
}
