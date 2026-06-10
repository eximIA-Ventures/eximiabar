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
/// - `percent`: fill percentage, 0–100.
/// - `tint`: fill colour (the Claude brand `#CC7C5E`).
/// - `pacePercent`: when non-nil, draws the diagonal pace punch-out at this percentage (AC14).
/// - `paceReserve`: `true` → green stripe (under-pace / reserve), `false` → red stripe (deficit).
/// - `warningMarkerPercents`: vertical dash markers at the given percentages (AC14).
struct UsageProgressBar: View {
    private static let paceStripeWidth: CGFloat = 2

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
            let fillWidth = size.width * self.clamped / 100
            let paceWidth = size.width * Self.clampedPercent(self.pacePercent) / 100
            // Tip width: max(25, height * 6.5) pt (AC14).
            let tipWidth = max(25, size.height * 6.5)
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + (Self.paceStripeSpan / 2) + stripeInset
            let showTip = self.pacePercent != nil && tipWidth > 0.5
            let markerPercents = self.warningMarkerPercents
                .map(Self.clampedPercent)
                .filter { $0 > 0 && $0 < 100 }

            // Corner radius 3 pt at the 6 pt height (height / 2) (AC14).
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            context.clip(to: Path(rect))

            // Track.
            let trackPath = Path { $0.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(PopoverStyle.progressTrack))

            // Fill.
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))
            }

            // Warning markers (AC14): vertical dashes, 1 px wide, 55% of bar height.
            if !markerPercents.isEmpty {
                let markerColor = Color.primary.opacity(0.32)
                for markerPercent in markerPercents {
                    let x = size.width * markerPercent / 100
                    let markerRect = Self.warningMarkerRect(x: x, size: size, scale: scale)
                    let markerPath = Path {
                        $0.addRoundedRect(
                            in: markerRect,
                            cornerSize: CGSize(width: markerRect.width / 2, height: markerRect.width / 2))
                    }
                    context.fill(markerPath, with: .color(markerColor))
                }
            }

            // Pace tip: punch-out triangle + centre stripe, drawn with CG blend modes so no SwiftUI
            // compositing modifier is needed (AC14).
            if showTip {
                let stripeColor: Color = self.paceReserve ? .green : .red

                let tipSize = CGSize(width: tipWidth, height: size.height)
                let stripes = Self.paceStripePaths(size: tipSize, scale: scale)
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)

                // Punch out of the accumulated track+fill pixels.
                context.blendMode = .destinationOut
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal

                context.fill(stripes.center.applying(shift), with: .color(stripeColor))
            }
        }
        .frame(height: 6) // AC14
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clamped)) percent")
    }

    private static var paceStripeSpan: CGFloat { Self.paceStripeWidth * 3 }

    private static func paceStripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
        let rect = CGRect(origin: .zero, size: size)
        let extend = size.height * 2
        let stripeTopY: CGFloat = -extend
        let stripeBottomY: CGFloat = size.height + extend
        let align: (CGFloat) -> CGFloat = { value in (value * scale).rounded() / scale }

        let stripeWidth = Self.paceStripeWidth
        let punchWidth = stripeWidth * 3
        let stripeInset = 1 / scale
        let stripeAnchorX = align(rect.maxX - stripeInset)
        let stripeMinY = align(stripeTopY)
        let stripeMaxY = align(stripeBottomY)
        let anchorTopX = stripeAnchorX
        var punchedStripe = Path()
        var centerStripe = Path()
        let availableWidth = (anchorTopX - punchWidth) - rect.minX
        guard availableWidth >= 0 else { return (punchedStripe, centerStripe) }

        let punchRightTopX = align(anchorTopX)
        let punchLeftTopX = punchRightTopX - punchWidth
        punchedStripe.addPath(Path { path in
            path.move(to: CGPoint(x: punchLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: punchLeftTopX, y: stripeMaxY))
            path.closeSubpath()
        })

        let centerLeftTopX = align(punchLeftTopX + (punchWidth - stripeWidth) / 2)
        let centerRightTopX = centerLeftTopX + stripeWidth
        centerStripe.addPath(Path { path in
            path.move(to: CGPoint(x: centerLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: centerLeftTopX, y: stripeMaxY))
            path.closeSubpath()
        })

        return (punchedStripe, centerStripe)
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
}
