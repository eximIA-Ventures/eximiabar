import CoreGraphics
import Testing
@testable import ClaudeBar

/// Tests the pure pace geometry of `UsageProgressBar` — the reserve/deficit zone and the solid pace
/// marker (the redesign that replaces the old diagonal punch-out). The drawing itself is a single
/// `Canvas` of `context.fill` calls with no `blendMode`/second `Canvas` (anti-freeze, issue #805);
/// these tests cover the geometry that decides WHAT gets drawn, leaving rendering to visual QA.
struct UsageProgressBarTests {
    private let size = CGSize(width: 100, height: 6)

    // MARK: - (a) Reserve zone drawn only when pace > fill

    /// Reserve case: consumed 22% < pace 74% → a zone spans [22, 74] and the marker sits at 74.
    @Test
    func reserveZoneDrawnWhenPaceAboveFill() {
        let g = UsageProgressBar.paceGeometry(percent: 22, pacePercent: 74, size: self.size)
        #expect(g.hasZone)
        #expect(g.xFill == 22)              // 22% of width 100
        #expect(g.xPace == 74)              // 74% of width 100
        #expect(g.zoneLo == 22)             // zone starts at the fill edge
        #expect(g.zoneHi == 74)             // zone ends at the pace point
        #expect(g.markerOnly == false)
    }

    // MARK: - (b) Deficit case uses the mirrored (alert) geometry

    /// Deficit case: consumed 80% > pace 25% → the zone mirrors to [25, 80] (pace → fill) and the
    /// marker sits at the pace point 25. The same `hasZone` flag drives the alert treatment; colour
    /// selection (red vs green) is the `paceReserve` flag, not geometry.
    @Test
    func deficitZoneMirroredWhenFillAbovePace() {
        let g = UsageProgressBar.paceGeometry(percent: 80, pacePercent: 25, size: self.size)
        #expect(g.hasZone)
        #expect(g.xFill == 80)
        #expect(g.xPace == 25)
        #expect(g.zoneLo == 25)             // zone now starts at the pace point (left of fill)
        #expect(g.zoneHi == 80)             // ...and ends at the consumed fill
        #expect(g.markerOnly == false)
    }

    // MARK: - (c) Pace marker geometry: new width, full height, pixel-aligned

    /// The solid pace marker is `paceMarkerWidth` (3.5 pt) wide, full bar height, centred at xPace.
    /// Asserts on the pure `paceMarkerRect` geometry — reading a SwiftUI `Path.boundingRect` in a
    /// headless test process traps (SIGTRAP, issue #805), so geometry stays in `CGRect`.
    @Test
    func paceMarkerHasNewWidthAndFullHeight() {
        let rect = UsageProgressBar.paceMarkerRect(xPace: 74, size: self.size, scale: 2)
        #expect(abs(rect.width - UsageProgressBar.paceMarkerWidth) < 0.001)
        #expect(UsageProgressBar.paceMarkerWidth == 3.5)
        // Full height (0 → size.height), not the 55% of a warning marker.
        #expect(rect.minY == 0)
        #expect(abs(rect.height - self.size.height) < 0.001)
        // Centred on the pace point (within the rounding to the pixel grid).
        #expect(abs(rect.midX - 74) < 0.5)
    }

    /// The marker is taller than a warning marker (full height vs 55%) — it is unmistakably the
    /// dominant mark on the bar. Both sides are pure `CGRect` geometry (no SwiftUI `Path`).
    @Test
    func paceMarkerTallerThanWarningMarker() {
        let marker = UsageProgressBar.paceMarkerRect(xPace: 50, size: self.size, scale: 2)
        let warning = UsageProgressBar.warningMarkerRect(x: 50, size: self.size, scale: 2)
        #expect(marker.height > warning.height)
    }

    // MARK: - (d) No pace → neither zone nor marker

    /// `pacePercent == nil` → no zone, no marker (the bar is fill-only).
    @Test
    func noZoneOrMarkerWhenPaceNil() {
        let g = UsageProgressBar.paceGeometry(percent: 40, pacePercent: nil, size: self.size)
        #expect(g.hasZone == false)
        #expect(g.markerOnly == false)
        #expect(g.xPace == 0)
        #expect(g.xFill == 40)
    }

    /// A pace of 0 (off the bar) also yields no zone and no marker.
    @Test
    func noZoneOrMarkerWhenPaceZero() {
        let g = UsageProgressBar.paceGeometry(percent: 40, pacePercent: 0, size: self.size)
        #expect(g.hasZone == false)
        #expect(g.markerOnly == false)
    }

    // MARK: - Edge: fill ≈ pace → marker still shows, zone suppressed

    /// When the fill and the pace coincide (on-pace), the zone has no width so it is suppressed, but
    /// the solid marker still shows so the pace point never silently disappears.
    @Test
    func markerOnlyWhenFillEqualsPace() {
        let g = UsageProgressBar.paceGeometry(percent: 50, pacePercent: 50, size: self.size)
        #expect(g.hasZone == false)         // zero-width zone is not drawn
        #expect(g.markerOnly)               // ...but the marker still is
        #expect(g.xPace == 50)
    }

    /// Clamping: out-of-range percentages are pinned to [0, width].
    @Test
    func geometryClampsOutOfRange() {
        let g = UsageProgressBar.paceGeometry(percent: 150, pacePercent: 200, size: self.size)
        #expect(g.xFill == 100)             // clamped to width
        #expect(g.xPace == 100)             // clamped to width
        #expect(g.hasZone == false)         // both at 100 → zero width
    }
}
