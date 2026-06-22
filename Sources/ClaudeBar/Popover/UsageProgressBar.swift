import SwiftUI

/// Static progress fill drawn in a single SwiftUI `Canvas` — no implicit animations, no Metal
/// shaders, no SwiftUI compositing modifiers (`.blendMode` / `.compositingGroup`).
///
/// Ported from `_reference_codexbar/Sources/CodexBar/UsageProgressBar.swift:4-195` and adapted for
/// the panel: there is no `\.menuItemHighlighted` environment (that existed only to recolour
/// content while an `NSMenu` item was highlighted), so the highlight branches are removed and the
/// track/fill use the panel palette directly. A single `Canvas` uses Core Graphics internally and
/// avoids the compositing modifiers that trigger RenderBox shader compilation (reference issue
/// #805).
///
/// The pace treatment (redesign): the old diagonal punch-out tip is replaced by two filled layers
/// drawn entirely with `context.fill` of plain rectangular `Path`s (no `blendMode`, no second
/// `Canvas`):
///   1. a translucent **reserve / deficit zone** between the consumed fill and the pace point, and
///   2. a solid, full-height **pace marker** that supersedes the thin warning-style stripe.
/// In the reserve case (pace > fill) the zone is sage green and the marker forest green; in the
/// deficit case (fill > pace) the zone is alert red and the marker red. Warning markers that fall
/// inside the zone are dimmed so they do not compete with the band.
///
/// - `percent`: fill percentage, 0–100 (consumed).
/// - `tint`: fill colour (the Claude brand `#CC7C5E`).
/// - `pacePercent`: when non-nil, draws the reserve/deficit zone + pace marker at this percentage.
/// - `paceReserve`: `true` → green reserve (under-pace), `false` → red deficit (over-pace).
/// - `warningMarkerPercents`: vertical dash markers at the given percentages (AC14).
struct UsageProgressBar: View {
    /// Width of the solid pace marker, in points (replaces the 2 pt warning-style stripe).
    static let paceMarkerWidth: CGFloat = 3.5
    /// Fill opacity for the translucent reserve (green) zone over the dark popover track.
    static let reserveZoneOpacity: CGFloat = 0.20
    /// Fill opacity for the translucent deficit (red) zone — one stop heavier than reserve, because
    /// an alert should read with more weight than a positive reserve.
    static let deficitZoneOpacity: CGFloat = 0.22

    let percent: Double
    let tint: Color
    let accessibilityLabel: String
    let pacePercent: Double?
    let paceReserve: Bool
    let warningMarkerPercents: [Double]

    @Environment(\.displayScale) private var displayScale

    init(
        percent: Double,
        tint: Color = PopoverStyle.brand,
        accessibilityLabel: String,
        pacePercent: Double? = nil,
        paceReserve: Bool = true,
        warningMarkerPercents: [Double] = [])
    {
        self.percent = percent
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.pacePercent = pacePercent
        self.paceReserve = paceReserve
        self.warningMarkerPercents = warningMarkerPercents
    }

    private var clamped: Double { min(100, max(0, self.percent)) }

    var body: some View {
        Canvas { context, size in
            let scale = max(self.displayScale, 1)
            let geometry = Self.paceGeometry(
                percent: self.clamped,
                pacePercent: self.pacePercent,
                size: size)
            let fillWidth = geometry.xFill
            let markerPercents = self.warningMarkerPercents
                .map(Self.clampedPercent)
                .filter { $0 > 0 && $0 < 100 }

            // Corner radius 3 pt at the 6 pt height (height / 2) (AC14).
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            context.clip(to: Path(rect))

            // 1. Track.
            let trackPath = Path { $0.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(PopoverStyle.progressTrack))

            // 2. Reserve / deficit zone — NEW. A straight rectangle drawn INSIDE the rounded clip,
            //    so its right edge inherits the pill's rounding when it touches 100% (no own corners).
            //    In the reserve case it sits to the RIGHT of the fill (no overlap); in the deficit
            //    case it sits to the LEFT of the fill, and the fill (drawn next) seals its left edge.
            if geometry.hasZone {
                let zoneRect = CGRect(
                    x: geometry.zoneLo,
                    y: 0,
                    width: geometry.zoneHi - geometry.zoneLo,
                    height: size.height)
                let zoneColor = self.paceReserve
                    ? PopoverStyle.roiPositive.opacity(Self.reserveZoneOpacity)
                    : DesignTokens.zoneCriticalBar.opacity(Self.deficitZoneOpacity)
                context.fill(Path(zoneRect), with: .color(zoneColor))
            }

            // 3. Fill (terracotta). Drawn after the zone so it covers cleanly up to xFill; in the
            //    deficit case this also seals the zone's left edge where the zone starts at xPace.
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))
            }

            // 4. Warning markers (AC14): vertical dashes, 1 px wide, 55% of bar height. Markers that
            //    fall inside the reserve/deficit zone are dimmed (0.14 vs 0.32) so they do not compete
            //    with the band; those within 2 pt of the pace marker are skipped entirely.
            if !markerPercents.isEmpty {
                for markerPercent in markerPercents {
                    let x = size.width * markerPercent / 100
                    if geometry.hasZone, abs(x - geometry.xPace) < 2 { continue }
                    let inZone = geometry.hasZone && x >= geometry.zoneLo && x <= geometry.zoneHi
                    let markerColor = Color.primary.opacity(inZone ? 0.14 : 0.32)
                    let markerRect = Self.warningMarkerRect(x: x, size: size, scale: scale)
                    let markerPath = Path {
                        $0.addRoundedRect(
                            in: markerRect,
                            cornerSize: CGSize(width: markerRect.width / 2, height: markerRect.width / 2))
                    }
                    context.fill(markerPath, with: .color(markerColor))
                }
            }

            // 5. Pace marker — solid, full-height, drawn last so it sits over everything (the zone's
            //    adjacent edge and any nearby warning markers). A plain rounded rectangle filled with
            //    `context.fill`: no `blendMode`, no second `Canvas`, no compositing modifier.
            if geometry.hasZone || geometry.markerOnly {
                let markerPath = Self.paceMarkerPath(xPace: geometry.xPace, size: size, scale: scale)
                let markerColor = self.paceReserve
                    ? PopoverStyle.roiPositive
                    : DesignTokens.zoneCriticalBar
                context.fill(markerPath, with: .color(markerColor))
            }
        }
        .frame(height: 6) // AC14
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clamped)) percent")
    }

    // MARK: - Pure geometry (testable)

    /// The resolved coordinates of the pace treatment for one bar, all pure functions of the inputs.
    struct PaceGeometry: Equatable {
        /// Right edge of the consumed terracotta fill (points).
        let xFill: CGFloat
        /// Centre x of the pace marker (points). `0` when there is no pace.
        let xPace: CGFloat
        /// Left edge of the zone — `min(xFill, xPace)`.
        let zoneLo: CGFloat
        /// Right edge of the zone — `max(xFill, xPace)`.
        let zoneHi: CGFloat
        /// `true` when there is a pace AND the zone has visible width (> 0.5 pt).
        let hasZone: Bool
        /// `true` when there is a pace but the zone is too thin to draw (fill ≈ pace) — the solid
        /// marker still shows so the pace point never silently disappears.
        let markerOnly: Bool
    }

    /// Resolve the pace geometry for a bar. Returns a zero-pace geometry (`hasZone == false`,
    /// `markerOnly == false`) when `pacePercent` is `nil` or resolves off-bar.
    static func paceGeometry(percent: Double, pacePercent: Double?, size: CGSize) -> PaceGeometry {
        let xFill = min(size.width * Self.clampedPercent(percent) / 100, size.width)
        guard let pacePercent else {
            return PaceGeometry(xFill: xFill, xPace: 0, zoneLo: 0, zoneHi: 0, hasZone: false, markerOnly: false)
        }
        let xPace = size.width * Self.clampedPercent(pacePercent) / 100
        guard xPace > 0 else {
            return PaceGeometry(xFill: xFill, xPace: 0, zoneLo: 0, zoneHi: 0, hasZone: false, markerOnly: false)
        }
        let zoneLo = min(xFill, xPace)
        let zoneHi = max(xFill, xPace)
        let hasZone = (zoneHi - zoneLo) > 0.5
        return PaceGeometry(
            xFill: xFill,
            xPace: xPace,
            zoneLo: zoneLo,
            zoneHi: zoneHi,
            hasZone: hasZone,
            markerOnly: !hasZone)
    }

    /// The pixel-aligned rectangle of the solid pace marker: width `paceMarkerWidth`, full bar height
    /// (`y == 0`, `height == size.height`), centred at `xPace`, left edge snapped to the pixel grid.
    /// Pure geometry — no SwiftUI — so it is safe to assert on in a headless test process.
    static func paceMarkerRect(xPace: CGFloat, size: CGSize, scale rawScale: CGFloat) -> CGRect {
        let scale = max(rawScale, 1)
        let align: (CGFloat) -> CGFloat = { value in (value * scale).rounded() / scale }
        let width = Self.paceMarkerWidth
        let minX = align(xPace - width / 2)
        return CGRect(x: minX, y: 0, width: width, height: size.height)
    }

    /// The pixel-aligned rounded-rectangle path for the solid pace marker: width `paceMarkerWidth`,
    /// full bar height, centred at `xPace`, corners `min(width/2, 1.25)` to take the edge off.
    /// Thin wrapper over `paceMarkerRect` — the rect is the geometry, this only wraps it in a SwiftUI
    /// `Path` for the `Canvas` draw, so the rendered output is unchanged.
    static func paceMarkerPath(xPace: CGFloat, size: CGSize, scale rawScale: CGFloat) -> Path {
        let markerRect = Self.paceMarkerRect(xPace: xPace, size: size, scale: rawScale)
        let radius = min(Self.paceMarkerWidth / 2, 1.25)
        return Path { $0.addRoundedRect(in: markerRect, cornerSize: CGSize(width: radius, height: radius)) }
    }

    static func warningMarkerRect(x: CGFloat, size: CGSize, scale rawScale: CGFloat) -> CGRect {
        let scale = max(rawScale, 1)
        let width = max(1 / scale, 1)
        let height = min(size.height, max(1 / scale, size.height * 0.55))
        let align: (CGFloat) -> CGFloat = { value in (value * scale).rounded() / scale }

        return CGRect(
            x: align(x - width / 2),
            y: align((size.height - height) / 2),
            width: width,
            height: align(height))
    }

    private static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
