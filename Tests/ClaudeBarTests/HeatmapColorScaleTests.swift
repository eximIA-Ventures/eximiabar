import Foundation
import Testing
@testable import ClaudeBar

/// EXB-4.1 — the log/contrast heatmap colour scale.
///
/// The fix that matters visually (cells legible against the dark card) is validated by Hugo's eye;
/// these tests pin the *pure* contract the view rests on: the `log1p` normalization, the exact-zero
/// case, the minimum-contrast floor for any non-zero cell, and the legend's K/M/B labels never
/// emitting scientific notation. Run order independent — `HeatmapColorScale` is stateless.
struct HeatmapColorScaleTests {
    // MARK: - AC4-#9 / AC5-#12: log1p normalization spreads an exponential distribution into bands

    /// The story's headline case: one 238.9M peak with the rest at 100K–5M must still produce at
    /// least four perceptibly different intensities (a linear scale would crush 100K, 1M and 10M into
    /// the same near-zero sliver).
    @Test
    func normalized4DistinctBands() {
        let max = 238_900_000
        let values = [100_000, 1_000_000, 10_000_000, 238_900_000]
        let normalized = values.map { HeatmapColorScale.normalized(tokens: $0, max: max) }

        // Four inputs spanning ~3.4 orders of magnitude → four distinct outputs.
        #expect(Set(normalized).count == 4)

        // Strictly increasing — more tokens is always a stronger cell.
        for i in 1..<normalized.count {
            #expect(normalized[i] > normalized[i - 1])
        }

        // The peak saturates at 1.0; the smallest sample is already well clear of the floor.
        #expect(normalized.last == 1.0)
        #expect(normalized.first! > HeatmapColorScale.minimumNonZero)
    }

    /// `log1p(tokens) / log1p(max)` is the exact transform (AC1-#3) — spot-check the formula directly
    /// so a future refactor can't silently swap in a different curve.
    @Test
    func normalizedMatchesLog1pFormula() {
        let max = 480_500_000 // the real-data peak observed in ~/.claude/projects
        for tokens in [62_300_000, 4_400_000, 1_400_000] {
            let expected = log1p(Double(tokens)) / log1p(Double(max))
            #expect(abs(HeatmapColorScale.normalized(tokens: tokens, max: max) - expected) < 1e-12)
        }
    }

    // MARK: - AC4-#10: the zero case is exactly 0.0

    @Test
    func normalizedZeroReturnsZero() {
        #expect(HeatmapColorScale.normalized(tokens: 0, max: 238_900_000) == 0.0)
        // A degenerate empty heatmap (max == 0) must not divide by `log1p(0) == 0`.
        #expect(HeatmapColorScale.normalized(tokens: 0, max: 0) == 0.0)
        #expect(HeatmapColorScale.normalized(tokens: 500, max: 0) == 0.0)
    }

    // MARK: - AC2-#4 / AC5-#12: every non-zero cell clears the 0.08 visibility floor

    @Test
    func normalizedNonZeroMinimum008() {
        let max = 1_000_000_000
        // Even a single token against a billion-token peak must remain visible.
        #expect(HeatmapColorScale.normalized(tokens: 1, max: max) >= 0.08)
        // And the clamp never lets a non-zero cell dip under the floor across a wide range.
        for tokens in [1, 100, 10_000, 250_000, 5_000_000] {
            #expect(HeatmapColorScale.normalized(tokens: tokens, max: max) >= HeatmapColorScale.minimumNonZero)
        }
        // The floor only lifts — it never pulls a strong cell down below its true value.
        #expect(HeatmapColorScale.normalized(tokens: max, max: max) == 1.0)
    }

    // MARK: - AC3-#7 / AC3-#8: legend anchors are log-spaced and K/M/B formatted (no sci-notation)

    @Test
    func legendLabelsNoScientificNotation() {
        let max = 238_900_000
        let anchors = [0, HeatmapColorScale.logMidpoint(max: max), max]
        let labels = anchors.map { DashboardFormat.tokenCount($0) }

        // No label may contain an exponent marker.
        for label in labels {
            #expect(!label.lowercased().contains("e"))
        }

        // The anchors are ordered 0 < mid < max, and the mid sits inside the log range (not a linear
        // half of max, which for this distribution would be ~119M — far too high).
        #expect(anchors[0] == 0)
        #expect(anchors[1] > 0)
        #expect(anchors[1] < max)
        #expect(anchors[1] < max / 2)

        // Concrete expected K/M/B renderings for the headline max.
        #expect(labels[0] == "0")
        #expect(labels[2] == "238.9M")
    }

    @Test
    func logMidpointIsGeometricMidOfRange() {
        let max = 238_900_000
        let mid = HeatmapColorScale.logMidpoint(max: max)
        // The mid-point's normalized position is ~0.5 of the scale by construction.
        let position = HeatmapColorScale.normalized(tokens: mid, max: max)
        #expect(abs(position - 0.5) < 0.01)
        // Degenerate guard.
        #expect(HeatmapColorScale.logMidpoint(max: 0) == 0)
    }

    // MARK: - AC2-#6: zero cells are a distinct neutral fill, not a faint brand cell

    @Test
    func zeroCellUsesNeutralFillDistinctFromBrand() {
        let zero = HeatmapColorScale.color(tokens: 0, max: 1_000_000)
        let faintNonZero = HeatmapColorScale.color(tokens: 1, max: 1_000_000)
        // The two must not be the same colour value — "no activity" vs "some activity" is immediate.
        #expect(zero != faintNonZero)
        #expect(zero == HeatmapColorScale.zeroFill)
    }
}
