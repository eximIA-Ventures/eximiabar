import AppKit
import ClaudeBarCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The `@Observable` state the dashboard window binds to (EXB-2.3 / EXB-3.2).
///
/// The hosting view reads `state` and `period`; the controller flips `state` from `.loading` to a
/// terminal state on `@MainActor` once the off-main scan completes. Kept tiny and `@MainActor` so
/// there is no data race between the detached scan task and the SwiftUI render.
@MainActor
@Observable
final class DashboardModel {
    var state: DashboardState = .loading
    /// The currently-selected period filter (AC1). Mutating it requests a (cached) reload.
    var period: DashboardPeriod = .thirtyDays
    /// Invoked when the segmented control changes the period (wired by the controller, AC1).
    var onPeriodChange: (@MainActor (DashboardPeriod) -> Void)?
    /// Invoked by the "Export CSV" button (wired by the controller, AC9).
    var onExportCSV: (@MainActor () -> Void)?

    func selectPeriod(_ period: DashboardPeriod) {
        guard period != self.period else { return }
        self.period = period
        self.onPeriodChange?(period)
    }
}

/// Owns the local analytics dashboard `NSWindow` (EXB-2.3 / EXB-3.2).
///
/// Mirrors `SettingsWindowController`'s LSUIElement activation-policy dance: exímIABar runs as an
/// `.accessory` agent (no Dock icon), so to bring a real window forward it temporarily becomes
/// `.regular` and reverts to `.accessory` on close. The window is a standard `NSWindow`, 760×560 pt
/// minimum, resizable, titled (AC11).
///
/// Incremental cache (AC12): a `DashboardData` is memoized per `DashboardPeriod`. Selecting a period
/// already in cache applies it instantly with no re-scan; the cache is invalidated when the JSONL
/// directories' modification fingerprint changes between opens.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let costSettingsProvider: @Sendable () -> LiveUsageProvider.CostSettings
    private let costScanner: CostScanner
    private let openSettings: @MainActor () -> Void

    private let model = DashboardModel()
    private var window: NSWindow?
    private var scanTask: Task<Void, Never>?

    /// In-memory cache: one built `DashboardData` per period (AC12). Cleared when the source
    /// directories change (fingerprint mismatch) or on each fresh `open()`-with-stale-data.
    private var cache: [DashboardPeriod: DashboardData] = [:]
    /// Fingerprint of the source directories at the time the cache was populated; a mismatch on a
    /// later scan request invalidates the cache so new usage is picked up (AC12).
    private var cacheFingerprint: String?

    init(
        costSettingsProvider: @escaping @Sendable () -> LiveUsageProvider.CostSettings,
        costScanner: CostScanner = .shared,
        openSettings: @escaping @MainActor () -> Void)
    {
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.openSettings = openSettings
    }

    // MARK: - Open (AC1/AC12)

    func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if window == nil {
            setupWindow()
        }
        // Drop the cache on a fresh open so re-opening reflects new usage since last time.
        cache.removeAll()
        cacheFingerprint = nil
        model.state = .loading
        window?.makeKeyAndOrderFront(nil)

        loadData(for: model.period)
    }

    private func setupWindow() {
        model.onPeriodChange = { [weak self] period in self?.loadData(for: period) }
        model.onExportCSV = { [weak self] in self?.exportCSV() }

        let hostingView = NSHostingView(rootView: DashboardRoot(model: model, openSettings: openSettings))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // AC11: standard NSWindow, 760×560 minimum, resizable, titled.
        let contentSize = NSSize(width: 760, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = L("dashboard.window.title")
        window.setContentSize(contentSize)
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        window.contentView = hostingView
        self.window = window
    }

    // MARK: - Off-main data load (AC12)

    /// Load (or apply cached) data for `period`. When cost tracking is off, show the disabled state.
    /// AC12: if the period is already cached and the source fingerprint is unchanged, apply instantly
    /// with no re-scan; otherwise scan off-main and cache the result.
    private func loadData(for period: DashboardPeriod) {
        let settings = costSettingsProvider()
        guard settings.enabled else {
            model.state = .disabled
            return
        }

        // Cache hit (AC12): apply without a scan.
        if let cached = cache[period] {
            model.state = cached.isEmpty ? .empty : .loaded(cached)
            return
        }

        // Show loading while the scan is in flight (unless we already have content on screen).
        if case .loaded = model.state {} else {
            model.state = .loading
        }

        scanTask?.cancel()
        let scanner = costScanner
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let analytics = await scanner.scanAnalytics(windowDays: period.days)
            let fingerprint = CostScanner.sourceFingerprint()
            let data = DashboardData.build(from: analytics, period: period)
            guard !Task.isCancelled else { return }
            await self?.apply(data, fingerprint: fingerprint)
        }
    }

    /// Post the scanned data into the observable model on `@MainActor`, updating the cache (AC12).
    @MainActor
    private func apply(_ data: DashboardData, fingerprint: String) {
        // Invalidate the cache if the source directories changed since it was populated.
        if let existing = cacheFingerprint, existing != fingerprint {
            cache.removeAll()
        }
        cacheFingerprint = fingerprint
        cache[data.period] = data
        // Only apply if the result is still for the period the user is looking at.
        guard data.period == model.period else { return }
        model.state = data.isEmpty ? .empty : .loaded(data)
    }

    // MARK: - CSV export (AC9)

    /// Present an `NSSavePanel` (on main) and write the current period's daily aggregate as CSV.
    private func exportCSV() {
        guard case let .loaded(data) = model.state, let window else { return }
        let panel = NSSavePanel()
        let dateTag = Self.fileDateTag()
        panel.nameFieldStringValue = "claude-usage-\(data.period.fileTag)-\(dateTag).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let csv = data.csvExport()
            // Write off-main: pure bytes, no UI. A failure is silent (the panel is gone).
            Task.detached(priority: .utility) {
                try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    private static func fileDateTag() -> String {
        let formatter = DateFormatter()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        scanTask?.cancel()
        scanTask = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Bridges the `@Observable` `DashboardModel` into a `DashboardView`.
private struct DashboardRoot: View {
    @Bindable var model: DashboardModel
    let openSettings: @MainActor () -> Void

    var body: some View {
        DashboardView(
            state: model.state,
            period: model.period,
            selectPeriod: { model.selectPeriod($0) },
            exportCSV: { model.onExportCSV?() },
            openSettings: openSettings)
    }
}
