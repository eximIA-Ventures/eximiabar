import AppKit
import ClaudeBarCore
import SwiftUI

/// Owns the dropdown `NSPanel` (AC1–AC6, AC18, AC20, AC21).
///
/// Critical architecture decision: the dropdown is an **`NSPanel`, never an `NSMenu`** (Dev Notes).
/// An `NSMenu` measures and re-lays out an embedded SwiftUI hosting view synchronously inside the
/// menu-tracking run loop, which stalls the WindowServer. An `NSPanel` is outside that run loop:
/// AppKit never calls `fittingSize` / `layoutSubtreeIfNeeded` on it, so SwiftUI lays out its content
/// asynchronously with no stall.
///
/// The panel is created **once** and reused (show / hide). Its content is purely a function of the
/// `DisplaySnapshot` supplied by `AppState` (AC21); while it is open we observe the snapshot and
/// re-render the hosting view's root in place.
@MainActor
final class UsagePanelController: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let effectView: RoundedVisualEffectView
    /// macOS 26 Liquid Glass backing (EXB-3.5 AC1). Created lazily the first time a non-`.opaque`
    /// level is applied on macOS 26; `nil` on macOS < 26 and while `.opaque` is selected (the panel
    /// then falls back to `effectView` exactly as the EXB-3.1 path did). Typed as `NSView?` so the
    /// stored property needs no availability annotation; downcast under `#available` at use sites.
    private var glassBacking: NSView?
    private let hostingView: NSHostingView<UsageCardView>
    private let actions: UsageCardActions

    /// Supplies the current snapshot when the panel needs to (re)build its card.
    private let snapshotProvider: @MainActor () -> DisplaySnapshot?

    /// Supplies the current "Menu Content" display options when the panel (re)builds its card (AC5).
    private let optionsProvider: @MainActor () -> MenuDisplayOptions

    /// Live observation of `AppState.snapshot` while the panel is open.
    private var observationTask: Task<Void, Never>?

    /// `true` while the panel is on screen.
    private(set) var isOpen = false

    init(
        snapshotProvider: @escaping @MainActor () -> DisplaySnapshot?,
        actions: UsageCardActions,
        optionsProvider: @escaping @MainActor () -> MenuDisplayOptions = { .default },
        transparency: TransparencyLevel = .frosted)
    {
        self.snapshotProvider = snapshotProvider
        self.optionsProvider = optionsProvider
        self.actions = actions

        // AC1: nonactivating + titled style mask, status-bar level, buffered, deferred false.
        self.panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PopoverStyle.panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // EXB-3.1 AC1: a `.behindWindow` vibrant background that frosts the desktop content behind the
        // panel. The default material is `.hudWindow` (strong frost with a darkened backing) — the
        // EXB-2.1 `.popover` material composited nearly opaque on a free-floating `NSPanel` in Dark
        // mode, which the EXB-3.1 diagnosis confirmed as the root cause of the "still opaque" result.
        // The material is driven by `TransparencyLevel` (AC3) and re-applied live via
        // `applyTransparency(_:)` with no panel recreation. `blendingMode = .behindWindow` is explicit
        // so the blur samples the desktop, not the window's own backing. The rounded subclass clips
        // the card to `PopoverStyle.cornerRadius` so the corners are not square (EXB-2.1 AC4).
        self.effectView = RoundedVisualEffectView()
        self.effectView.material = transparency.material
        self.effectView.blendingMode = .behindWindow
        self.effectView.state = .active
        self.effectView.translatesAutoresizingMaskIntoConstraints = false

        // AC2: single hosting view wrapping the SwiftUI card.
        self.hostingView = NSHostingView(
            rootView: UsageCardView(snapshot: snapshotProvider(), actions: actions, options: optionsProvider()))
        self.hostingView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        self.configurePanel()
        self.assembleViewTree()
        // EXB-3.5 AC1: on macOS 26 adopt the native Liquid Glass backing for the seeded level. On
        // macOS < 26 this is a no-op and the EXB-3.1 `effectView` path stays in place.
        self.applyTransparency(transparency)
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Setup

    private func configurePanel() {
        self.panel.level = .statusBar + 1 // AC1
        self.panel.isFloatingPanel = true
        self.panel.hidesOnDeactivate = false
        self.panel.becomesKeyOnlyIfNeeded = false
        self.panel.isMovable = false
        self.panel.titleVisibility = .hidden
        self.panel.titlebarAppearsTransparent = true
        self.panel.standardWindowButton(.closeButton)?.isHidden = true
        self.panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.panel.standardWindowButton(.zoomButton)?.isHidden = true
        self.panel.isOpaque = false
        self.panel.backgroundColor = .clear
        self.panel.hasShadow = true
        self.panel.acceptsMouseMovedEvents = true // AC18: needed for key event handling.
        self.panel.delegate = self
        self.panel.animationBehavior = .none // AC6/AC20: no open/close animation.

        // Keyboard shortcuts forwarded to the action handlers (AC18).
        self.panel.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        self.panel.onEscape = { [weak self] in
            self?.close()
        }
    }

    private func assembleViewTree() {
        // EXB-2.1 AC1: the `NSVisualEffectView` is the panel's content view; the `NSHostingView` is its
        // child (never a sibling or replacement), pinned to all edges so SwiftUI drives the height
        // (AC2 — never call `fittingSize` synchronously). The architecture stays an `NSPanel` (AC7).
        self.panel.contentView = self.effectView
        self.effectView.addSubview(self.hostingView)
        NSLayoutConstraint.activate([
            self.hostingView.leadingAnchor.constraint(equalTo: self.effectView.leadingAnchor),
            self.hostingView.trailingAnchor.constraint(equalTo: self.effectView.trailingAnchor),
            self.hostingView.topAnchor.constraint(equalTo: self.effectView.topAnchor),
            self.hostingView.bottomAnchor.constraint(equalTo: self.effectView.bottomAnchor),
        ])
    }

    // MARK: - Show / hide (AC5, AC6, AC20)

    /// Toggle the panel relative to the status item button.
    func toggle(near button: NSStatusBarButton) {
        if self.isOpen {
            self.close()
        } else {
            self.show(near: button)
        }
    }

    /// Show the panel anchored to the status-item button and trigger a user-initiated refresh.
    func show(near button: NSStatusBarButton) {
        guard !self.isOpen else { return }

        // Rebuild the card from the freshest snapshot before showing (AC21).
        self.rebuildCard()

        self.position(near: button)
        self.panel.makeKeyAndOrderFront(nil) // AC18: panel becomes key to accept ⌘R/⌘,/⌘Q.
        self.isOpen = true

        // AC6: opening triggers a user-initiated refresh (delegated through the actions set).
        self.actions.refresh()

        // Re-anchor after the async SwiftUI layout settles the real height (AC2/AC20): never call
        // `fittingSize` synchronously — instead re-read the frame on the next runloop tick.
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button, self.isOpen else { return }
            self.position(near: button)
        }

        self.startObserving()
    }

    /// Hide the panel without animation (AC6/AC20).
    func close() {
        guard self.isOpen else { return }
        self.isOpen = false
        self.observationTask?.cancel()
        self.observationTask = nil
        self.panel.orderOut(nil)
    }

    // MARK: - Transparency (EXB-3.1 AC3 / EXB-3.5 AC1)

    /// Apply a new translucency level to the live panel.
    ///
    /// **macOS < 26 (EXB-3.1 path, unchanged):** swap `NSVisualEffectView.material` in place — settable
    /// at any time, so the frost changes the next frame even while the panel is open.
    ///
    /// **macOS 26 (EXB-3.5 AC1):** for `.standard`/`.frosted`, install (or update) an
    /// `NSGlassEffectView` as the panel's content view with the `hostingView` as its `contentView` and
    /// the mapped `style`; for `.opaque` there is no glass, so fall back to the same
    /// `NSVisualEffectView(.underWindowBackground)` surface the EXB-3.1 path uses (AC4 — `.opaque`
    /// stays a near-solid background on both OS versions).
    ///
    /// Pure AppKit on the main thread (anti-freeze invariant: no I/O, no parse).
    func applyTransparency(_ level: TransparencyLevel) {
        if #available(macOS 26.0, *) {
            self.applyGlassTransparency(level)
        } else {
            self.effectView.material = level.material
        }
    }

    /// macOS 26 glass swap (EXB-3.5 AC1/AC4). Routes `.opaque` to the legacy effect view and
    /// `.standard`/`.frosted` to the Liquid Glass backing, re-parenting `hostingView` as needed.
    @available(macOS 26.0, *)
    private func applyGlassTransparency(_ level: TransparencyLevel) {
        guard let style = level.glassStyle else {
            // `.opaque` (AC4): no glass — show the near-solid `NSVisualEffectView` exactly as < 26 does.
            self.installEffectViewBacking(material: level.material)
            return
        }
        self.installGlassBacking(cornerRadius: PopoverStyle.cornerRadius, style: style)
    }

    /// Make the legacy `effectView` the panel's content view (with the `hostingView` re-pinned to its
    /// edges), used on macOS < 26 always and for `.opaque` on macOS 26.
    private func installEffectViewBacking(material: NSVisualEffectView.Material) {
        self.effectView.material = material
        guard self.panel.contentView !== self.effectView else { return }
        self.glassBacking = nil
        self.attachHostingViewWithConstraints(to: self.effectView)
        self.panel.contentView = self.effectView
    }

    /// Make an `NSGlassEffectView` the panel's content view, creating it on first use and re-parenting
    /// the `hostingView` as its `contentView` (the only SDK-guaranteed in-glass placement). Reuses the
    /// existing glass view on subsequent calls — a style change is a single property set.
    @available(macOS 26.0, *)
    private func installGlassBacking(cornerRadius: CGFloat, style: NSGlassEffectView.Style) {
        if let existing = self.glassBacking as? NSGlassEffectView {
            // A style change is a single property set; the glass keeps sizing itself to the host.
            existing.style = style
            if existing.contentView !== self.hostingView {
                self.detachHostingView()
                self.hostingView.translatesAutoresizingMaskIntoConstraints = false
                existing.contentView = self.hostingView
            }
            if self.panel.contentView !== existing { self.panel.contentView = existing }
            return
        }
        self.detachHostingView()
        // CRITICAL (verified by runtime probe on macOS 26.3): keep
        // `translatesAutoresizingMaskIntoConstraints = false` so the hosting view's Auto Layout
        // *fitting size* propagates up through the glass to the panel — `NSGlassEffectView` sizes
        // itself to its `contentView`'s fitting size exactly like the EXB-3.1 constraint chain, so the
        // panel still grows/shrinks with the SwiftUI card (AC2/AC20). Setting autoresizing here instead
        // would pin the panel at its seed height and clip the card.
        self.hostingView.translatesAutoresizingMaskIntoConstraints = false
        let glassView = GlassEffectBridge.makeGlassView(
            contentView: self.hostingView,
            cornerRadius: cornerRadius,
            style: style)
        self.glassBacking = glassView
        self.panel.contentView = glassView
    }

    /// Remove `hostingView` from whatever parent currently holds it so it can be re-installed.
    private func detachHostingView() {
        self.hostingView.removeFromSuperview()
    }

    /// Re-install `hostingView` inside `container` pinned to all edges (the EXB-3.1 layout).
    private func attachHostingViewWithConstraints(to container: NSView) {
        guard self.hostingView.superview !== container else { return }
        self.detachHostingView()
        self.hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self.hostingView)
        NSLayoutConstraint.activate([
            self.hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            self.hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            self.hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            self.hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Positioning (Dev Notes)

    /// Anchor the panel's top-right under the status-item button, clamped to the screen (Dev Notes).
    private func position(near button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrameInWindow)

        let panelSize = self.panel.frame.size
        var originX = screenFrame.maxX - panelSize.width
        let originY = screenFrame.minY - panelSize.height

        // Clamp within the visible screen so a status item near the right edge isn't clipped.
        if let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame {
            let maxX = visible.maxX - panelSize.width
            originX = min(max(originX, visible.minX), max(visible.minX, maxX))
        }

        self.panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - Live observation (AC21)

    private func rebuildCard() {
        self.hostingView.rootView = UsageCardView(
            snapshot: self.snapshotProvider(), actions: self.actions, options: self.optionsProvider())
    }

    /// Rebuild the card so a "Menu Content" preference change (AC5) is reflected immediately while the
    /// panel is open. Cheap and idempotent when closed (the next open rebuilds the card anyway).
    func reflectMenuContentChange() {
        self.rebuildCard()
    }

    /// Observe `AppState.snapshot` while the panel is open so the card reflects refreshes live.
    private func startObserving() {
        self.observationTask?.cancel()
        self.observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isOpen else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.snapshotProvider()
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, self.isOpen else { return }
                self.rebuildCard()
            }
        }
    }

    // MARK: - Keyboard (AC18)

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            self.actions.refresh()
            return true
        case "d":
            // EXB-2.3 AC1: ⌘D opens the local dashboard window.
            self.actions.openLocalDashboard()
            return true
        case ",":
            self.actions.openSettings()
            return true
        case "q":
            self.actions.quit()
            return true
        default:
            return false
        }
    }

    // MARK: - NSWindowDelegate (AC5)

    /// Close on resign key (click outside / focus loss) — AC5.
    func windowDidResignKey(_ notification: Notification) {
        self.close()
    }
}

/// An `NSPanel` subclass that can become key (so it accepts keyboard shortcuts, AC18) without
/// activating the app, and routes Escape / ⌘-key events to the controller.
private final class KeyablePanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Escape key (AC5).
        self.onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        // Escape has keyCode 53; route it explicitly in case `cancelOperation` isn't invoked.
        if event.keyCode == 53 {
            self.onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if self.onKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// An `NSVisualEffectView` that clips itself (and therefore the frosted material) to a rounded
/// rectangle (EXB-2.1 AC4).
///
/// The `.popover` material does not bring its own corner radius the way `.menu` does inside an
/// `NSMenu`, so a free-floating panel would otherwise show hard square corners. The mask is rebuilt
/// from the live bounds in `layout()` because the panel's height is driven asynchronously by the
/// SwiftUI hosting view (AC2) — a static mask would be the wrong size on the first frame. Building
/// the mask is pure CoreGraphics on the main thread with no I/O, so the anti-freeze invariants hold.
private final class RoundedVisualEffectView: NSVisualEffectView {
    override func layout() {
        super.layout()
        // A 9-slice resizable mask stretches to the view's current bounds automatically, so it only
        // needs to be (re)built when the radius could change — but rebuilding here is cheap and keeps
        // the mask correct after an appearance change. AppKit resizes the mask to `bounds` itself.
        if self.maskImage == nil {
            self.maskImage = Self.roundedMask(cornerRadius: PopoverStyle.cornerRadius)
        }
    }

    /// A resizable mask image with a rounded-rectangle cap inset of `cornerRadius` on every edge, so
    /// the corners curve while the straight runs stretch (`NSImage.resizingMode = .stretch`).
    private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
