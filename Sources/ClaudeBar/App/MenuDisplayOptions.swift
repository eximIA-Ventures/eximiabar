import Foundation

/// The four "Menu Content" display preferences (AC5), resolved from `SettingsStore` into a single
/// immutable value the popover card renders from.
///
/// The EXB port shipped the preference UI (`PreferencesDisplayPane`) and the backing `SettingsStore`
/// fields, but never threaded any of them through to `UsageCardView` — so all four toggles persisted
/// their state and changed nothing on screen. This value type is the missing wire: `AppState` builds
/// it from the live store and hands it to the card on every (re)build.
///
/// Pure value semantics (`Equatable`, `Sendable`) so the card stays a function of its inputs.
struct MenuDisplayOptions: Sendable, Equatable {
    /// Bars fill with the consumed quota (`true`) or the remaining quota (`false`).
    var showUsed: Bool
    /// Reset line shows an absolute clock ("Renova 14:00", `true`) or a countdown
    /// ("Renova em 2h 15m", `false`).
    var showAbsoluteReset: Bool
    /// Draw the threshold dashes on the bars.
    var showWarningMarkers: Bool
    /// Pace markers on the weekly bar (off / 4 / 5 / 7 workdays).
    var workdayMarkers: WorkdayMarkers
    /// How the weekly pace / forecast is surfaced: stripe on the bar (`.bar`) or the
    /// "No ritmo atual…" text line (`.text`).
    var paceDisplayMode: PaceDisplayMode
    /// Session-window warning thresholds (percent remaining, e.g. `[50, 20]`).
    var sessionThresholds: [Int]
    /// Weekly-window warning thresholds (percent remaining, e.g. `[50, 20]`).
    var weeklyThresholds: [Int]
    /// The popover skin (v2.2.0): `.classic` terracotta or the opt-in `.meter` amber look.
    var popoverTheme: PopoverTheme

    init(
        showUsed: Bool = true,
        showAbsoluteReset: Bool = true,
        showWarningMarkers: Bool = true,
        workdayMarkers: WorkdayMarkers = .off,
        paceDisplayMode: PaceDisplayMode = .bar,
        sessionThresholds: [Int] = [50, 20],
        weeklyThresholds: [Int] = [50, 20],
        popoverTheme: PopoverTheme = .classic)
    {
        self.showUsed = showUsed
        self.showAbsoluteReset = showAbsoluteReset
        self.showWarningMarkers = showWarningMarkers
        self.workdayMarkers = workdayMarkers
        self.paceDisplayMode = paceDisplayMode
        self.sessionThresholds = sessionThresholds
        self.weeklyThresholds = weeklyThresholds
        self.popoverTheme = popoverTheme
    }

    /// The shipping defaults — consumed bars, absolute reset, markers on, no workday pace. Matches the
    /// `SettingsStore` property defaults so a card built before settings load looks correct.
    static let `default` = MenuDisplayOptions()
}
