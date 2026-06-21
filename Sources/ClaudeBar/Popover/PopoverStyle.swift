import SwiftUI

/// Shared visual constants for the popover card.
///
/// The popover is an `NSPanel`, not an `NSMenu`, so there is no menu-tracking highlight
/// environment to thread through the views (the reference's `MenuHighlightStyle` /
/// `\.menuItemHighlighted` machinery existed only to recolour content while an `NSMenu` item was
/// highlighted). Action-row hover is handled locally per row with `.onHover`. This enum therefore
/// keeps only the palette and layout metrics the card needs.
enum PopoverStyle {
    /// Claude brand colour `#CC7C5E` — the bar fill (AC14). No asset catalog; hardcoded hex.
    static let brand = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)

    /// Progress-bar track: `tertiaryLabelColor` at 0.22 opacity (AC14).
    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)

    // MARK: - Semantic usage zones (EXB redesign)
    //
    // The fill/number colour carries *risk*, not just brand. The brand terracotta survives the
    // comfortable zone (where the user spends ~90% of the time); amber and red carry the alarm.
    // Text variants are one luminance stop lighter than the bar so thin glyphs match the bar's
    // perceived contrast on the dark vibrancy panel.

    /// Attention-zone bar fill (70–89% consumed): amber `#E0A340`.
    static let zoneAttentionBar = Color(red: 224 / 255, green: 163 / 255, blue: 64 / 255)
    /// Critical-zone bar fill (≥90% consumed): red `#E5484D`.
    static let zoneCriticalBar = Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255)
    /// Attention-zone headline text (lighter amber for thin-glyph legibility): `#E8B24A`.
    static let zoneAttentionText = Color(red: 232 / 255, green: 178 / 255, blue: 74 / 255)
    /// Critical-zone headline text: `#F26669`.
    static let zoneCriticalText = Color(red: 242 / 255, green: 102 / 255, blue: 105 / 255)

    /// Positive, value-affirming green for the cost ROI line (EXB redesign #2): `#5FB87E`.
    static let roiPositive = Color(red: 95 / 255, green: 184 / 255, blue: 126 / 255)

    /// Bar fill colour for a consumed percentage. Pure function of `utilization` (0–100):
    /// `< 70` → brand terracotta, `70..<90` → amber, `>= 90` → red. Half-open cuts so 90.0 is
    /// already critical. Safe to call in a view body (anti-freeze).
    static func zoneBarColor(utilization: Double) -> Color {
        switch utilization {
        case ..<70: return brand
        case ..<90: return zoneAttentionBar
        default: return zoneCriticalBar
        }
    }

    /// Headline-number colour for a consumed percentage. Same thresholds as `zoneBarColor`, with the
    /// amber/red variants one luminance stop lighter for thin-glyph contrast on glass.
    static func zoneTextColor(utilization: Double) -> Color {
        switch utilization {
        case ..<70: return brand
        case ..<90: return zoneAttentionText
        default: return zoneCriticalText
        }
    }

    /// Panel width in points (AC4).
    static let panelWidth: CGFloat = 310

    /// Corner radius of the popover panel's visual-effect card (EXB-2.1 AC4).
    ///
    /// `≥ 8 pt` is the AC floor; 10 pt matches the radius the system applies to its own `.popover`
    /// material so the frosted card reads as a native floating panel rather than a square block.
    static let cornerRadius: CGFloat = 10

    /// Horizontal content padding (matches the reference card's 20 pt gutter).
    static let horizontalPadding: CGFloat = 20

    /// Spacing between the two header lines (AC7).
    static let headerLineSpacing: CGFloat = 4

    /// Spacing between the header columns (AC7).
    static let headerColumnSpacing: CGFloat = 12

    /// Internal spacing within a metric row (title→bar→labels) (AC9).
    static let metricInternalSpacing: CGFloat = 6

    /// Spacing between metric rows (AC9).
    static let metricRowSpacing: CGFloat = 12

    /// Action-row height (AC17).
    static let actionRowHeight: CGFloat = 28
}
