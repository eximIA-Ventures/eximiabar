import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for launch-at-login control (AC9, macOS 13+).
///
/// `register()` / `unregister()` are synchronous but cheap (they touch a launchd plist, not the
/// network), so calling them from the main actor on a toggle flip is fine — no anti-freeze concern.
@MainActor
final class LaunchAtLoginManager {
    /// Enable or disable launching exímIABar at login (AC9).
    /// Throws if `SMAppService` rejects the request (e.g. the user disabled the login item in
    /// System Settings and macOS requires manual re-enablement).
    func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Whether the app is currently registered to launch at login (AC9).
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
