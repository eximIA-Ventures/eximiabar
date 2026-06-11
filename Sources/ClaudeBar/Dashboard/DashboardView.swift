import Charts
import ClaudeBarCore
import SwiftUI

/// The loading / loaded / empty / disabled states of the dashboard (EXB-2.3 T3).
enum DashboardState: Equatable {
    /// Scan in flight — show a centered `ProgressView` (AC3/AC8).
    case loading
    /// Scan complete with data.
    case loaded(DashboardData)
    /// Scan returned zero entries (AC10).
    case empty
    /// Cost tracking is off in Settings (AC9).
    case disabled
}

/// The local usage dashboard (EXB-2.3 AC3–AC10).
///
/// A pure function of `state` plus two action callbacks. The window controller owns the state and
/// flips it from `.loading` → `.loaded`/`.empty`/`.disabled` once the off-main scan completes (AC8),
/// so this view never does I/O. Charts use Swift Charts (`Charts`), which ships with the macOS SDK —
/// no extra dependency (AC12).
struct DashboardView: View {
    let state: DashboardState
    /// Opens the Settings window (AC9 "Open Settings" button).
    var openSettings: () -> Void = {}

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .disabled:
                DisabledStateView(openSettings: openSettings)
            case .empty:
                CenteredMessageView(
                    systemImage: "tray",
                    message: L("dashboard.empty.message"))
            case let .loaded(data):
                if data.isEmpty {
                    CenteredMessageView(
                        systemImage: "tray",
                        message: L("dashboard.empty.message"))
                } else {
                    LoadedDashboard(data: data)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loaded content

private struct LoadedDashboard: View {
    let data: DashboardData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SummaryCardsRow(data: data)        // AC7
                CostPerDayChart(entries: data.dailyCosts)   // AC4
                TokensPerDayChart(entries: data.dailyTokens) // AC5
                ModelBreakdownTable(rows: data.byModel)      // AC6
            }
            .padding(20)
        }
    }
}

// MARK: - Summary cards (AC7)

private struct SummaryCardsRow: View {
    let data: DashboardData

    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: L("dashboard.summary.today"),
                cost: data.todayCost,
                tokens: data.todayTokens)
            SummaryCard(
                title: L("dashboard.summary.last_7_days"),
                cost: data.sevenDayCost,
                tokens: data.sevenDayTokens)
            SummaryCard(
                title: L("dashboard.summary.last_30_days"),
                cost: data.thirtyDayCost,
                tokens: data.thirtyDayTokens)
        }
    }
}

/// One summary card: title `.headline`, cost `.title2.bold`, tokens `.footnote.secondary` (AC7).
private struct SummaryCard: View {
    let title: String
    let cost: Double
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(PopoverFormatter.currency(cost))
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L("dashboard.summary.tokens", PopoverFormatter.tokenCount(tokens)))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Charts (AC4/AC5)

/// Cost-per-day bar chart (AC4). Brand-colored bars, USD Y axis, first/last date labels only.
private struct CostPerDayChart: View {
    let entries: [DashboardDailyEntry]

    /// The first and last calendar day in the window (deduped when there is a single entry) — used as
    /// the X-axis label values so the axis is not crowded (AC4/AC5).
    static func endpointDates(_ entries: [DashboardDailyEntry]) -> [Date] {
        guard let first = entries.first?.date, let last = entries.last?.date else { return [] }
        return first == last ? [first] : [first, last]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.chart.cost.title"))
                .font(.headline)
            Chart(entries, id: \.date) { entry in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), entry.date, unit: .day),
                    y: .value("USD", entry.costUSD))
                    .foregroundStyle(PopoverStyle.brand)
            }
            .chartXAxis {
                // AC4: label only the first and last calendar day to avoid crowding.
                AxisMarks(values: Self.endpointDates(entries)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxisLabel(L("dashboard.chart.cost.y_label"))
            .frame(height: 160)
        }
    }
}

/// Tokens-per-day bar chart (AC5). Same date axis; Y plots combined input + output tokens.
private struct TokensPerDayChart: View {
    let entries: [DashboardDailyEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.chart.tokens.title"))
                .font(.headline)
            Chart(entries, id: \.date) { entry in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), entry.date, unit: .day),
                    y: .value("Tokens", Double(entry.tokens)))
                    .foregroundStyle(PopoverStyle.brand)
            }
            .chartXAxis {
                // AC5: same first/last date label treatment as the cost chart.
                AxisMarks(values: CostPerDayChart.endpointDates(entries)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxisLabel(L("dashboard.chart.tokens.y_label"))
            .frame(height: 160)
        }
    }
}

// MARK: - Model breakdown (AC6)

/// 30-day per-model totals, sorted by cost desc. Columns: model · input · output · cost (AC6).
private struct ModelBreakdownTable: View {
    let rows: [DashboardModelEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("dashboard.models.title"))
                .font(.headline)

            // Header row.
            HStack(spacing: 8) {
                Text(L("dashboard.models.col.model"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("dashboard.models.col.input"))
                    .frame(width: 70, alignment: .trailing)
                Text(L("dashboard.models.col.output"))
                    .frame(width: 70, alignment: .trailing)
                Text(L("dashboard.models.col.cost"))
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PopoverFormatter.tokenCount(row.inputTokens))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                    Text(PopoverFormatter.tokenCount(row.outputTokens))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                    Text(PopoverFormatter.currency(row.costUSD))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Empty / disabled states (AC9/AC10)

private struct CenteredMessageView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AC9: cost tracking disabled — message plus an "Open Settings" button.
private struct DisabledStateView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L("dashboard.disabled.message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("dashboard.disabled.open_settings"), action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
