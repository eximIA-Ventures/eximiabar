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
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // AC1: 546 pt wide; the height is the designed 638 pt pane area plus a 28 pt titlebar band
        // reserved by `SettingsRootView` so the tab strip clears the traffic lights under
        // `.fullSizeContentView` (EXB-2.1 AC2). Not resizable.
        let contentSize = NSSize(width: 546, height: 638 + 28)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L("settings.window.title")
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.delegate = self

        // EXB-2.1 AC2: a `.behindWindow` visual-effect background gives the Settings window the same
        // native macOS translucency as the popover. `.fullSizeContentView` plus a transparent
        // titlebar lets the blur extend under the title area; `.followsWindowActiveState` dims the
        // material when the window is in the background, matching system preference panels. The
        // material adapts to Dark/Light automatically with no colour branching (AC3).
        window.titlebarAppearsTransparent = true
        // Title text is hidden so the `TabView`'s tab strip can sit in the titlebar band without
        // colliding with it; the traffic-light buttons stay visible. The window still carries the
        // title for the Window menu / accessibility.
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false

        let effectView = NSVisualEffectView()
        effectView.material = .windowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        window.contentView = effectView

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
