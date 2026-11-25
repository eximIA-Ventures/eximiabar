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

    // MARK: - State palette (EXB-6.2 AC2) — gravity, never identity

    /// How serious a usage reading is. Colour follows **gravity**, not the brand: a healthy window
    /// reads neutral, so amber and red keep their meaning when they do appear.
    enum Severity: Equatable, Sendable {
        /// Within limits and on pace.
        case neutral
        /// Behind pace (deficit) or at/above 70% used.
        case attention
        /// The burn empties the window before the reset, or at/above 90% used.
        case critical
    }

    /// The single severity rule. `runsOutBeforeReset` and `inDeficit` come from the pace; without a
    /// pace only the consumed percentage decides.
    static func severity(utilization: Double, inDeficit: Bool = false, runsOutBeforeReset: Bool = false) -> Severity {
        if utilization >= 90 || runsOutBeforeReset { return .critical }
        if utilization >= 70 || inDeficit { return .attention }
        return .neutral
    }

    /// The colours a usage surface may use. Separate from `ModelPalette` on purpose: a model's
    /// identity colour must never read as a warning.
    enum StatePalette {
        /// Neutral bar fill: the label colour, softened.
        static let neutralBar = Color(nsColor: .labelColor).opacity(0.55)
        /// Neutral headline text.
        static let neutralText = Color(nsColor: .labelColor)

        static func bar(_ severity: Severity) -> Color {
            switch severity {
            case .neutral: return neutralBar
            case .attention: return zoneAttentionBar
            case .critical: return zoneCriticalBar
            }
        }

        static func text(_ severity: Severity) -> Color {
            switch severity {
            case .neutral: return neutralText
            case .attention: return zoneAttentionText
            case .critical: return zoneCriticalText
            }
        }

        /// Every colour the state palette can produce — what `ModelPalette` must stay clear of.
        static let all: [Color] = [zoneAttentionBar, zoneCriticalBar, zoneAttentionText, zoneCriticalText]
    }

    // MARK: - Model palette (EXB-6.2 AC2.3) — identity, never gravity

    /// Per-model identity swatches for the Dashboard. Cool and muted only: no brand terracotta, no
    /// amber, no red — the old ramp put Opus (usually the top model) on terracotta and the fourth
    /// model on amber, so a heavy Opus week looked like an alert.
    enum ModelPalette {
        static let ramp: [Color] = [
            Color(red: 0.35, green: 0.55, blue: 0.78),  // slate blue
            Color(red: 0.45, green: 0.68, blue: 0.50),  // sage green
            Color(red: 0.62, green: 0.45, blue: 0.72),  // muted purple
            Color(red: 0.40, green: 0.65, blue: 0.70),  // teal
            Color(red: 0.60, green: 0.60, blue: 0.40),  // olive
            Color(red: 0.42, green: 0.45, blue: 0.75),  // indigo
            Color(red: 0.55, green: 0.58, blue: 0.62),  // steel grey
            Color(red: 0.70, green: 0.55, blue: 0.75),  // lilac
        ]
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

    // MARK: - Spacing (one vertical rhythm)

    /// Between metric rows / sections.
    static let rowSpacing: CGFloat = 12
    /// Title → bar → labels within a row.
    static let internalSpacing: CGFloat = 6
    /// Between stacked sub-lines.
    static let subLineSpacing: CGFloat = 2
}
