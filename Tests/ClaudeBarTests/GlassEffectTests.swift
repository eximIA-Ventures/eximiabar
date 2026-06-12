import AppKit
import Testing
@testable import ClaudeBar

/// Tests for EXB-3.5 — macOS 26 Liquid Glass (`NSGlassEffectView`) adoption.
///
/// Covers the load-bearing contract: each `TransparencyLevel` maps to the right `NSGlassEffectView.Style`
/// on macOS 26 (AC4/AC7), `.opaque` maps to *no* glass (the sentinel the controllers route to the legacy
/// effect-view backing), and the mapping mirrors the established `material` mapping so both OS paths
/// express the same three-level intent. The `material` fallback (macOS < 26) stays covered by
/// `AppearanceTests`.
@MainActor
struct GlassEffectTests {
    // MARK: - TransparencyLevel → NSGlassEffectView.Style mapping (AC4)

    /// The exact macOS 26 mapping (AC4): `.standard → .regular` (standard glass),
    /// `.frosted → .clear` (the maximally-translucent Liquid Glass).
    @available(macOS 26.0, *)
    @Test
    func transparencyLevelMapsToGlassStyle() {
        #expect(TransparencyLevel.standard.glassStyle == .regular)
        #expect(TransparencyLevel.frosted.glassStyle == .clear)
    }

    /// `.opaque` has no glass (AC4) — the macOS 26 path uses this `nil` sentinel to fall back to the
    /// near-solid `NSVisualEffectView(.underWindowBackground)` surface, matching the macOS < 26 behaviour.
    @available(macOS 26.0, *)
    @Test
    func opaqueLevelHasNoGlassStyle() {
        #expect(TransparencyLevel.opaque.glassStyle == nil)
    }

    /// The glass mapping mirrors the material mapping: every level that frosts (`.standard`/`.frosted`)
    /// has a glass style, and the only non-glass level (`.opaque`) is exactly the one whose material is
    /// the least-translucent `.underWindowBackground`. Guards against the two mappings drifting apart.
    @available(macOS 26.0, *)
    @Test
    func glassAndMaterialMappingsAgreeOnOpaque() {
        for level in TransparencyLevel.allCases {
            let hasGlass = level.glassStyle != nil
            let isOpaque = level == .opaque
            #expect(hasGlass == !isOpaque)
            if isOpaque {
                #expect(level.material == .underWindowBackground)
            }
        }
    }

    // MARK: - GlassEffectBridge wiring (AC1 — contentView placement)

    /// `makeGlassView` installs the supplied view as the glass **`contentView`** (the only SDK-guaranteed
    /// in-glass placement, per the `NSGlassEffectView.h` header), never as a loose subview, and applies
    /// the requested radius and style.
    @available(macOS 26.0, *)
    @Test
    func bridgeInstallsContentViewAndStyle() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let glass = GlassEffectBridge.makeGlassView(
            contentView: content,
            cornerRadius: 12,
            style: .clear)

        #expect(glass.contentView === content)
        #expect(glass.cornerRadius == 12)
        #expect(glass.style == .clear)
        #expect(glass.autoresizingMask == [.width, .height])
    }
}
