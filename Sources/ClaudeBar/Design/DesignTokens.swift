import SwiftUI

/// The shared visual language for every exímIABar surface — popover, Settings, Dashboard, About.
///
/// Before v2.1 the redesign's vocabulary (rounded numerals, semantic zones, headline hierarchy) lived
/// only inside `PopoverStyle`, so the popover looked like a different app from the rest. These tokens
/// promote that language to a neutral place every view can import, so the screens read as one family.
/// `PopoverStyle` now re-exports from here, so existing popover code keeps working unchanged.
///
/// The family's four tells:
/// 1. Every number uses `Numeral.*` (`design: .rounded`) plus `.monospacedDigit()` at the call site.
/// 2. Title (discreet) + value (large, right-aligned) on the same baseline.
/// 3. Semantic zone colour where there is usage/risk; `roiPositive` where there is value/gain.
/// 4. One vertical rhythm: 12 / 6 / 2.
enum DesignTokens {
    // MARK: - Numerals (always pair with `.monospacedDigit()` at the call site)

    enum Numeral {
        /// Primary metric — the section's headline number.
        static let hero = Font.system(size: 22, weight: .bold, design: .rounded)
        /// Secondary metric — the weekly row's headline number.
        static let large = Font.system(size: 17, weight: .semibold, design: .rounded)
        /// Per-model rows, inline stats, and the cost ROI multiplier line.
        static let compact = Font.system(size: 13, weight: .semibold, design: .rounded)
    }

    // MARK: - Labels

    enum Label {
        /// Section / group titles (use with `.secondary` + `sectionTracking`).
        static let section = Font.caption2.weight(.semibold)
        /// Sub-line values.
        static let value = Font.footnote
    }

    static let sectionTracking: CGFloat = 0.5

    // MARK: - Brand + semantic zones

    /// Claude brand terracotta `#CC7C5E` — the family's accent, in place of the system blue.
    static let brand = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)

    /// Attention-zone bar fill (70–89% consumed): amber `#E0A340`.
    static let zoneAttentionBar = Color(red: 224 / 255, green: 163 / 255, blue: 64 / 255)
    /// Critical-zone bar fill (>= 90% consumed): red `#E5484D`.
    static let zoneCriticalBar = Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255)
    /// Attention-zone headline text (lighter amber for thin glyphs): `#E8B24A`.
    static let zoneAttentionText = Color(red: 232 / 255, green: 178 / 255, blue: 74 / 255)
    /// Critical-zone headline text: `#F26669`.
    static let zoneCriticalText = Color(red: 242 / 255, green: 102 / 255, blue: 105 / 255)

    /// Positive, value-affirming green for the cost ROI line: `#5FB87E`.
    static let roiPositive = Color(red: 95 / 255, green: 184 / 255, blue: 126 / 255)

    /// Bar fill colour for a consumed percentage (`< 70` brand, `70..<90` amber, `>= 90` red).
    /// Half-open cuts so 90.0 is already critical. Pure; safe in a view body.
    static func zoneBarColor(utilization: Double) -> Color {
        switch utilization {
        case ..<70: return brand
        case ..<90: return zoneAttentionBar
        default: return zoneCriticalBar
        }
    }

    /// Headline-number colour for a consumed percentage. Same thresholds as `zoneBarColor`, with the
    /// amber/red one luminance stop lighter for thin-glyph contrast.
    static func zoneTextColor(utilization: Double) -> Color {
        switch utilization {
        case ..<70: return brand
        case ..<90: return zoneAttentionText
        default: return zoneCriticalText
        }
    }

    // MARK: - Popover theme (v2.2.0 — opt-in "eximIA Meter" skin)

    /// "eximIA Meter" amber accent `#EB9A2C` — the meter theme's brand colour, in place of terracotta.
    static let meterAccent = Color(red: 235 / 255, green: 154 / 255, blue: 44 / 255)
    /// Lighter amber for thin headline glyphs in the meter theme: `#F2A93E`.
    static let meterAccentText = Color(red: 242 / 255, green: 169 / 255, blue: 62 / 255)
    /// Deep near-black surface behind the meter theme's card: `#0C0C0E`. Painted over the window
    /// material only when the meter skin is active, to get the "eximIA Meter" black depth.
    static let meterSurface = Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255)

    /// The brand accent for a theme: terracotta (classic) or amber (meter). The attention/critical
    /// bands stay shared amber/red, so the theme switch is just the healthy-band accent swap.
    static func accent(for theme: PopoverTheme) -> Color {
        switch theme {
        case .classic: return brand
        case .meter: return meterAccent
        }
    }

    /// Themed bar fill: the healthy `< 70` band uses the theme accent; attention/critical are shared.
    static func zoneBarColor(utilization: Double, theme: PopoverTheme) -> Color {
        switch utilization {
        case ..<70: return accent(for: theme)
        case ..<90: return zoneAttentionBar
        default: return zoneCriticalBar
        }
    }

    /// Themed headline-number colour. Healthy band uses the theme accent's lighter text variant.
    static func zoneTextColor(utilization: Double, theme: PopoverTheme) -> Color {
        switch utilization {
        case ..<70: return theme == .meter ? meterAccentText : brand
        case ..<90: return zoneAttentionText
        default: return zoneCriticalText
        }
    }

    // MARK: - Spacing (one vertical rhythm)

    /// Between metric rows / sections.
    static let rowSpacing: CGFloat = 12
    /// Title → bar → labels within a row.
    static let internalSpacing: CGFloat = 6
    /// Between stacked sub-lines.
    static let subLineSpacing: CGFloat = 2
}
