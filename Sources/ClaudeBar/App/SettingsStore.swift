import Foundation

/// How the status item presents usage in the menu bar.
enum DisplayMode: Sendable, Equatable {
    /// F1 — the two-bar crab meter icon.
    case meterIcon
    /// F2 — the Claude brand SVG plus a percentage / pace string.
    case brandIconPercent
}

/// Lightweight settings holder.
///
/// This is a **stub** for EXB-1.2: it only exposes the `displayMode` the status item needs.
/// The full settings surface (launch-at-login, keychain prompt policy, panes, persistence to
/// `UserDefaults`) is implemented in EXB-1.5. Marked `@MainActor` because the UI reads it on the
/// main thread; values are plain Sendable enums so reading them off-main (if ever needed) is safe.
@MainActor
final class SettingsStore {
    /// Active display mode. Defaults to the meter icon (F1).
    var displayMode: DisplayMode = .meterIcon

    init(displayMode: DisplayMode = .meterIcon) {
        self.displayMode = displayMode
    }
}
