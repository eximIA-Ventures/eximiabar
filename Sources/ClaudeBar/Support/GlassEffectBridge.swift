import AppKit

/// macOS 26 Liquid Glass (`NSGlassEffectView`) adoption helpers (EXB-3.5).
///
/// Centralises the one piece of glass logic the popover, Settings, and Dashboard controllers all need
/// so the `#available(macOS 26.0, *)` branch is written and reasoned about once. On macOS < 26 none of
/// this is referenced — each controller keeps its existing `NSVisualEffectView` path untouched (AC1–AC3
/// fallbacks).
///
/// **API confirmed against the local SDK (T1):** `NSGlassEffectView : NSView` exposes
/// `contentView: NSView?`, `cornerRadius: CGFloat`, `tintColor: NSColor?`, and
/// `style: NSGlassEffectView.Style` (`.regular` / `.clear`). The header is emphatic that the glass only
/// guarantees placement for its **`contentView`** — arbitrary subviews have no z-order guarantee — so
/// every caller installs its `NSHostingView` as `contentView`, never via `addSubview` (AC1).
///
/// **Anti-freeze:** building and mutating an `NSGlassEffectView` is pure AppKit on `@MainActor` with no
/// I/O or parsing, so the transversal anti-freeze invariants hold (this is the same class of work as
/// swapping `NSVisualEffectView.material`).
@available(macOS 26.0, *)
enum GlassEffectBridge {
    /// Build an `NSGlassEffectView` carrying `contentView` inside the glass.
    ///
    /// - Parameters:
    ///   - contentView: the view (an `NSHostingView`) to embed in glass. Installed as `contentView`,
    ///     the only placement the SDK guarantees stays inside the effect.
    ///   - cornerRadius: native rounded-corner radius — replaces the `RoundedVisualEffectView` mask the
    ///     macOS < 26 path uses (the glass clips its own corners, so no `maskImage` is needed here).
    ///   - style: the Liquid Glass style (`.regular` / `.clear`), mapped from `TransparencyLevel`.
    /// - Returns: a configured glass view sized to fill its host (autoresizing on both axes).
    @MainActor
    static func makeGlassView(
        contentView: NSView,
        cornerRadius: CGFloat,
        style: NSGlassEffectView.Style) -> NSGlassEffectView
    {
        let glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        glassView.style = style
        glassView.autoresizingMask = [.width, .height]
        // `contentView`, NOT `addSubview`: the header only guarantees z-order for the content view.
        glassView.contentView = contentView
        return glassView
    }
}
