import ClaudeBarCore
import SwiftUI

/// A single usage metric row: title → progress bar → `"N% left"` + `"Resets HH:mm"`, with an
/// optional pace line below the bar (AC9–AC13).
///
/// Adapted from `_reference_codexbar/Sources/CodexBar/MenuCardView.swift:383-452`. Consumes the
/// repo's `RateWindow` (`utilization` 0–100, non-optional `windowMinutes`) directly rather than the
/// reference's `Model.Metric` view-model.
struct MetricRow: View {
    let title: String
    let window: RateWindow
    var showPace: Bool = false
    var pace: UsagePace? = nil
    var paceDetail: UsagePaceText.Detail? = nil
    /// Warning markers (percent-remaining positions, e.g. 50, 20).
    var warningMarkerPercents: [Double] = []

    private var remaining: Double { min(100, max(0, self.window.remaining)) }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            Text(self.title)
                .font(.body)
                .fontWeight(.medium)

            UsageProgressBar(
                percent: self.window.utilization,
                accessibilityLabel: L("popover.metric.usage_accessibility", self.title),
                pacePercent: self.showPace ? self.paceDetail?.pacePercent : nil,
                paceReserve: self.paceDetail?.isReserve ?? true,
                warningMarkerPercents: self.warningMarkerPercents)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("popover.metric.percent_left", Int(self.remaining.rounded())))
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    if let resetText = PopoverFormatter.resetText(for: self.window.resetsAt) {
                        Text(resetText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Pace line below the bar (AC10/AC13) — Weekly row only (showPace == true).
                if self.showPace, let detail = self.paceDetail {
                    HStack(alignment: .firstTextBaseline) {
                        Text(detail.primary)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        if let secondary = detail.secondary {
                            Text(secondary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
