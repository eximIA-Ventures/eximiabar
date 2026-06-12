import Charts
import ClaudeBarCore
import SwiftUI

/// The loading / loaded / empty / disabled states of the dashboard (EXB-2.3 / EXB-3.2).
enum DashboardState: Equatable {
    case loading
    case loaded(DashboardData)
    case empty
    case disabled
}

/// The local analytics dashboard (EXB-3.2).
///
/// A pure function of `state` + `period` plus action callbacks. The window controller owns the state
/// and flips it from `.loading` → `.loaded`/`.empty`/`.disabled` once the off-main scan completes, so
/// this view never does I/O. Charts use Swift Charts, which ships with the macOS SDK.
struct DashboardView: View {
    let state: DashboardState
    var period: DashboardPeriod = .thirtyDays
    var selectPeriod: (DashboardPeriod) -> Void = { _ in }
    var exportCSV: () -> Void = {}
    var openSettings: () -> Void = {}

    /// `true` when an export button should be enabled (only when loaded with data).
    private var canExport: Bool {
        if case let .loaded(data) = state { return !data.isEmpty }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // AC1: the period filter + export button stay pinned at the top for every state.
            DashboardToolbar(
                period: period,
                selectPeriod: selectPeriod,
                exportCSV: exportCSV,
                canExport: canExport)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disabled:
            DisabledStateView(openSettings: openSettings)
        case .empty:
            CenteredMessageView(systemImage: "tray", message: L("dashboard.empty.message"))
        case let .loaded(data):
            if data.isEmpty {
                CenteredMessageView(systemImage: "tray", message: L("dashboard.empty.message"))
            } else {
                LoadedDashboard(data: data)
            }
        }
    }
}

// MARK: - Toolbar (AC1/AC9)

private struct DashboardToolbar: View {
    let period: DashboardPeriod
    let selectPeriod: (DashboardPeriod) -> Void
    let exportCSV: () -> Void
    let canExport: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { period }, set: { selectPeriod($0) })) {
                ForEach(DashboardPeriod.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                exportCSV()
            } label: {
                Label(L("dashboard.export.csv"), systemImage: "square.and.arrow.up")
            }
            .disabled(!canExport)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - Loaded content

private struct LoadedDashboard: View {
    let data: DashboardData

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                SummaryCardsRow(data: data)                       // AC2
                CostPerDayChart(entries: data.dailyCosts)         // AC3
                StackedTokensChart(entries: data.dailyTokens)     // AC4
                ModelBreakdownSection(rows: data.byModel)         // AC5
                if !data.byProject.isEmpty {
                    ProjectBreakdownTable(rows: data.byProject)   // AC6
                }
                ActivityHeatmapChart(heatmap: data.heatmap)       // AC7
                if !data.topSessions.isEmpty {
                    TopSessionsTable(rows: data.topSessions)      // AC8
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Summary cards (AC2)

private struct SummaryCardsRow: View {
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            SummaryCard(title: L("dashboard.summary.today"), cost: data.todayCost, tokens: data.todayTokens)
            SummaryCard(title: L("dashboard.summary.last_7_days"), cost: data.sevenDayCost, tokens: data.sevenDayTokens)
            SummaryCard(title: L("dashboard.summary.last_30_days"), cost: data.thirtyDayCost, tokens: data.thirtyDayTokens)
            SummaryCard(title: L("dashboard.summary.avg_daily"), cost: data.averageDailyCost, tokens: nil)
            SummaryCard(title: L("dashboard.summary.projection"), cost: data.monthProjection, tokens: nil)
        }
    }
}

/// One summary card: title `.headline`, cost `.title2.bold`, optional tokens footnote (AC2).
private struct SummaryCard: View {
    let title: String
    let cost: Double
    let tokens: Int?

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
            if let tokens {
                Text(L("dashboard.summary.tokens", PopoverFormatter.tokenCount(tokens)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.footnote)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Cost-per-day + cumulative line (AC3)

private struct CostPerDayChart: View {
    let entries: [DashboardDailyEntry]

    /// First/last calendar day for a sparse X axis.
    static func endpointDates(_ entries: [DashboardDailyEntry]) -> [Date] {
        guard let first = entries.first?.date, let last = entries.last?.date else { return [] }
        return first == last ? [first] : [first, last]
    }

    /// Running cumulative cost over the window — the overlay line (AC3).
    private var cumulative: [(date: Date, total: Double)] {
        var running = 0.0
        return entries.map { entry in
            running += entry.costUSD
            return (entry.date, running)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.chart.cost.title"))
                .font(.headline)
            Chart {
                ForEach(entries, id: \.date) { entry in
                    BarMark(
                        x: .value(L("dashboard.chart.axis.date"), entry.date, unit: .day),
                        y: .value(L("dashboard.chart.cost.y_label"), entry.costUSD))
                        .foregroundStyle(PopoverStyle.brand)
                }
                ForEach(cumulative, id: \.date) { point in
                    LineMark(
                        x: .value(L("dashboard.chart.axis.date"), point.date, unit: .day),
                        y: .value(L("dashboard.chart.cost.cumulative"), point.total),
                        series: .value("Series", "cumulative"))
                        .foregroundStyle(.secondary)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks(values: Self.endpointDates(entries)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxisLabel(L("dashboard.chart.cost.y_label"))
            .frame(height: 180)
        }
    }
}

// MARK: - Stacked tokens chart (AC4)

private struct StackedTokensChart: View {
    let entries: [DashboardDailyEntry]

    /// One stacked slice per (day, token type). Flattened so Swift Charts can colour by type.
    private struct Slice: Identifiable {
        let id = UUID()
        let date: Date
        let type: TokenType
        let tokens: Int
    }

    private enum TokenType: String, CaseIterable {
        case input, output, cacheRead, cacheWrite

        var label: String {
            switch self {
            case .input: return L("dashboard.tokens.input")
            case .output: return L("dashboard.tokens.output")
            case .cacheRead: return L("dashboard.tokens.cache_read")
            case .cacheWrite: return L("dashboard.tokens.cache_write")
            }
        }
    }

    private var slices: [Slice] {
        entries.flatMap { entry -> [Slice] in
            [
                Slice(date: entry.date, type: .input, tokens: entry.inputTokens),
                Slice(date: entry.date, type: .output, tokens: entry.outputTokens),
                Slice(date: entry.date, type: .cacheRead, tokens: entry.cacheReadTokens),
                Slice(date: entry.date, type: .cacheWrite, tokens: entry.cacheWriteTokens),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.chart.tokens.title"))
                .font(.headline)
            Chart(slices) { slice in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), slice.date, unit: .day),
                    y: .value(L("dashboard.chart.tokens.y_label"), slice.tokens))
                    .foregroundStyle(by: .value(L("dashboard.tokens.type"), slice.type.label))
            }
            .chartXAxis {
                AxisMarks(values: CostPerDayChart.endpointDates(entries)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxisLabel(L("dashboard.chart.tokens.y_label"))
            .chartLegend(position: .bottom)
            .frame(height: 200)
        }
    }
}

// MARK: - Model breakdown: donut + table (AC5)

private struct ModelBreakdownSection: View {
    let rows: [DashboardModelEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("dashboard.models.title"))
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                ModelCostDonut(rows: rows)
                    .frame(width: 160, height: 160)
                ModelBreakdownTable(rows: rows)
            }
        }
    }
}

/// Donut (SectorMark) of per-model cost share (AC5).
private struct ModelCostDonut: View {
    let rows: [DashboardModelEntry]

    var body: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value(L("dashboard.models.col.cost"), row.costUSD),
                innerRadius: .ratio(0.6),
                angularInset: 1.5)
                .foregroundStyle(by: .value(L("dashboard.models.col.model"), row.model))
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
    }
}

/// Per-model totals, sorted by cost desc. Columns: model · input · output · cost (AC5).
private struct ModelBreakdownTable: View {
    let rows: [DashboardModelEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

// MARK: - Project breakdown table (AC6)

private struct ProjectBreakdownTable: View {
    let rows: [ProjectUsageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("dashboard.projects.title"))
                .font(.headline)

            HStack(spacing: 8) {
                Text(L("dashboard.projects.col.project"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("dashboard.projects.col.cost"))
                    .frame(width: 80, alignment: .trailing)
                Text(L("dashboard.projects.col.tokens"))
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.project)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PopoverFormatter.currency(row.costUSD))
                        .frame(width: 80, alignment: .trailing)
                        .monospacedDigit()
                    Text(PopoverFormatter.tokenCount(row.totalTokens))
                        .frame(width: 80, alignment: .trailing)
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

// MARK: - Activity heatmap (AC7)

private struct ActivityHeatmapChart: View {
    let heatmap: [[HeatmapBucket]]

    private var cells: [HeatmapBucket] { heatmap.flatMap { $0 } }
    private var maxTokens: Int { max(1, cells.map(\.tokens).max() ?? 1) }

    /// Localized weekday short labels, Sun…Sat, ordered to match `weekday` 0…6.
    private static let weekdaySymbols: [String] = {
        var cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols // index 0 = Sunday in Gregorian
        return symbols
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.heatmap.title"))
                .font(.headline)
            Chart {
                ForEach(cells, id: \.cellID) { cell in
                    RectangleMark(
                        x: .value(L("dashboard.heatmap.hour"), cell.hour),
                        y: .value(L("dashboard.heatmap.day"), Self.weekdaySymbols[safe: cell.weekday] ?? "\(cell.weekday)"))
                        .foregroundStyle(by: .value(L("dashboard.heatmap.tokens"), cell.tokens))
                }
            }
            .chartForegroundStyleScale(range: Gradient(colors: [
                Color(nsColor: .controlBackgroundColor),
                PopoverStyle.brand,
            ]))
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d", hour))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading)
            }
            .chartLegend(.hidden)
            .frame(height: 200)
        }
    }
}

// MARK: - Top sessions (AC8)

private struct TopSessionsTable: View {
    let rows: [SessionUsageEntry]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("dashboard.sessions.title"))
                .font(.headline)

            HStack(spacing: 8) {
                Text(L("dashboard.sessions.col.date"))
                    .frame(width: 56, alignment: .leading)
                Text(L("dashboard.sessions.col.project"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("dashboard.sessions.col.model"))
                    .frame(width: 110, alignment: .leading)
                Text(L("dashboard.sessions.col.tokens"))
                    .frame(width: 64, alignment: .trailing)
                Text(L("dashboard.sessions.col.cost"))
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: row.date))
                        .frame(width: 56, alignment: .leading)
                    Text(row.project)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.dominantModel)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PopoverFormatter.tokenCount(row.totalTokens))
                        .frame(width: 64, alignment: .trailing)
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

// MARK: - Empty / disabled states

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

// MARK: - Helpers

private extension Array {
    /// Safe indexed access (out-of-range → `nil`).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension HeatmapBucket {
    /// Stable identity for `ForEach` in the heatmap chart.
    var cellID: String { "\(weekday)-\(hour)" }
}
