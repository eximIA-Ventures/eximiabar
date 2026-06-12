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
    /// The window's frosted backing. Held so `applyTransparency(_:)` can swap the material live on the
    /// already-open window without recreating it (EXB-3.1 AC3).
    private var effectView: NSVisualEffectView?

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

        // EXB-3.1 AC2: a `.behindWindow` visual-effect background gives the Settings window the same
        // native macOS translucency as the popover. The material is `.underWindowBackground`, NOT the
        // EXB-2.1 `.windowBackground`: `.windowBackground` renders a near-solid surface on a floating
        // window by design (it is the material AppKit fills a standard window's content with), which
        // the EXB-3.1 diagnosis confirmed as the cause of the opaque Settings result.
        // `.underWindowBackground` is the genuine blur-under-the-window material used by system
        // preference panels and adapts to Dark/Light with no colour branching. `.fullSizeContentView`
        // plus a transparent titlebar lets the blur extend under the title area;
        // `.followsWindowActiveState` dims the material when the window is in the background. The
        // SwiftUI panes embedded here use plain `ScrollView`/`VStack` roots with NO `.background`
        // modifier (audited — see Dev Notes), so the blur shows through unobstructed.
        window.titlebarAppearsTransparent = true
        // Title text is hidden so the `TabView`'s tab strip can sit in the titlebar band without
        // colliding with it; the traffic-light buttons stay visible. The window still carries the
        // title for the Window menu / accessibility.
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false

        let effectView = NSVisualEffectView()
        // EXB-3.1 AC2/AC3: seed the material from the persisted transparency level (`.opaque` →
        // `.underWindowBackground`, `.standard` → `.popover`, `.frosted` → `.hudWindow`).
        effectView.material = settings.transparencyLevel.material
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
        self.effectView = effectView

        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Transparency (EXB-3.1 AC3)

    /// Apply a new translucency level to the Settings window's frosted backing. Swaps
    /// `NSVisualEffectView.material` in place — no window recreation — so the change is visible the
    /// next frame even while the window is open. No-op until the window has been created once. Pure
    /// AppKit on the main thread (anti-freeze invariant: no I/O, no parse).
    func applyTransparency(_ level: TransparencyLevel) {
        self.effectView?.material = level.material
    }

    // MARK: - NSWindowDelegate (AC10)

    func windowWillClose(_ notification: Notification) {
        // AC10: revert to the agent activation policy so no Dock icon remains.
        NSApp.setActivationPolicy(.accessory)
        // Persist any in-flight settings change immediately (AC8 — survive restart).
        settings.flush()
    }
}
