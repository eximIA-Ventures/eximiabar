import AppKit
import SwiftUI

/// Owns the settings `NSWindow` and performs the LSUIElement activation-policy dance (AC10).
///
/// exímIABar runs as an `.accessory` agent (no Dock icon). To bring a real window to the front it
/// must temporarily become `.regular`; on close it reverts to `.accessory` so no Dock icon lingers
/// (AC10). The window is 546×638 pt, non-resizable (AC1).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let launchManager: LaunchAtLoginManager
    private var window: NSWindow?

    init(settings: SettingsStore, launchManager: LaunchAtLoginManager) {
        self.settings = settings
        self.launchManager = launchManager
    }

    /// Show the settings window, creating it on first use. Brings the app forward (AC10).
    func open() {
        // AC10: become a regular app so the window can come to the front, then activate.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let root = SettingsRootView(settings: settings, launchManager: launchManager)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "exímIABar Settings"
        // AC1: fixed 546×638 pt; not resizable.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 546, height: 638))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate (AC10)

    func windowWillClose(_ notification: Notification) {
        // AC10: revert to the agent activation policy so no Dock icon remains.
        NSApp.setActivationPolicy(.accessory)
        // Persist any in-flight settings change immediately (AC8 — survive restart).
        settings.flush()
    }
}
