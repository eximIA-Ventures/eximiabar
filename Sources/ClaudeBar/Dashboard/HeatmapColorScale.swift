import SwiftUI

/// Non-linear colour scale for the activity heatmap (EXB-4.1).
///
/// The EXB-3.7 baseline fed a **linear** `0 … max` domain to Swift Charts'
/// `chartForegroundStyleScale`. Claude usage is exponentially distributed — one or two peak hours
/// dwarf everything else — so the linear ramp pushed the vast majority of non-zero cells into the
/// bottom sliver of opacity, rendering them effectively invisible against the dark card. With real
/// data (peak 480.5M, median 62.3M) the median cell mapped to ~13% opacity; the smallest non-zero
/// cell to <1%.
///
/// This type replaces that with a **logarithmic** transform (`log1p`, so `log(0)` never occurs) and a
/// hard `0.08` floor for any non-zero cell, guaranteeing every hour with activity is distinguishable
/// from both the dark background and the neutral "zero" cells. Under log1p the same real data lifts
/// the median to ~90% and the smallest cell to ~71% — every busy hour reads clearly.
///
/// Pure, stateless `static` functions: no I/O, no `DateFormatter`/`NumberFormatter`, no allocation
/// beyond the returned `Color`. Safe to call from any thread and from inside a chart `body`
/// (anti-freeze invariant — EPIC-EXB transversal rule).
enum HeatmapColorScale {
    /// The minimum normalized intensity for any cell with `tokens > 0` (AC2 / AC4-#4).
    /// Below this, a cell would be visually indistinguishable from the dark card background.
    static let minimumNonZero: Double = 0.08

    /// The neutral fill for a `tokens == 0` cell (AC2-#6). A faint `secondary` wash that reads as
    /// "no activity" and is immediately distinguishable from the brand-tinted non-zero cells, which
    /// start at `minimumNonZero` (0.08) opacity of the saturated brand colour.
    static let zeroFill: Color = Color.secondary.opacity(0.10)

    /// Logarithmic normalization of a cell's token volume to `0.0 … 1.0` (AC1 / AC4).
    ///
    /// - `tokens == 0` → exactly `0.0` (AC4-#10): zero cells must be perfectly distinct from the
    ///   faintest non-zero cell.
    /// - `tokens > 0` → `log1p(tokens) / log1p(max)`, clamped to `[minimumNonZero, 1.0]` so every
    ///   active cell clears the visibility floor (AC2-#4) and the peak cell saturates at `1.0`.
    ///
    /// `log1p(x) = log(1 + x)` keeps the transform defined for the whole non-negative range without a
    /// `log(0)` special case (AC1-#3).
    static func normalized(tokens: Int, min: Int, max: Int) -> Double {
        guard max > 0, tokens > 0 else { return 0 }
        // Normalize within the ACTIVE range [min … max] in log space, so the full colour ramp is
        // used. Normalizing by `max` alone compressed every busy hour into the top sliver (10M and
        // 200M both mapped to ~0.9), so the map looked monochrome (the v1.4.1 "same colour" bug).
        let lo = log1p(Double(min))
        let hi = log1p(Double(max))
        guard hi > lo else { return 1.0 }
        let value = (log1p(Double(tokens)) - lo) / (hi - lo)
        return Swift.max(0.0, Swift.min(1.0, value))
    }

    /// The fill colour for a heatmap cell (AC2).
    ///
    /// Zero cells get the neutral `zeroFill`; non-zero cells get the brand colour at the cell's
    /// log-normalized opacity. Opacity-of-brand is the same monotone dark→colour ramp the EXB-3.7
    /// legend used, so the visual language is unchanged — only the *distribution* of intensity is
    /// fixed.
    static func color(tokens: Int, min: Int, max: Int) -> Color {
        guard tokens > 0 else { return zeroFill }
        return solidColor(t: normalized(tokens: tokens, min: min, max: max))
    }

    /// The three-stop terracota ramp for a normalized intensity `t` (0…1): dark brown (#2A1A13) →
    /// brand terracota (#CC7C5E) → light peach (#F7DCC4). A SOLID, opaque colour shared by cells and
    /// legend.
    ///
    /// Three stops (not a flat dark→brand lerp) give the heatmap real luminance gradation — a single
    /// terracota tint read as "all the same colour" (v1.4.1). Solid, not `brand.opacity(t)`, because a
    /// low-opacity fill over the Liquid Glass panel blends with the desktop behind the glass and
    /// vanishes (the v1.4.0 "invisible heatmap" bug).
    static func solidColor(t: Double) -> Color {
        let stops: [(Double, Double, Double)] = [
            (42, 26, 19),    // #2A1A13 dark brown
            (204, 124, 94),  // #CC7C5E brand terracota
            (247, 220, 196), // #F7DCC4 light peach
        ]
        let clamped = Swift.max(0.0, Swift.min(1.0, t))
        let seg = 1.0 / Double(stops.count - 1)
        let i = Swift.min(stops.count - 2, Int(clamped / seg))
        let lt = (clamped - Double(i) * seg) / seg
        let a = stops[i]
        let b = stops[i + 1]
        return Color(
            red: (a.0 + (b.0 - a.0) * lt) / 255.0,
            green: (a.1 + (b.1 - a.1) * lt) / 255.0,
            blue: (a.2 + (b.2 - a.2) * lt) / 255.0)
    }

    /// The geometric mid-point token value of the log range, used as the legend's middle anchor
    /// (AC3-#7): `exp(log1p(max) / 2) - 1`. This is the token count whose log-normalized position
    /// sits halfway along the scale, so the three legend anchors (`0`, this, `max`) are evenly spaced
    /// in the *perceptual* (log) space rather than the linear one.
    static func logMidpoint(max: Int) -> Int {
        guard max > 0 else { return 0 }
        return Int((exp(log1p(Double(max)) / 2) - 1).rounded())
    }
}
