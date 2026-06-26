import SwiftUI

/// The popover's selectable skin (v2.2.0).
///
/// `classic` is the shipping terracotta family; `meter` is the opt-in amber "eximIA Meter" look —
/// the healthy band turns amber and the plan badge / footer pick up the amber accent. It is a pure
/// colour swap layered on the same layout, so every screen keeps working unchanged when classic is
/// selected (the default). Persisted as its raw string in `UserDefaults` via `SettingsStore`.
enum PopoverTheme: String, Sendable, Equatable, CaseIterable, Identifiable {
    case classic
    case meter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: L("settings.display.theme.classic")
        case .meter: L("settings.display.theme.meter")
        }
    }
}

private struct PopoverThemeKey: EnvironmentKey {
    static let defaultValue: PopoverTheme = .classic
}

extension EnvironmentValues {
    /// The popover's selected skin, injected once by `UsageCardView` from `MenuDisplayOptions` so
    /// every descendant (metric rows, per-model rows, the header plan badge) reads it from the
    /// environment instead of threading it through every initializer.
    var popoverTheme: PopoverTheme {
        get { self[PopoverThemeKey.self] }
        set { self[PopoverThemeKey.self] = newValue }
    }
}
