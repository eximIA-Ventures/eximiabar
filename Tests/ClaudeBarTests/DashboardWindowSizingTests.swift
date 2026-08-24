import AppKit
import Testing
@testable import ClaudeBar

/// Guards the dashboard window's minimum size (AC11) against the defect where the authored floor was
/// silently discarded, letting the window shrink until the KPI card grid was clipped — the reported
/// "cards cut in half" bug.
///
/// The mechanism: installing a `contentView` whose subtree uses auto layout makes AppKit re-derive
/// the window's size limits from that subtree's constraints, throwing away anything set beforehand.
/// `NSGlassEffectView` pins its `contentView` with constraints, so on the glass transparency levels
/// (`.frosted` — the **default** — and `.standard`) the authored 760×560 floor was replaced by the
/// hosting view's own 241×88.5 minimums, i.e. a window that could be dragged down to 241×32.
///
/// `.opaque` never showed the bug (nothing re-parents on that path), which is exactly why it makes a
/// good control: the same assertions must hold on all three levels.
///
/// Reads the controller's private `window` via `Mirror`, the same technique `GlassRuntimeSmoke` uses.
@MainActor
struct DashboardWindowSizingTests {
    /// The floor the summary-card row needs. Mirrors `DashboardWindowController.minimumContentSize`
    /// deliberately by value rather than by reference: this is the *contract*, so a change to the
    /// production constant should break this test rather than silently redefine the expectation.
    private static let expectedContentMinSize = NSSize(width: 760, height: 528)

    private func openedWindow(_ level: TransparencyLevel) -> NSWindow {
        _ = NSApplication.shared
        let controller = DashboardWindowController(
            costSettingsProvider: { .init(enabled: false, days: 30) },
            openSettings: {},
            transparencyProvider: { level })
        controller.open()
        let mirror = Mirror(reflecting: controller)
        return mirror.children.first { $0.label == "window" }!.value as! NSWindow
    }

    @Test(arguments: [TransparencyLevel.frosted, .standard, .opaque])
    func windowKeepsTheCardRowFloorOnEveryTransparencyLevel(level: TransparencyLevel) {
        let window = openedWindow(level)

        #expect(
            window.contentMinSize == Self.expectedContentMinSize,
            "\(level): content floor was \(window.contentMinSize); a subtree-derived floor here means the window can shrink until the summary-card grid is clipped")
        // AC11 is authored in frame terms (760×560). AppKit derives the frame minimum from the content
        // minimum plus the titlebar, so asserting it catches a content floor that never reached the frame.
        #expect(window.minSize.width >= 760, "\(level): frame minimum width \(window.minSize.width) < 760")
        #expect(window.minSize.height >= 560, "\(level): frame minimum height \(window.minSize.height) < 560")
    }

    /// The floor must survive transparency changes made while the window is open, since each one can
    /// swap the content view and re-trigger the re-derivation.
    @Test
    func floorSurvivesLiveTransparencySwitches() {
        _ = NSApplication.shared
        let controller = DashboardWindowController(
            costSettingsProvider: { .init(enabled: false, days: 30) },
            openSettings: {},
            transparencyProvider: { .frosted })
        controller.open()
        let mirror = Mirror(reflecting: controller)
        let window = mirror.children.first { $0.label == "window" }!.value as! NSWindow

        for level in [TransparencyLevel.opaque, .standard, .frosted, .opaque] {
            controller.applyTransparency(level)
            #expect(
                window.contentMinSize == Self.expectedContentMinSize,
                "floor lost after switching to \(level): \(window.contentMinSize)")
        }
    }
}
