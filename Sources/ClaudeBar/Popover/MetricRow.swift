import ClaudeBarCore
import SwiftUI

/// A single usage metric row, redesigned (EXB redesign): a headline (title + big usage number),
/// the progress bar, then a compact sub-line (reset, and a forecast only when it is an alarm).
///
/// The big number is the section's one primary datum; its size descends by `prominence` so the
/// session row dominates and per-model sub-windows recede (Ive's autocracy of weight). The number
/// and the bar carry a semantic zone colour (terracotta / amber / red) driven by `utilization`, so
/// colour signals risk rather than just brand (the signifier Norman asks for).
struct MetricRow: View {
    /// Visual weight of the row — drives the headline number size (EXB redesign #1).
    enum Prominence {
        case primary    // Session — the star
        case secondary  // Weekly
        case compact    // Sonnet / Opus (per-model sub-windows)

        var numberFont: Font {
            switch self {
            case .primary: return .system(size: 22, weight: .bold, design: .rounded)
            case .secondary: return .system(size: 17, weight: .semibold, design: .rounded)
            case .compact: return .system(size: 13, weight: .semibold, design: .rounded)
            }
        }

        var titleFont: Font {
            switch self {
            case .primary, .secondary: return .caption2.weight(.semibold)
            case .compact: return .caption
            }
        }
    }

    let title: String
    let window: RateWindow
    var showPace: Bool = false
    var pace: UsagePace? = nil
    var paceDetail: UsagePaceText.Detail? = nil
    /// Warning markers (percent-remaining positions, e.g. 50, 20).
    var warningMarkerPercents: [Double] = []
    /// Bars fill with the consumed quota (`true`) vs the remaining quota (`false`) —
    /// `SettingsStore.showUsed`. The headline number follows the bar so the two always agree.
    var showUsed: Bool = true
    /// Reset line as an absolute clock (`true`) vs a countdown (`false`) — `SettingsStore.showAbsoluteReset`.
    var showAbsoluteReset: Bool = true
    /// Visual weight of this row (EXB redesign #1).
    var prominence: Prominence = .secondary
    /// How pace is shown: `.bar` draws the stripe on the bar; `.text` hides the stripe (the forecast
    /// text carries the pace instead). Only affects rows that have a pace (Weekly).
    var paceMode: PaceDisplayMode = .bar
    /// Forecast line, already gated by `MetricsSection` (alarm-only in `.bar` mode, always in
    /// `.text` mode), or `nil` to render nothing.
    var forecastText: String? = nil

    /// The active popover skin, injected by `UsageCardView`. Decides whether the healthy `< 70` zone
    /// reads terracotta (classic) or amber (meter); attention/critical are shared across themes.
    @Environment(\.popoverTheme) private var popoverTheme

    private var remaining: Double { min(100, max(0, self.window.remaining)) }

    /// The number shown in the headline: consumed or remaining per `showUsed`, matching the bar fill
    /// so the text and the graphic tell one story.
    private var headlineValue: Int {
        Int((self.showUsed ? self.window.utilization : self.remaining).rounded())
    }

    /// Whether the bar is currently drawing a pace marker — `.bar` mode with a resolved pace detail.
    /// The pace text in the sub-line and the marker on the bar are shown together (the number is on
    /// the line, the position is on the bar); the two never disagree.
    private var hasBarPace: Bool {
        self.showPace && self.paceMode == .bar && self.paceDetail != nil
    }

    /// The enriched pace status line (`"folga no ritmo - 74%"`), shown only when the bar carries a
    /// pace marker. `nil` otherwise (Session row, `.text` mode, or no pace).
    private var paceLineText: String? {
        guard self.hasBarPace else { return nil }
        return self.paceDetail?.primary
    }

    /// `true` when the current pace is a deficit (over-pace) — drives the alert colour of the line.
    private var paceIsDeficit: Bool {
        guard let detail = self.paceDetail else { return false }
        return !detail.isReserve
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            // Headline: title (left) + big usage number (right), same baseline (#1). The number is
            // the anchor the eye falls on first; the zone colour is decided by consumed % (risk).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.title)
                    .font(self.prominence.titleFont)
                    .foregroundStyle(.secondary)
                    .tracking(DesignTokens.sectionTracking)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(verbatim: "\(self.headlineValue)%")
                    .font(self.prominence.numberFont)
                    .foregroundStyle(PopoverStyle.zoneTextColor(utilization: self.window.utilization, theme: self.popoverTheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            UsageProgressBar(
                percent: self.showUsed ? self.window.utilization : self.window.remaining,
                tint: PopoverStyle.zoneBarColor(utilization: self.window.utilization, theme: self.popoverTheme),
                accessibilityLabel: L("popover.metric.usage_accessibility", self.title),
                pacePercent: (self.showPace && self.paceMode == .bar) ? self.paceDetail?.pacePercent : nil,
                paceReserve: self.paceDetail?.isReserve ?? true,
                warningMarkerPercents: self.warningMarkerPercents)

            VStack(alignment: .leading, spacing: 2) {
                // Pace line (#bar mode): the pace number now lives here (the bar carries the marker,
                // not a number), enriching the status into "folga no ritmo - 74%". Reserve reads in
                // `.secondary`; deficit reads in the zone colour so the alert weight matches the bar.
                if let paceText = self.paceLineText {
                    Text(paceText)
                        .font(.caption)
                        .foregroundStyle(self.paceIsDeficit
                            ? PopoverStyle.zoneTextColor(utilization: self.window.utilization, theme: self.popoverTheme)
                            : Color.secondary)
                        .lineLimit(1)
                }

                if let resetText = PopoverFormatter.resetText(
                    for: self.window.resetsAt, absolute: self.showAbsoluteReset)
                {
                    Text(resetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Forecast: shown only when MetricsSection's gate deems it a real alarm (#4), and
                // painted in the zone colour so it reads as critical — consistent with headline + bar.
                if let forecastText = self.forecastText {
                    Text(forecastText)
                        .font(.caption)
                        .foregroundStyle(PopoverStyle.zoneTextColor(utilization: self.window.utilization, theme: self.popoverTheme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
