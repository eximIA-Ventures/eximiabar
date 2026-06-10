import Foundation

/// How the status item presents usage in the menu bar.
enum DisplayMode: Sendable, Equatable {
    /// F1 — the two-bar crab meter icon.
    case meterIcon
    /// F2 — the Claude brand SVG plus a percentage / pace string.
    case brandIconPercent
}

/// Refresh timer cadence (AC7). The full `SettingsStore` with `UserDefaults` persistence and the
/// settings panes lands in EXB-1.5; here it is a stub that drives the `AppState` refresh loop.
enum RefreshCadence: String, Sendable, Equatable, CaseIterable {
    case manual
    case min1
    case min2
    case min5
    case min15
    case min30

    /// Interval in seconds. `manual` is `0` — the loop then idles until a user/startup trigger.
    var intervalSeconds: Double {
        switch self {
        case .manual: 0
        case .min1: 60
        case .min2: 120
        case .min5: 300
        case .min15: 900
        case .min30: 1800
        }
    }
}

/// Lightweight settings holder.
///
/// **Stub** (EXB-1.2 / EXB-1.4): exposes the `displayMode` the status item needs plus the
/// `refreshCadence` and notification toggles the EXB-1.4 refresh loop and `QuotaNotifier`
/// consume. The full settings surface (launch-at-login, keychain prompt policy, panes,
/// persistence to `UserDefaults`) is implemented in EXB-1.5.
///
/// Marked `@MainActor` because the UI reads it on the main thread; values are plain Sendable
/// enums / structs so reading them off-main (if ever needed) is safe.
@MainActor
final class SettingsStore {
    /// Active display mode. Defaults to the meter icon (F1).
    var displayMode: DisplayMode = .meterIcon

    /// Refresh timer cadence (AC7). Default 5 minutes. Changing this should cause `AppState`
    /// to cancel and restart its timer task.
    var refreshCadence: RefreshCadence = .min5 {
        didSet {
            guard refreshCadence != oldValue else { return }
            onRefreshCadenceChange?(refreshCadence)
        }
    }

    /// Quota-remaining thresholds (percent) that fire warning notifications (AC9c). Default `[50, 20]`.
    var quotaThresholds: [Int] = [50, 20]

    /// Whether `NSSound("Glass")` plays on a notification (AC10). Default off.
    var notificationSound: Bool = false

    /// Master switch for quota notifications. Default on.
    var notificationsEnabled: Bool = true

    /// Invoked when `refreshCadence` changes so the owner can restart the timer (AC14).
    var onRefreshCadenceChange: (@MainActor (RefreshCadence) -> Void)?

    init(displayMode: DisplayMode = .meterIcon, refreshCadence: RefreshCadence = .min5) {
        self.displayMode = displayMode
        self.refreshCadence = refreshCadence
    }

    /// Snapshot the notification-relevant settings into the value type `QuotaNotifier` consumes.
    var notificationSettings: NotificationSettings {
        NotificationSettings(
            thresholds: quotaThresholds,
            soundEnabled: notificationSound,
            enabled: notificationsEnabled)
    }
}
