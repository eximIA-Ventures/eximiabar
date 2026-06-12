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
    /// `true` while a background scan is in flight with content already on screen (EXB-3.6 AC3) — the
    /// view keeps the existing charts and floats a non-blocking refresh indicator over them.
    var isRefreshing: Bool = false
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
                // AC3: floating, non-blocking refresh banner so a period switch never looks frozen.
                .overlay(alignment: .top) {
                    if isRefreshing {
                        RefreshBanner()
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(L("dashboard.loading.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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

// MARK: - Refresh banner (AC3)

/// A small, glassy "Carregando…" pill shown over existing content while a period switch scans
/// (EXB-3.6 AC3). Non-blocking — the charts behind it stay interactive.
private struct RefreshBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("dashboard.loading.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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

// MARK: - Shared formatting & layout (EXB-3.6 AC6/AC10/AC13)

/// Static formatters + axis label helpers for the dashboard. All instances are `static let` so they
/// are created **once** for the whole view tree — never inside a `body` or chart closure (AC6,
/// anti-freeze). Pure functions; safe to call from any thread.
enum DashboardFormat {
    /// `dd/MM` day-axis / subtitle formatter (AC10/AC13).
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "dd/MM"
        return f
    }()

    /// `"01/06 – 12/06"` style date-range subtitle for a section header (AC13).
    static func rangeSubtitle(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "" }
        return "\(dayMonth.string(from: start)) – \(dayMonth.string(from: end))"
    }

    /// Y-axis cost label (AC10): `$0.00` below $1, `$X.XK` at/above $1 000, plain `$X.XX` between.
    static func axisCurrency(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        if abs < 1 { return String(format: "$%.2f", value) }
        return String(format: "$%.2f", value)
    }

    /// Y-axis token label (AC10): `XK` (thousands) / `XM` (millions) / plain.
    static func axisTokens(_ value: Int) -> String {
        let abs = Swift.abs(value)
        if abs >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if abs >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Cost with 4 decimal places for the hover annotation (AC11).
    static func preciseCurrency(_ value: Double) -> String { String(format: "$%.4f", value) }
}

/// The window's stable per-model colour palette (AC12). A fixed ramp seeded on the brand colour so
/// the *same* model index maps to the *same* swatch in the donut, the table and the stacked chart.
enum DashboardPalette {
    /// Ordered swatch ramp. Index *N* → model *N* (models pre-sorted by cost in `DashboardData`).
    static let ramp: [Color] = [
        PopoverStyle.brand,                                   // #CC7C5E brand
        Color(red: 0.35, green: 0.55, blue: 0.78),           // slate blue
        Color(red: 0.45, green: 0.68, blue: 0.50),           // sage green
        Color(red: 0.78, green: 0.58, blue: 0.30),           // amber
        Color(red: 0.62, green: 0.45, blue: 0.72),           // muted purple
        Color(red: 0.80, green: 0.45, blue: 0.50),           // dusty rose
        Color(red: 0.40, green: 0.65, blue: 0.70),           // teal
        Color(red: 0.60, green: 0.60, blue: 0.40),           // olive
    ]

    /// Colour for model at sorted position `index`, cycling the ramp for >8 models.
    static func color(at index: Int) -> Color { ramp[index % ramp.count] }

    /// `(domain, range)` for `chartForegroundStyleScale` — the models in their stable cost order and
    /// the matching swatches.
    static func scale(for models: [String]) -> (domain: [String], range: [Color]) {
        (models, models.indices.map { color(at: $0) })
    }
}

/// A section header: bold title + a secondary date-range subtitle (AC13), with an optional trailing
/// "Total: …" highlight number (AC14).
private struct DashboardSectionHeader: View {
    let title: String
    var subtitle: String = ""
    var total: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let total {
                Text(total)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Elegant empty state shown inside a chart card when the window has no data (AC15).
private struct ChartEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

// MARK: - Loaded content

private struct LoadedDashboard: View {
    let data: DashboardData

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                SummaryCardsRow(data: data)                       // AC2
                CostPerDayChart(data: data)                       // AC3/AC10/AC11/AC13/AC14
                StackedTokensChart(data: data)                    // AC4/AC9/AC10/AC13/AC14
                ModelBreakdownSection(data: data)                 // AC5/AC12/AC13
                if !data.byProject.isEmpty {
                    ProjectBreakdownTable(rows: data.byProject)   // AC6
                }
                ActivityHeatmapChart(data: data)                  // AC7/AC9/AC13/AC14
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
    let data: DashboardData
    private var entries: [DashboardDailyEntry] { data.dailyCosts }

    /// The day the user is hovering, if any (AC11).
    @State private var selectedDate: Date?

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

    /// The entry under the current hover, snapped to the nearest day (AC11).
    private var selectedEntry: DashboardDailyEntry? {
        guard let selectedDate else { return nil }
        let cal = Calendar.current
        let target = cal.startOfDay(for: selectedDate)
        return entries.first { $0.date == target }
    }

    private var hasData: Bool { entries.contains { $0.costUSD > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.chart.cost.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                total: L("dashboard.total.cost", PopoverFormatter.currency(data.totalCost)))
            if hasData {
                chart
            } else {
                ChartEmptyState(systemImage: "chart.bar.xaxis", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(entries, id: \.date) { entry in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), entry.date, unit: .day),
                    y: .value(L("dashboard.chart.cost.y_label"), entry.costUSD))
                    .foregroundStyle(PopoverStyle.brand)
                    .opacity(selectedDate == nil || selectedEntry?.date == entry.date ? 1 : 0.4)
            }
            ForEach(cumulative, id: \.date) { point in
                LineMark(
                    x: .value(L("dashboard.chart.axis.date"), point.date, unit: .day),
                    y: .value(L("dashboard.chart.cost.cumulative"), point.total),
                    series: .value("Series", L("dashboard.chart.cost.cumulative")))
                    .foregroundStyle(.secondary)
                    .interpolationMethod(.monotone)
            }
            if let selectedEntry {
                RuleMark(x: .value(L("dashboard.chart.axis.date"), selectedEntry.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HoverAnnotation(
                            date: selectedEntry.date,
                            primary: DashboardFormat.preciseCurrency(selectedEntry.costUSD),
                            secondary: L("dashboard.summary.tokens", PopoverFormatter.tokenCount(selectedEntry.tokens)))
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: Self.endpointDates(entries)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(DashboardFormat.dayMonth.string(from: date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(DashboardFormat.axisCurrency(cost))
                    }
                }
            }
        }
        .chartYAxisLabel(L("dashboard.chart.cost.y_label"))
        .chartLegend(.visible)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotAnchor = proxy.plotFrame else { selectedDate = nil; return }
                            let origin = geo[plotAnchor].origin
                            let xInPlot = location.x - origin.x
                            selectedDate = proxy.value(atX: xInPlot, as: Date.self)
                        case .ended:
                            selectedDate = nil
                        }
                    }
            }
        }
        .frame(height: 200)
    }
}

/// Tooltip body for chart hover (AC11): date + a precise primary value + a secondary line.
private struct HoverAnnotation: View {
    let date: Date
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DashboardFormat.dayMonth.string(from: date))
                .font(.caption.bold())
            Text(primary)
                .font(.callout.monospacedDigit())
            Text(secondary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

// MARK: - Stacked tokens chart (AC4)

private struct StackedTokensChart: View {
    let data: DashboardData
    private var entries: [DashboardDailyEntry] { data.dailyTokens }

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

    private var hasData: Bool { slices.contains { $0.tokens > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.chart.tokens.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                total: L("dashboard.total.tokens", PopoverFormatter.tokenCount(data.totalTokens)))
            if hasData {
                chart
            } else {
                ChartEmptyState(systemImage: "square.stack.3d.up", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
        Chart(slices) { slice in
            BarMark(
                x: .value(L("dashboard.chart.axis.date"), slice.date, unit: .day),
                y: .value(L("dashboard.chart.tokens.y_label"), slice.tokens))
                .foregroundStyle(by: .value(L("dashboard.tokens.type"), slice.type.label))
        }
        .chartXAxis {
            AxisMarks(values: CostPerDayChart.endpointDates(entries)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(DashboardFormat.dayMonth.string(from: date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(DashboardFormat.axisTokens(tokens))
                    }
                }
            }
        }
        .chartYAxisLabel(L("dashboard.chart.tokens.y_label"))
        .chartLegend(.visible)
        .frame(height: 220)
    }
}

// MARK: - Model breakdown: donut + table (AC5)

private struct ModelBreakdownSection: View {
    let data: DashboardData
    private var rows: [DashboardModelEntry] { data.byModel }

    /// Stable model→colour scale shared by the donut and the table swatches (AC12).
    private var colorScale: (domain: [String], range: [Color]) {
        DashboardPalette.scale(for: data.sortedModelNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSectionHeader(
                title: L("dashboard.models.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd))
            HStack(alignment: .top, spacing: 16) {
                ModelCostDonut(rows: rows, scale: colorScale)
                    .frame(width: 160, height: 160)
                ModelBreakdownTable(rows: rows, scale: colorScale)
            }
        }
    }
}

/// Donut (SectorMark) of per-model cost share (AC5), coloured by the shared scale (AC12).
private struct ModelCostDonut: View {
    let rows: [DashboardModelEntry]
    let scale: (domain: [String], range: [Color])

    var body: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value(L("dashboard.models.col.cost"), row.costUSD),
                innerRadius: .ratio(0.6),
                angularInset: 1.5)
                .foregroundStyle(by: .value(L("dashboard.models.col.model"), row.model))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(.hidden)
    }
}

/// Per-model totals, sorted by cost desc. Columns: swatch · model · input · output · cost (AC5/AC12).
private struct ModelBreakdownTable: View {
    let rows: [DashboardModelEntry]
    let scale: (domain: [String], range: [Color])

    /// Colour for a model from the shared scale (matches the donut swatch, AC12).
    private func color(for model: String) -> Color {
        guard let idx = scale.domain.firstIndex(of: model) else { return .secondary }
        return scale.range[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("")
                    .frame(width: 10)
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
                    Circle()
                        .fill(color(for: row.model))
                        .frame(width: 10, height: 10)
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
    let data: DashboardData
    private var heatmap: [[HeatmapBucket]] { data.heatmap }

    private var cells: [HeatmapBucket] { heatmap.flatMap { $0 } }
    private var hasData: Bool { cells.contains { $0.tokens > 0 } }

    /// Localized weekday short labels, Sun…Sat, ordered to match `weekday` 0…6.
    private static let weekdaySymbols: [String] = {
        var cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols // index 0 = Sunday in Gregorian
        return symbols
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.heatmap.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                total: L("dashboard.total.tokens", PopoverFormatter.tokenCount(data.totalHeatmapTokens)))
            if hasData {
                chart
            } else {
                ChartEmptyState(systemImage: "flame", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
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
        // AC9: surface the token-intensity scale so the colour ramp is legible.
        .chartLegend(.visible)
        .frame(height: 220)
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
