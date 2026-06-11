import AppKit
import ClaudeBarCore
import Observation
import SwiftUI

/// The `@Observable` state the dashboard window binds to (EXB-2.3 T3/T5).
///
/// The hosting view reads `state`; the controller flips it from `.loading` to a terminal state on
/// `@MainActor` once the off-main scan completes (AC8). Kept tiny and `@MainActor` so there is no
/// data race between the detached scan task and the SwiftUI render.
@MainActor
@Observable
final class DashboardModel {
    var state: DashboardState = .loading
}

/// Owns the local dashboard `NSWindow` (EXB-2.3 T2 / AC2/AC3).
///
/// Mirrors `SettingsWindowController`'s LSUIElement activation-policy dance: exímIABar runs as an
/// `.accessory` agent (no Dock icon), so to bring a real window forward it temporarily becomes
/// `.regular` and reverts to `.accessory` on close (AC10 of EXB-1.5). The window is a **standard
/// `NSWindow`**, not an `NSPanel` (AC2) — 480×600 pt minimum, resizable, titled.
///
/// Singleton hide/show: the window is created once and reused; `open()` brings it to the front and
/// kicks a fresh scan each time so the data is current (AC3 — opens instantly with a loading state).
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    /// Resolves the live cost-scan settings (`costEnabled` / `costDays`) — same source the menu-bar
    /// fetch uses (EXB-1.7). Read off-MainActor inside the detached scan task.
    private let costSettingsProvider: @Sendable () -> LiveUsageProvider.CostSettings
    /// The shared scanner. Reusing `.shared` means the dashboard reads the same incremental aggregate
    /// the menu-bar refresh already populated — no duplicate JSONL parsing (AC11).
    private let costScanner: CostScanner
    /// Opens the Settings window (AC9 "Open Settings" button target).
    private let openSettings: @MainActor () -> Void

    private let model = DashboardModel()
    private var window: NSWindow?
    private var scanTask: Task<Void, Never>?

    init(
        costSettingsProvider: @escaping @Sendable () -> LiveUsageProvider.CostSettings,
        costScanner: CostScanner = .shared,
        openSettings: @escaping @MainActor () -> Void)
    {
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.openSettings = openSettings
    }

    // MARK: - Open (AC2/AC3)

    /// Show the dashboard window (creating it on first use), bring the app forward, and kick a fresh
    /// off-main scan (AC8). Opens instantly in the loading state — no main-thread blocking (AC3).
    func open() {
        // Become a regular app so the window can come to the front, then activate (mirrors
        // `SettingsWindowController`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if window == nil {
            setupWindow()
        }
        // Reset to the loading skeleton before each open so a re-open shows fresh state (AC3).
        model.state = .loading
        window?.makeKeyAndOrderFront(nil)

        loadData()
    }

    private func setupWindow() {
        // Bind the hosting view to the observable model so a `state` flip re-renders `DashboardView`
        // in place — no `NSHostingView.rootView` reassignment.
        let hostingView = NSHostingView(rootView: DashboardRoot(model: model, openSettings: openSettings))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // AC2: standard NSWindow (NOT an NSPanel). 480×600 minimum, resizable, titled.
        let contentSize = NSSize(width: 480, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = L("dashboard.window.title")
        window.setContentSize(contentSize)
        window.minSize = NSSize(width: 480, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        window.contentView = hostingView
        self.window = window
    }

    // MARK: - Off-main data load (AC8/AC11)

    /// AC8: load entirely off the main thread via `Task.detached(priority: .utility)`, then post the
    /// result back to `@MainActor`. AC11: opening the dashboard never triggers a rate-limit API fetch —
    /// it only reads what `CostScanner` already computed.
    private func loadData() {
        // AC9: when cost tracking is off, skip the scan and show the disabled state immediately.
        let settings = costSettingsProvider()
        guard settings.enabled else {
            model.state = .disabled
            return
        }

        scanTask?.cancel()
        let scanner = costScanner
        let days = settings.days
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let cost = await scanner.scan(costDays: days)
            // Pure value transformation off-MainActor; `DashboardData` is `Sendable` so it crosses the
            // actor hop without a data race (the `@MainActor` model is never captured into this task).
            let data = DashboardData.build(from: cost, windowDays: days)
            guard !Task.isCancelled else { return }
            await self?.apply(data)
        }
    }

    /// Post the scanned data into the observable model on `@MainActor` (AC8).
    @MainActor
    private func apply(_ data: DashboardData) {
        model.state = data.isEmpty ? .empty : .loaded(data)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Cancel any in-flight scan and revert to the agent activation policy so no Dock icon lingers.
        scanTask?.cancel()
        scanTask = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Bridges the `@Observable` `DashboardModel` into a `DashboardView` so a `state` mutation re-renders
/// the hosted SwiftUI tree in place (no `NSHostingView.rootView` reassignment needed).
private struct DashboardRoot: View {
    @Bindable var model: DashboardModel
    let openSettings: @MainActor () -> Void

    var body: some View {
        DashboardView(state: model.state, openSettings: openSettings)
    }
}
