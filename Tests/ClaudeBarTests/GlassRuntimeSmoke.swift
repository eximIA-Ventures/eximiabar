import AppKit
import Testing
@testable import ClaudeBar

/// EXB-3.5 runtime smoke (macOS 26 only): drives the **real** `UsagePanelController` so the glass
/// wiring is verified end-to-end, not just the `GlassEffectBridge` helper in isolation.
///
/// The contract (AC1/AC4): on macOS 26 the panel's content view is an `NSGlassEffectView` whose
/// `contentView` is the SwiftUI host (NOT a loose sibling — the only z-order the SDK guarantees);
/// switching `TransparencyLevel` swaps the glass `style`; and `.opaque` routes back to the legacy
/// `NSVisualEffectView` backing. Uses `Mirror` to read the controller's private panel/host without
/// widening their access level.
@MainActor
struct GlassRuntimeSmoke {
    @available(macOS 26.0, *)
    @Test
    func panelAdoptsGlassAndHostsAsContentView() {
        let controller = UsagePanelController(
            snapshotProvider: { nil },
            actions: UsageCardActions(),
            transparency: TransparencyLevel.frosted)
        let mirror = Mirror(reflecting: controller)
        let panel = mirror.children.first { $0.label == "panel" }!.value as! NSWindow
        let host = mirror.children.first { $0.label == "hostingView" }!.value as! NSView

        // Seeded `.frosted` → `NSGlassEffectView(.clear)` holding the host as its content view (AC1).
        let glass = panel.contentView as? NSGlassEffectView
        #expect(glass != nil, "frosted on macOS 26 must yield an NSGlassEffectView content view")
        #expect(glass?.style == .clear)
        #expect(glass?.contentView === host, "host must be the glass CONTENT VIEW, not a sibling")
        // NSGlassEffectView wraps its contentView in a private `_ContentHolderView`, so `host.superview`
        // is that holder, not the glass directly — assert the host is inside the glass subtree instead
        // of an exact parent identity (the holder layer is an SDK implementation detail).
        #expect(host.isDescendant(of: glass!), "host must live inside the glass view subtree")

        // `.standard` → `.regular`, same glass reused (a style change is a single property set).
        controller.applyTransparency(TransparencyLevel.standard)
        #expect((panel.contentView as? NSGlassEffectView)?.style == .regular)

        // `.opaque` → falls back to the NSVisualEffectView backing (AC4); host re-parented.
        controller.applyTransparency(TransparencyLevel.opaque)
        #expect(panel.contentView is NSVisualEffectView)
        #expect(!(panel.contentView is NSGlassEffectView))

        // Back to `.frosted` → glass again.
        controller.applyTransparency(TransparencyLevel.frosted)
        #expect(panel.contentView is NSGlassEffectView)
    }
}
