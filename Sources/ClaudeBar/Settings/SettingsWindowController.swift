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
    /// The SwiftUI host. Held so the macOS 26 glass path can re-parent it between the effect view and
    /// the `NSGlassEffectView` when the transparency level changes (EXB-3.5 AC2).
    private var hostingView: NSView?
    /// macOS 26 Liquid Glass backing (EXB-3.5 AC2). `nil` on macOS < 26 and while `.opaque` is
    /// selected. Typed as `NSView?` so the stored property needs no availability annotation.
    private var glassBacking: NSView?

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
        self.hostingView = hostingView

        // EXB-3.5 AC2: on macOS 26 adopt the native Liquid Glass backing for the seeded level. On
        // macOS < 26 this is a no-op and the EXB-3.1 effect-view backing above stays in place.
        self.applyTransparency(settings.transparencyLevel)

        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Transparency (EXB-3.1 AC3 / EXB-3.5 AC2)

    /// Apply a new translucency level to the Settings window's backing.
    ///
    /// **macOS < 26 (EXB-3.1 path, unchanged):** swap `NSVisualEffectView.material` in place — no
    /// window recreation, so the change is visible the next frame even while the window is open.
    ///
    /// **macOS 26 (EXB-3.5 AC2):** install (or update) an `NSGlassEffectView` as the window's content
    /// view with the SwiftUI host as its `contentView`; `.opaque` falls back to the same
    /// `NSVisualEffectView(.underWindowBackground)` surface (AC4). `cornerRadius` is 0 — the titled
    /// window frame supplies the corners, so rounding the content view would clip against the frame.
    ///
    /// No-op until the window has been created once (`hostingView == nil`). Pure AppKit on the main
    /// thread (anti-freeze invariant: no I/O, no parse).
    func applyTransparency(_ level: TransparencyLevel) {
        guard let window, let hostingView else { return }
        if #available(macOS 26.0, *) {
            self.applyGlassTransparency(level, window: window, hostingView: hostingView)
        } else {
            self.effectView?.material = level.material
        }
    }

    @available(macOS 26.0, *)
    private func applyGlassTransparency(
        _ level: TransparencyLevel,
        window: NSWindow,
        hostingView: NSView)
    {
        guard let style = level.glassStyle else {
            // `.opaque` (AC4): restore the near-solid effect-view backing.
            self.installEffectViewBacking(window: window, hostingView: hostingView, material: level.material)
            return
        }
        if let existing = self.glassBacking as? NSGlassEffectView {
            existing.style = style
            if window.contentView !== existing { window.contentView = existing }
            return
        }
        hostingView.removeFromSuperview()
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        let glassView = GlassEffectBridge.makeGlassView(
            contentView: hostingView,
            cornerRadius: 0,
            style: style)
        glassView.frame = window.contentLayoutRect
        self.glassBacking = glassView
        window.contentView = glassView
    }

    /// Restore the legacy `NSVisualEffectView` backing (macOS 26 `.opaque` and as a re-attach helper).
    private func installEffectViewBacking(
        window: NSWindow,
        hostingView: NSView,
        material: NSVisualEffectView.Material)
    {
        guard let effectView else { return }
        effectView.material = material
        guard window.contentView !== effectView else { return }
        self.glassBacking = nil
        hostingView.removeFromSuperview()
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        window.contentView = effectView
    }

    // MARK: - NSWindowDelegate (AC10)

    func windowWillClose(_ notification: Notification) {
        // AC10: revert to the agent activation policy so no Dock icon remains.
        NSApp.setActivationPolicy(.accessory)
        // Persist any in-flight settings change immediately (AC8 — survive restart).
        settings.flush()
    }
}
