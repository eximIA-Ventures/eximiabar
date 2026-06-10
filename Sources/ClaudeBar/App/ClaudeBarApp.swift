import AppKit
import ClaudeBarCore
import SwiftUI
import UserNotifications

/// Application entry point.
///
/// exímIABar is an `LSUIElement` agent (no Dock icon, no app menu — see `Info.plist`). It uses the
/// SwiftUI `App` lifecycle purely as a host: there is no main window. All UI lives in the menu-bar
/// status item, created by the `AppDelegate` in `applicationDidFinishLaunching`.
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window: the app is a menu-bar agent. `Settings` provides an (empty) scene so SwiftUI
        // has a valid `App` body; the real settings window arrives in EXB-1.5.
        Settings {
            EmptyView()
        }
    }
}

/// Wires the live refresh loop (EXB-1.4) to the status item on launch.
///
/// Lifecycle (AC6 / AC11 / T6):
///  1. Request notification authorization once (fire-and-forget).
///  2. Launch the watchdog helper if present (no-op if absent — S6).
///  3. Kick the startup refresh (`.startup` phase) and start the repeating timer.
///  4. Observe `AppState.snapshot` and push every change to the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let provider = LiveUsageProvider()
    private let notificationPoster = SystemNotificationPoster()
    private lazy var appState = AppState(
        fetch: provider.makeFetch(),
        settingsStore: settings,
        notifier: QuotaNotifier(poster: notificationPoster))
    private var statusItemController: StatusItemController?
    private var observationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: enforce the agent activation policy even if `Info.plist` is missed
        // (e.g. running the bare executable during development).
        NSApp.setActivationPolicy(.accessory)

        // AC11: request notification authorization once at launch — fire and forget.
        notificationPoster.requestAuthorizationOnStartup()

        let controller = StatusItemController(settings: settings)
        statusItemController = controller

        // Click hook — popover (NSPanel) implementation lands in EXB-1.3; trigger a user-initiated
        // refresh when the user opens it (AC6b).
        controller.onClick = { [weak self] in
            self?.appState.triggerRefresh(.userInitiated)
        }

        // AC12: launch the watchdog helper if it exists (no-op when S6 binary is absent).
        appState.launchWatchdogIfPresent()

        // Render the initial (empty) state, then start observing.
        controller.update(snapshot: appState.snapshot)
        startObserving(controller: controller)

        // AC6a + AC3: startup refresh, then start the repeating timer.
        appState.triggerRefresh(.startup)
        appState.startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationTask?.cancel()
        appState.stopRefreshTimer()
    }

    private func startObserving(controller: StatusItemController) {
        observationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                // Suspend until `snapshot` changes, then re-render. Each iteration re-registers via
                // `withObservationTracking` (one observable property → one re-render, AC2).
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.appState.snapshot
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                controller.update(snapshot: self.appState.snapshot)
            }
        }
    }
}
