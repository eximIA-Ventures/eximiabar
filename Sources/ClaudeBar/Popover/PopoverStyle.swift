import SwiftUI

/// Shared visual constants for the popover card.
///
/// The popover is an `NSPanel`, not an `NSMenu`, so there is no menu-tracking highlight
/// environment to thread through the views (the reference's `MenuHighlightStyle` /
/// `\.menuItemHighlighted` machinery existed only to recolour content while an `NSMenu` item was
/// highlighted). Action-row hover is handled locally per row with `.onHover`. This enum therefore
/// keeps only the palette and layout metrics the card needs.
enum PopoverStyle {
    /// Claude brand colour `#CC7C5E` — re-exported from the shared `DesignTokens`.
    static let brand = DesignTokens.brand

    /// Progress-bar track: `tertiaryLabelColor` at 0.22 opacity (AC14).
    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)

    // MARK: - Semantic usage zones — re-exported from the shared `DesignTokens` so the popover and
    // the other surfaces share one vocabulary. Definitions live in `DesignTokens`.

    static let zoneAttentionBar = DesignTokens.zoneAttentionBar
    static let zoneCriticalBar = DesignTokens.zoneCriticalBar
    static let zoneAttentionText = DesignTokens.zoneAttentionText
    static let zoneCriticalText = DesignTokens.zoneCriticalText
    static let roiPositive = DesignTokens.roiPositive

    static func zoneBarColor(utilization: Double) -> Color {
        DesignTokens.zoneBarColor(utilization: utilization)
    }

    static func zoneTextColor(utilization: Double) -> Color {
        DesignTokens.zoneTextColor(utilization: utilization)
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
