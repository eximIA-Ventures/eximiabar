import Foundation
import Testing
@testable import ClaudeBar

/// EXB-4.2 — the min-max log heatmap colour scale (3-stop terracota ramp).
///
/// The visual fix (legible, gradated cells over the Liquid Glass card) is validated by Hugo's eye
/// and by ImageRenderer snapshots; these tests pin the pure contract: min-max log normalization
/// spreading the active range across the full 0…1 ramp, the exact-zero case, real 3-stop gradation,
/// and the legend's K/M/B labels never emitting scientific notation. Stateless — order independent.
struct HeatmapColorScaleTests {
    // MARK: - Min-max log normalization uses the whole ramp

    /// The smallest active hour anchors at 0.0 and the peak at 1.0 — the full colour range is used,
    /// so busy hours are no longer crushed into one tint (the v1.4.1 "same colour" bug).
    @Test
    func normalizedSpansActiveRange() {
        let minT = 100_000, maxT = 238_900_000
        #expect(HeatmapColorScale.normalized(tokens: minT, min: minT, max: maxT) == 0.0)
        #expect(HeatmapColorScale.normalized(tokens: maxT, min: minT, max: maxT) == 1.0)
    }

    /// Four inputs across ~3.4 orders of magnitude → four distinct, strictly increasing intensities.
    @Test
    func normalized4DistinctBands() {
        let minT = 100_000, maxT = 238_900_000
        let values = [100_000, 1_000_000, 10_000_000, 238_900_000]
        let norm = values.map { HeatmapColorScale.normalized(tokens: $0, min: minT, max: maxT) }
        #expect(Set(norm).count == 4)
        for i in 1..<norm.count { #expect(norm[i] > norm[i - 1]) }
        #expect(norm.first == 0.0)
        #expect(norm.last == 1.0)
    }

    /// Spot-check the exact min-max log transform so a refactor can't silently swap the curve.
    @Test
    func normalizedMatchesMinMaxLogFormula() {
        let minT = 1_400_000, maxT = 480_500_000
        let lo = log1p(Double(minT)), hi = log1p(Double(maxT))
        for tokens in [62_300_000, 4_400_000, 1_400_000] {
            let expected = Swift.max(0.0, Swift.min(1.0, (log1p(Double(tokens)) - lo) / (hi - lo)))
            #expect(abs(HeatmapColorScale.normalized(tokens: tokens, min: minT, max: maxT) - expected) < 1e-12)
        }
    }

    // MARK: - Degenerate cases

    @Test
    func normalizedZeroReturnsZero() {
        #expect(HeatmapColorScale.normalized(tokens: 0, min: 100, max: 238_900_000) == 0.0)
        // A degenerate empty heatmap (max == 0) must not divide by `log1p(0) == 0`.
        #expect(HeatmapColorScale.normalized(tokens: 0, min: 0, max: 0) == 0.0)
        #expect(HeatmapColorScale.normalized(tokens: 500, min: 100, max: 0) == 0.0)
    }

    /// A single distinct active value (min == max) saturates rather than dividing by zero.
    @Test
    func normalizedSingleValueIsFull() {
        #expect(HeatmapColorScale.normalized(tokens: 5_000_000, min: 5_000_000, max: 5_000_000) == 1.0)
    }

    // MARK: - The 3-stop ramp gives real gradation

    @Test
    func solidColorGradation() {
        let low = HeatmapColorScale.solidColor(t: 0.0)
        let mid = HeatmapColorScale.solidColor(t: 0.5)
        let high = HeatmapColorScale.solidColor(t: 1.0)
        #expect(low != mid)
        #expect(mid != high)
        #expect(low != high)
    }

    // MARK: - Legend labels are K/M/B, never scientific notation

    @Test
    func legendLabelsNoScientificNotation() {
        let maxT = 238_900_000
        let anchors = [0, HeatmapColorScale.logMidpoint(max: maxT), maxT]
        let labels = anchors.map { DashboardFormat.tokenCount($0) }
        for label in labels { #expect(!label.lowercased().contains("e")) }
        #expect(anchors[0] == 0)
        #expect(anchors[1] > 0)
        #expect(anchors[1] < maxT)
        #expect(labels[0] == "0")
        #expect(labels[2] == "238.9M")
    }

    // MARK: - Zero cells are a distinct neutral fill, not a faint coloured cell

    @Test
    func zeroCellUsesNeutralFillDistinctFromBrand() {
        let zero = HeatmapColorScale.color(tokens: 0, min: 100, max: 1_000_000)
        let active = HeatmapColorScale.color(tokens: 500_000, min: 100, max: 1_000_000)
        #expect(zero != active)
        #expect(zero == HeatmapColorScale.zeroFill)
    }
}
