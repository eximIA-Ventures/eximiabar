import AppKit
import ClaudeBarCore
import SwiftUI

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

/// Wires the status item to app state on launch.
///
/// For EXB-1.2 the `AppState` is seeded with a mock snapshot so the icon is visible and exercises
/// the proportional-fill / stale logic end to end. The live refresh loop that feeds real snapshots
/// lands in EXB-1.4.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let appState = AppState()
    private var statusItemController: StatusItemController?
    private var observationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: enforce the agent activation policy even if `Info.plist` is missed
        // (e.g. running the bare executable during development).
        NSApp.setActivationPolicy(.accessory)

        let controller = StatusItemController(settings: settings)
        statusItemController = controller

        // Click hook — popover (NSPanel) implementation lands in EXB-1.3.
        controller.onClick = { [weak self] in
            self?.handleStatusItemClick()
        }

        // Seed a mock snapshot so the icon renders immediately (EXB-1.4 replaces this with the
        // real refresh loop). 87.5% session remaining, 60% weekly remaining.
        appState.snapshot = DisplaySnapshot(
            session: RateWindow(utilization: 12.5, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 40, resetsAt: nil, windowMinutes: 10080),
            pace: nil,
            isStale: false,
            hasError: false,
            updatedAt: Date())

        // Observe `AppState.snapshot` and push every change to the status item. Uses the
        // `@Observable` change-tracking loop; each iteration re-registers via `withObservationTracking`.
        controller.update(snapshot: appState.snapshot)
        startObserving(controller: controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationTask?.cancel()
    }

    private func startObserving(controller: StatusItemController) {
        observationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                // Suspend until `snapshot` changes, then re-render.
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

    private func handleStatusItemClick() {
        // Hook only — popover presentation arrives in EXB-1.3.
    }
}
