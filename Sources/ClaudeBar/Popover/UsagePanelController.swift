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
    private let effectView: NSVisualEffectView
    private let hostingView: NSHostingView<UsageCardView>
    private let actions: UsageCardActions

    /// Supplies the current snapshot when the panel needs to (re)build its card.
    private let snapshotProvider: @MainActor () -> DisplaySnapshot?

    /// Live observation of `AppState.snapshot` while the panel is open.
    private var observationTask: Task<Void, Never>?

    /// `true` while the panel is on screen.
    private(set) var isOpen = false

    init(
        snapshotProvider: @escaping @MainActor () -> DisplaySnapshot?,
        actions: UsageCardActions)
    {
        self.snapshotProvider = snapshotProvider
        self.actions = actions

        // AC1: nonactivating + titled style mask, status-bar level, buffered, deferred false.
        self.panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PopoverStyle.panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // AC3: vibrant background matching system menus.
        self.effectView = NSVisualEffectView()
        self.effectView.material = .menu
        self.effectView.blendingMode = .behindWindow
        self.effectView.state = .active
        self.effectView.translatesAutoresizingMaskIntoConstraints = false

        // AC2: single hosting view wrapping the SwiftUI card.
        self.hostingView = NSHostingView(rootView: UsageCardView(snapshot: snapshotProvider(), actions: actions))
        self.hostingView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        self.configurePanel()
        self.assembleViewTree()
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
        // AC3: NSVisualEffectView is the content view; the hosting view is its child, pinned to all
        // edges so SwiftUI drives the height (AC2 — never call `fittingSize` synchronously).
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
        self.hostingView.rootView = UsageCardView(snapshot: self.snapshotProvider(), actions: self.actions)
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
