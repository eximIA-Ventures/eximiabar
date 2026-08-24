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
    /// The shortcut currently lit, or `nil` after the Senhor dragged his own range (EXB-5.8 §8).
    var atalho: DashboardPeriod? = .thirtyDays
    /// `true` while a background scan is in flight with content already on screen (EXB-3.6 AC3) — the
    /// view keeps the existing charts and floats a non-blocking refresh indicator over them.
    var isRefreshing: Bool = false
    var selectPeriod: (DashboardPeriod) -> Void = { _ in }
    /// A range dragged over the timeline. Writes into the same span the shortcuts write into — that
    /// is what keeps a button and a drag from being two different questions (EXB-5.8 §8).
    var selectRange: (ClosedRange<Date>) -> Void = { _ in }
    /// Opens the export panel. Named for what it does, not for one of the three formats it offers —
    /// `exportCSV` stopped being true the moment CSV became an option rather than the operation.
    var exportar: () -> Void = {}
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
                atalho: atalho,
                selectPeriod: selectPeriod,
                exportar: exportar,
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
                LoadedDashboard(data: data, selectRange: selectRange)
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
    /// `nil` means no shortcut is lit because the range on screen was dragged (EXB-5.8 §8). The
    /// segmented control then shows nothing selected, which is honest: none of the three buttons
    /// describes what is being displayed.
    let atalho: DashboardPeriod?
    let selectPeriod: (DashboardPeriod) -> Void
    let exportar: () -> Void
    let canExport: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding<DashboardPeriod?>(
                get: { atalho },
                set: { if let novo = $0 { selectPeriod(novo) } }))
            {
                ForEach(DashboardPeriod.allCases) { option in
                    Text(option.label).tag(Optional(option))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                exportar()
            } label: {
                // The button opens a picker of three formats. Saying "Exportar CSV" on it was a label
                // that lied about its own click — the same class of defect as a number whose divisor
                // is invisible, and it earns no more patience than one.
                Label(L("dashboard.export"), systemImage: "square.and.arrow.up")
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

    /// `24/08/2026` — the form a person reads in the coverage block (EXB-5.9).
    ///
    /// **Built from `Calendar` components, not a `DateFormatter`, and that is deliberate.** A
    /// formatter resolves its pattern against the machine's locale, so the same date prints
    /// differently on a Mac set to another region and any test pinning the string passes here and
    /// fails there — with no message saying why. The panel's `PainelDatas.longa` writes the digits by
    /// hand for exactly this reason, and prints exactly this shape: the coverage block on screen and
    /// the coverage block in the exported `painel.html` state the same date the same way, so the two
    /// can be compared without translating between them.
    ///
    /// The calendar stays `.current` because that is what `DashboardData.build` bucketed days with —
    /// a "day" has to mean the same thing here as it did there.
    static func longDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }

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

    /// Compact token count — the dashboard's single K/M/B formatting point (EXB-3.7 AC20).
    ///
    /// `XK` (thousands) / `X.XM` (millions) / `X.XB` (billions). Used by every dashboard token label,
    /// tooltip, KPI card and chart total so a value like `4_888_600_000` reads as `"4.9B"`, never as
    /// scientific notation (`"1.0E8"`) or an inflated millions count (`"4888.6M"`) — EXB-3.7 AC7/AC21.
    static func tokenCount(_ n: Int) -> String {
        let abs = Swift.abs(n)
        switch abs {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
    }

    /// Y-axis token label (AC10) with the EXB-3.7 billions threshold: `XK` / `X.XM` / `X.XB`.
    /// Routes through `tokenCount` so the axis, the heatmap legend and every tooltip share one ramp.
    static func axisTokens(_ value: Int) -> String { tokenCount(value) }

    /// Cost with 4 decimal places for the hover annotation (AC11).
    static func preciseCurrency(_ value: Double) -> String { String(format: "$%.4f", value) }

    /// A cache rate `0…1` as a one-decimal percentage that **truncates** (EXB-5.7 §3).
    ///
    /// Rounding is what let `0.9996` print as `100.0%` — an absolute the data never reached. One
    /// uncached token in two and a half million is still one uncached token, and a panel that rounds
    /// it away is asserting something it cannot back. `100.0%` now appears only at an exact 1.0.
    static func taxaCache(_ ratio: Double) -> String {
        let clamped = Swift.min(Swift.max(ratio, 0), 1)
        guard clamped < 1 else { return "100.0%" }
        return String(format: "%.1f%%", (clamped * 1_000).rounded(.down) / 10)
    }

    /// `"$1.6K"` / `"$3.20"` compact cost for chart-total headers + KPI cards (EXB-3.7 AC18/AC6).
    static func compactCurrency(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.2f", value)
    }

    /// `"Total: 4.9B tokens · $1.6K"` header line (EXB-3.7 AC18) — tokens-first, cost as context.
    static func totalTokensAndCost(_ tokens: Int, _ cost: Double) -> String {
        L("dashboard.total.tokens_cost", tokenCount(tokens), compactCurrency(cost))
    }

    /// Day-axis tick stride keeping labels readable (never truncated) at any span (EXB-3.7 AC8).
    ///
    /// Derived from the day count rather than switched on three named periods (EXB-5.8 §8): a dragged
    /// range can be any width, and a `switch` over buttons has no answer for 43 days. Caps the axis at
    /// 8 labels — 7d → every day, 30d → every 4, 120d → every 15.
    static func axisStride(forDays days: Int) -> Int {
        Swift.max(1, Int((Double(Swift.max(1, days)) / 8.0).rounded(.up)))
    }
}

/// The window's stable per-model colour palette (AC12). A fixed ramp seeded on the brand colour so
/// the *same* model index maps to the *same* swatch in the donut, the table and the stacked chart.
enum DashboardPalette {
    /// Ordered swatch ramp. Index *N* → model *N* (models pre-sorted by token volume, EXB-5.7 §6).
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

    /// Theme-aware ramp (v2.3.0): only the accent swatch (index 0) follows the popover theme —
    /// terracotta in classic, amber in meter. The rest are stable per-model identities, untouched.
    static func ramp(for theme: PopoverTheme) -> [Color] {
        guard theme == .meter else { return ramp }
        var themed = ramp
        themed[0] = DesignTokens.meterAccent
        return themed
    }

    static func color(at index: Int, theme: PopoverTheme) -> Color {
        let r = ramp(for: theme)
        return r[index % r.count]
    }

    /// `(domain, range)` for `chartForegroundStyleScale` — the models in their stable cost order and
    /// the matching swatches.
    static func scale(for models: [String]) -> (domain: [String], range: [Color]) {
        (models, models.indices.map { color(at: $0) })
    }

    /// Theme-aware `(domain, range)` — same stable model order, with the accent swatch following the
    /// active theme.
    static func scale(for models: [String], theme: PopoverTheme) -> (domain: [String], range: [Color]) {
        (models, models.indices.map { color(at: $0, theme: theme) })
    }
}

/// A section header: bold title + a secondary date-range subtitle (AC13), with an optional trailing
/// "Total: …" highlight number (AC14) and an optional explanatory line underneath.
///
/// The `explanation` line is what `painel.html` calls `p.sub`: one sentence saying what the chart is
/// actually plotting and where its axis starts. A chart that does not say "the axis begins at the
/// first covered date" is silently asking to be read as if it began at the window's first date.
private struct DashboardSectionHeader: View {
    let title: String
    var subtitle: String = ""
    var explanation: String = ""
    var total: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                        .font(.system(.title3, design: .rounded).bold().monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            if !explanation.isEmpty {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A named section band — the screen's top-level hierarchy, mirroring `h2.secao` in `painel.html`.
///
/// The screen used to have none: tokens and dollars sat in one undifferentiated grid of cards, so
/// nothing on it said which of the two was the quantity being consumed and which was an estimate.
/// Naming the sections is the cheapest way to say it, and it says it even to someone who reads no
/// further than the labels.
private struct DashboardSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Label.section)
            .tracking(DesignTokens.sectionTracking)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
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

/// The screen, in the order `painel.html` established (EXB-5.9).
///
/// **The order is the decision; the layout only carries it.** Coverage first, because a window the
/// source does not cover is the one thing that makes every number below it a lie. Then volume, because
/// the plan is a subscription and tokens are the quantity actually consumed. Then cost, labelled as an
/// estimate of value rather than a bill. The charts and tables follow.
///
/// Before this, the screen opened with a single grid that mixed tokens and dollars card by card and
/// never stated what the source covered — so the reader had to already know which number was the
/// headline and which was an estimate, and had no way at all to learn that a third of the window was
/// never observed.
private struct LoadedDashboard: View {
    let data: DashboardData
    var selectRange: (ClosedRange<Date>) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                CoverageBanner(data: data)                        // EXB-5.9: what the source covers
                VolumeSection(data: data)                         // the principal quantity
                CostSection(data: data)                           // the estimate, named as one
                // EXB-4.5 AC3: the "This week" wrapped recap — only in the 7-day period.
                if data.atalho == .sevenDays {
                    WeeklySummarySection(data: data)
                }
                DashboardSectionLabel(text: L("dashboard.section.charts"))
                // EXB-5.7 §6: tokens lead. The Senhor pays a subscription, so token volume is the
                // quantity he is actually spending; the dollar figure is an estimate of value
                // consumed, and it now reads as the supporting chart rather than the headline.
                StackedTokensChart(data: data, selectRange: selectRange)  // AC4/AC9/AC10 + §8 drag
                CostPerDayChart(data: data)                       // AC3/AC10/AC11/AC13/AC14
                ModelBreakdownSection(data: data)                 // AC5/AC12/AC13
                ModelsByDayChart(data: data)                      // EXB-3.7 AC4 (models per day)
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

// MARK: - Coverage banner (EXB-5.9) — the block that has to come first

/// What the source actually covers, stated before any number derived from it.
///
/// **Why this is at the top and not in a footnote.** The day axis is zero-filled across the whole
/// window, so a 30-day window over an archive reaching back 21 days carries 9 days of `0`. The charts
/// already refuse to draw those days (`DashboardDailyEntry.coberto`), but a reader who does not know
/// *why* the bars start late will read the gap as idleness. This block is the sentence that makes the
/// gap legible — and it names the same span the charts below it drew, because it reads the same flag.
private struct CoverageBanner: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private static func dayLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return DashboardFormat.longDate(date)
    }

    /// The one sentence that changes with the state of coverage — and the only place on the screen
    /// where "gap, not zero" is said in words.
    private var caveat: (text: String, tint: Color) {
        if data.primeiroDiaComDado == nil {
            return (L("dashboard.coverage.none"), DesignTokens.zoneCriticalText)
        }
        if data.cobreJanelaInteira {
            return (L("dashboard.coverage.full"), DesignTokens.roiPositive)
        }
        return (
            L("dashboard.coverage.partial", data.diasComDado, data.spanDays),
            DesignTokens.zoneAttentionText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionLabel(text: L("dashboard.coverage.title"))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                CoverageFact(
                    title: L("dashboard.coverage.first_day"),
                    value: Self.dayLabel(data.primeiroDiaComDado))
                CoverageFact(
                    title: L("dashboard.coverage.last_day"),
                    value: Self.dayLabel(data.ultimoDiaComDado))
                CoverageFact(
                    title: L("dashboard.coverage.days_with"),
                    value: "\(data.diasComDado)")
                CoverageFact(
                    title: L("dashboard.coverage.days_without"),
                    value: "\(data.diasSemDado)")
            }
            Text(caveat.text)
                .font(.caption)
                .foregroundStyle(caveat.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        // The accent edge is the panel's `border-left: 3px solid var(--destaque)`. Clipping the whole
        // card is what keeps the bar inside the corner radius without an `UnevenRoundedRectangle`.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PopoverStyle.accent(for: self.popoverTheme))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One `dt`/`dd` pair of the coverage block: a small caption over a tabular value.
private struct CoverageFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(.callout, design: .rounded).bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Volume: the principal quantity (EXB-5.9)

/// Token volume, named as the screen's principal quantity.
///
/// The two averages are the point of this section. They differ **only** in their divisor, share one
/// numerator (``DashboardData/totalTokens``), and each writes its divisor on its own label — so the
/// reader can check `média × dias = total` instead of trusting it. The screen used to show one average
/// with an invisible denominator, which is how a ~40% error survived on it for months.
private struct VolumeSection: View {
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionLabel(text: L("dashboard.section.volume"))
            LazyVGrid(columns: columns, spacing: 12) {
                MetricCard(
                    title: L("dashboard.volume.total"),
                    value: L("dashboard.summary.tokens", DashboardFormat.tokenCount(data.totalTokens)))
                MetricCard(
                    title: L("dashboard.volume.avg_covered"),
                    value: L("dashboard.summary.tokens",
                             DashboardFormat.tokenCount(Int(data.tokensPorDiaComUso.rounded()))),
                    note: L("dashboard.avg.divisor_covered", data.diasComDado))
                MetricCard(
                    title: L("dashboard.volume.avg_window"),
                    value: L("dashboard.summary.tokens",
                             DashboardFormat.tokenCount(Int(data.tokensPorDiaDaJanela.rounded()))),
                    note: L("dashboard.avg.divisor_window", data.spanDays))
                // EXB-3.7 AC6/AC16 + EXB-5.7 §2: today, with the prorated delta badge.
                MetricCard(
                    title: L("dashboard.summary.today"),
                    value: L("dashboard.summary.tokens", DashboardFormat.tokenCount(data.todayTokens)),
                    badge: DeltaBadgeModel(state: data.dailyDeltaState))
                MetricCard(
                    title: L("dashboard.summary.last_7_days"),
                    value: L("dashboard.summary.tokens", DashboardFormat.tokenCount(data.sevenDayTokens)))
                MetricCard(
                    title: L("dashboard.summary.projection"),
                    value: L("dashboard.summary.tokens", DashboardFormat.tokenCount(data.projectedTokens)))
                // EXB-5.7 §3: the rate travels with the two counts it is made of, so it can be checked
                // instead of believed. The dollar "saving" that used to sit here priced a scenario
                // that never ran, and was removed by the owner's decision.
                CacheHitCard(
                    hitRate: data.cacheHitRate,
                    cacheTokens: data.tokensDeCache,
                    inputTokens: data.tokensDeEntrada)
                // EXB-5.7 §7: only present when the previous month is covered in full. No card is a
                // better answer than an invented one.
                if let comparacao = data.comparacaoMensal {
                    MonthComparisonCard(comparacao: comparacao)
                }
            }
        }
    }
}

// MARK: - Cost: the estimate, named as one (EXB-5.9)

/// Estimated cost, under a caveat that travels with the numbers rather than living in a footnote.
///
/// The caveat is not decoration. The Senhor pays a subscription: none of these dollars is a bill, and
/// none of them prices a cache token. A figure that leaves this screen without that sentence becomes a
/// wrong fact in somebody else's spreadsheet.
private struct CostSection: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionLabel(text: L("dashboard.section.cost"))
            Text(L("dashboard.cost.caveat"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, spacing: 12) {
                let tint = PopoverStyle.accent(for: self.popoverTheme)
                MetricCard(
                    title: L("dashboard.cost.total"),
                    value: PopoverFormatter.currency(data.totalCost),
                    valueTint: tint)
                MetricCard(
                    title: L("dashboard.cost.today"),
                    value: PopoverFormatter.currency(data.todayCost),
                    valueTint: tint)
                MetricCard(
                    title: L("dashboard.volume.avg_covered"),
                    value: PopoverFormatter.currency(data.custoPorDiaComUso),
                    note: L("dashboard.avg.divisor_covered", data.diasComDado),
                    valueTint: tint)
                MetricCard(
                    title: L("dashboard.volume.avg_window"),
                    value: PopoverFormatter.currency(data.custoPorDiaDaJanela),
                    note: L("dashboard.avg.divisor_window", data.spanDays),
                    valueTint: tint)
                MetricCard(
                    title: L("dashboard.summary.projection"),
                    value: PopoverFormatter.currency(data.monthProjection),
                    valueTint: tint)
            }
        }
    }
}

// MARK: - KPI cards (AC2)

/// The delta-vs-average badge model (EXB-5.7 §2). Carries the *reason* there is no number, so the
/// badge never has to guess whether a missing delta means "sem uso hoje" or "cedo demais".
private struct DeltaBadgeModel {
    let state: DailyDeltaState

    /// The percentage integer (rounded) shown in the label, or `nil` when there is nothing to compare.
    var percent: Int? {
        guard case let .comparado(delta) = state else { return nil }
        return Int((delta * 100).rounded())
    }
}

/// One KPI card: title, one number, and — where the number is a quotient — the divisor that produced
/// it (EXB-5.9). `painel.html` calls these `rotulo` / `numero` / `nota`.
///
/// **One number per card, not two.** The card this replaces stacked tokens over cost, which is how the
/// screen ended up with no way to say which of the two was the principal quantity: every card asserted
/// they were equally important. Splitting them into a volume section and a cost section is only
/// possible once a card carries a single measure.
///
/// The `note` is where an average writes its own denominator. All numerics use `.monospacedDigit()` to
/// avoid layout jitter.
private struct MetricCard: View {
    let title: String
    let value: String
    var note: String? = nil
    var valueTint: Color? = nil
    /// EXB-4.5 AC2: the today-vs-average comparison, on the one card it applies to.
    var badge: DeltaBadgeModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(valueTint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let badge {
                DeltaBadge(model: badge)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// The today-vs-average comparison badge (EXB-4.5 AC2). Colour encodes direction: above-average spend
/// is warm (orange/red), below-average is green, on-average / no-data is neutral.
private struct DeltaBadge: View {
    let model: DeltaBadgeModel

    private var text: String {
        switch model.state {
        case .semUsoHoje: return L("dashboard.insights.delta.no_usage")
        case .cedoDemais: return L("dashboard.insights.delta.too_early")
        case .semBase: return L("dashboard.insights.delta.no_baseline")
        case .comparado:
            guard let percent = model.percent else { return L("dashboard.insights.delta.on_average") }
            if percent > 0 { return L("dashboard.insights.delta.above", percent) }
            if percent < 0 { return L("dashboard.insights.delta.below", -percent) }
            return L("dashboard.insights.delta.on_average")
        }
    }

    private var tint: Color {
        guard let percent = model.percent else { return .secondary }
        if percent > 0 { return Color(red: 0.82, green: 0.42, blue: 0.30) } // warm: above average
        if percent < 0 { return Color(red: 0.30, green: 0.62, blue: 0.40) } // green: below average
        return .secondary
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.14)))
    }
}

/// Month-vs-month KPI card (EXB-5.7 §7): the token variation as the headline, and — as the secondary
/// line — the stretch that was actually compared.
///
/// Naming the stretch is not decoration. `1–24` against `1–24` is a fair comparison; `1–24` against a
/// whole month is not, and looks identical on a card that only shows a percentage.
private struct MonthComparisonCard: View {
    let comparacao: ComparacaoMensal

    private var percent: Int { Int((comparacao.variacao * 100).rounded()) }

    private var tint: Color {
        if percent > 0 { return Color(red: 0.82, green: 0.42, blue: 0.30) }
        if percent < 0 { return Color(red: 0.30, green: 0.62, blue: 0.40) }
        return .secondary
    }

    private var headline: String {
        if percent > 0 { return L("dashboard.insights.month.up", percent) }
        if percent < 0 { return L("dashboard.insights.month.down", -percent) }
        return L("dashboard.insights.month.flat")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("dashboard.insights.month.title"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(headline)
                .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(comparacao.truncado
                ? L("dashboard.insights.month.range_truncated", comparacao.diasComparados)
                : L("dashboard.insights.month.range", comparacao.diasComparados))
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// The cache-hit KPI card: hit rate as the headline, the two absolute counts underneath.
///
/// EXB-5.7 §3: the secondary line used to be an estimated dollar saving computed at output prices —
/// 5,44× the real figure. It is gone. What replaced it is the pair of numbers the percentage is made
/// of, so the rate can be checked instead of believed.
private struct CacheHitCard: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let hitRate: Double
    let cacheTokens: Int
    let inputTokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("dashboard.insights.cache_hit.title"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(DashboardFormat.taxaCache(hitRate))
                .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(PopoverStyle.accent(for: self.popoverTheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L("dashboard.insights.cache_hit.counts",
                   DashboardFormat.tokenCount(cacheTokens),
                   DashboardFormat.tokenCount(inputTokens)))
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Weekly summary "wrapped" (EXB-4.5 AC3)

/// The "Esta semana" recap — four highlight cards visible only in the 7-day period (AC3/AC10): the
/// busiest day, the most-used model, the week total, and the peak hour. Built entirely from fields the
/// off-main `DashboardData.build` already derived (no work in `body`, AC4/AC12).
private struct WeeklySummarySection: View {
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    /// Full weekday name (e.g. "Quarta-feira") for weekday index 0…6, localized to the app language.
    private static func weekdayName(_ dayOfWeek: Int) -> String {
        let symbols = Calendar.current.standaloneWeekdaySymbols // index 0 = Sunday
        guard dayOfWeek >= 0, dayOfWeek < symbols.count else { return "\(dayOfWeek)" }
        return symbols[dayOfWeek].capitalized
    }

    /// `"09:00"` style label for a peak hour 0…23.
    private static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", max(0, min(23, hour)))
    }

    /// Busiest-day value: `"Quarta-feira · $4.23"`, or an em-dash placeholder when there is no spend.
    private var busiestDayValue: String {
        guard let busiest = data.busiestDay else { return L("dashboard.insights.weekly.no_data") }
        return "\(Self.weekdayName(busiest.dayOfWeek)) · \(PopoverFormatter.currency(busiest.cost))"
    }

    /// Top-model value: `"claude-sonnet-4 · 12.3B"`, or a placeholder when the week is empty.
    private var topModelValue: String {
        guard let top = data.topModelByTokens else { return L("dashboard.insights.weekly.no_data") }
        return L("dashboard.insights.weekly.model_value", top.name, DashboardFormat.tokenCount(top.tokens))
    }

    /// Week total: `"$18.45 · 45.2B"` (the 7-day cost + token totals).
    private var weekTotalValue: String {
        L("dashboard.insights.weekly.total_value",
          PopoverFormatter.currency(data.sevenDayCost),
          DashboardFormat.tokenCount(data.sevenDayTokens))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSectionHeader(
                title: L("dashboard.insights.weekly.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd))
            LazyVGrid(columns: columns, spacing: 12) {
                WeeklyHighlightCard(
                    icon: "calendar.badge.exclamationmark",
                    title: L("dashboard.insights.weekly.busiest_day"),
                    value: busiestDayValue)
                WeeklyHighlightCard(
                    icon: "cpu",
                    title: L("dashboard.insights.weekly.top_model"),
                    value: topModelValue)
                WeeklyHighlightCard(
                    icon: "chart.bar.fill",
                    title: L("dashboard.insights.weekly.week_total"),
                    value: weekTotalValue)
                WeeklyHighlightCard(
                    icon: "clock.fill",
                    title: L("dashboard.insights.weekly.peak_hour"),
                    value: Self.hourLabel(data.peakHour))
            }
        }
    }
}

/// One "Esta semana" highlight card (EXB-4.5 AC3/AC9): SF Symbol + small title + a prominent value,
/// sharing the rounded-rect KPI styling used across the dashboard.
private struct WeeklyHighlightCard: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(PopoverStyle.accent(for: self.popoverTheme))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.callout, design: .rounded).bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
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
    @Environment(\.popoverTheme) private var popoverTheme
    let data: DashboardData
    /// EXB-5.7 §5: only the days the archive vouches for get a mark. An uncovered day is a **gap** in
    /// the series, and Swift Charts renders a gap by simply not being handed the point — which is what
    /// makes "we never saw this" look different from "nothing happened here".
    private var entries: [DashboardDailyEntry] { data.dailyCosts.filter(\.coberto) }

    /// The day the user is hovering, if any (AC11).
    @State private var selectedDate: Date?

    /// Running cumulative cost over the covered span — the overlay line (AC3).
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

    /// Legend series labels (EXB-3.7 AC5): daily bars vs. the cumulative line.
    private var dailyLabel: String { L("dashboard.chart.cost.daily") }
    private var cumulativeLabel: String { L("dashboard.chart.cost.cumulative") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.chart.cost.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                explanation: L("dashboard.chart.cost.sub"),
                total: DashboardFormat.totalTokensAndCost(data.totalTokens, data.totalCost))
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
                    // EXB-3.7 AC5: name the series so the legend reads "Daily cost" / "Cumulative".
                    .foregroundStyle(by: .value("Series", dailyLabel))
                    .opacity(selectedDate == nil || selectedEntry?.date == entry.date ? 1 : 0.4)
            }
            ForEach(cumulative, id: \.date) { point in
                LineMark(
                    x: .value(L("dashboard.chart.axis.date"), point.date, unit: .day),
                    y: .value(L("dashboard.chart.cost.cumulative"), point.total),
                    series: .value("Series", cumulativeLabel))
                    .foregroundStyle(by: .value("Series", cumulativeLabel))
                    .interpolationMethod(.monotone)
            }
            if let selectedEntry {
                RuleMark(x: .value(L("dashboard.chart.axis.date"), selectedEntry.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        HoverAnnotation(
                            date: selectedEntry.date,
                            primary: DashboardFormat.preciseCurrency(selectedEntry.costUSD),
                            secondary: L("dashboard.summary.tokens", DashboardFormat.tokenCount(selectedEntry.tokens)))
                    }
            }
        }
        // EXB-3.7 AC5: bind the two series to brand (daily) / secondary (cumulative) so the colours in
        // the visible legend match the bars and line.
        .chartForegroundStyleScale(domain: [dailyLabel, cumulativeLabel], range: [PopoverStyle.accent(for: self.popoverTheme), Color.secondary])
        // EXB-5.7 §5.2: the axis keeps the requested window even when the marks do not fill it.
        .chartXScale(domain: data.windowDomain ?? Date()...Date().addingTimeInterval(86_400))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: DashboardFormat.axisStride(forDays: data.spanDays))) { value in
                AxisGridLine()
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
                .font(.system(.callout, design: .rounded).monospacedDigit())
            Text(secondary)
                .font(.system(.caption2, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

/// Stacked-tokens hover tooltip (EXB-3.7 AC3): date + the four token-type volumes in K/M/B.
private struct TokenBreakdownTooltip: View {
    let entry: DashboardDailyEntry

    private struct Line: Identifiable {
        let id = UUID()
        let label: String
        let value: Int
    }

    private var lines: [Line] {
        [
            Line(label: L("dashboard.tokens.input"), value: entry.inputTokens),
            Line(label: L("dashboard.tokens.output"), value: entry.outputTokens),
            Line(label: L("dashboard.tokens.cache_read"), value: entry.cacheReadTokens),
            Line(label: L("dashboard.tokens.cache_write"), value: entry.cacheWriteTokens),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DashboardFormat.dayMonth.string(from: entry.date))
                .font(.caption.bold())
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    Text(line.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(DashboardFormat.tokenCount(line.value))
                        .font(.system(.caption2, design: .rounded).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

// MARK: - Stacked tokens chart (AC4)

private struct StackedTokensChart: View {
    let data: DashboardData
    /// Called when the Senhor drags a stretch over this chart (EXB-5.8 §8). The primary chart carries
    /// the gesture because tokens are the primary quantity — you select time where you read volume.
    var selectRange: (ClosedRange<Date>) -> Void = { _ in }
    /// EXB-5.7 §5: no bar for an uncovered day. An absent bar is not a bar of height zero, and that
    /// difference is the whole point — a zero-height bar states "no usage", which the app cannot know.
    private var entries: [DashboardDailyEntry] { data.dailyTokens.filter(\.coberto) }

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

    /// The day under the pointer (EXB-3.7 AC3) — drives the RuleMark + breakdown annotation.
    @State private var selectedDate: Date?
    /// The stretch being dragged, held locally so the highlight is free while the gesture is live
    /// (EXB-5.8 §8). Committing upward is what costs a re-fold, so it happens on change and the
    /// controller cancels whatever fold was still in flight.
    @State private var faixaArrastada: ClosedRange<Date>?

    /// The daily entry snapped to the hovered day.
    private var selectedEntry: DashboardDailyEntry? {
        guard let selectedDate else { return nil }
        let target = Calendar.current.startOfDay(for: selectedDate)
        return entries.first { $0.date == target }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.chart.tokens.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                explanation: L("dashboard.chart.tokens.sub"),
                total: DashboardFormat.totalTokensAndCost(data.totalTokens, data.totalCost))
            if hasData {
                chart
                // EXB-5.7 §3: the cache rate survives here as a *fact*, stated with its absolutes —
                // the dollar estimate that used to carry it did not.
                Text(L("dashboard.chart.tokens.cache_footer",
                       DashboardFormat.tokenCount(data.tokensDeCache),
                       DashboardFormat.tokenCount(data.tokensDeEntrada),
                       DashboardFormat.taxaCache(data.cacheHitRate)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ChartEmptyState(systemImage: "square.stack.3d.up", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(slices) { slice in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), slice.date, unit: .day),
                    y: .value(L("dashboard.chart.tokens.y_label"), slice.tokens))
                    .foregroundStyle(by: .value(L("dashboard.tokens.type"), slice.type.label))
                    .opacity(selectedDate == nil || selectedEntry?.date == slice.date ? 1 : 0.45)
            }
            // EXB-3.7 AC3: vertical indicator + per-type breakdown annotation on hover.
            if let selectedEntry {
                RuleMark(x: .value(L("dashboard.chart.axis.date"), selectedEntry.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        TokenBreakdownTooltip(entry: selectedEntry)
                    }
            }
        }
        // EXB-5.7 §5.2: the axis keeps the requested window even when the marks do not fill it.
        .chartXScale(domain: data.windowDomain ?? Date()...Date().addingTimeInterval(86_400))
        // EXB-5.8 §8: the native drag. `chartXSelection(range:)` was verified to compile on macOS 14,
        // so the SDK's own highlight and accessibility come for free — no `DragGesture` needed.
        .chartXSelection(range: $faixaArrastada)
        .onChange(of: faixaArrastada) { _, nova in
            guard let nova else { return }
            selectRange(nova)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: DashboardFormat.axisStride(forDays: data.spanDays))) { value in
                AxisGridLine()
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotAnchor = proxy.plotFrame else { selectedDate = nil; return }
                            let origin = geo[plotAnchor].origin
                            selectedDate = proxy.value(atX: location.x - origin.x, as: Date.self)
                        case .ended:
                            selectedDate = nil
                        }
                    }
            }
        }
        .frame(height: 220)
    }
}

// MARK: - Model breakdown: donut + table (AC5)

private struct ModelBreakdownSection: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let data: DashboardData
    private var rows: [DashboardModelEntry] { data.byModel }

    /// The model under the pointer — shared so the donut sector and the table row light up together
    /// (EXB-3.7 AC7, cross-highlight). Set from either the donut hover or a table-row hover.
    @State private var hoveredModel: String?

    /// Total cost over the window — denominator for the per-model share % (EXB-3.7 AC6).
    private var totalCost: Double { rows.reduce(0) { $0 + $1.costUSD } }

    /// Stable model→colour scale shared by the donut and the table swatches (AC12).
    private var colorScale: (domain: [String], range: [Color]) {
        DashboardPalette.scale(for: data.sortedModelNames, theme: self.popoverTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSectionHeader(
                title: L("dashboard.models.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                explanation: L("dashboard.models.sub"))
            HStack(alignment: .top, spacing: 16) {
                ModelCostDonut(rows: rows, scale: colorScale, totalCost: totalCost, hoveredModel: $hoveredModel)
                    .frame(width: 160, height: 160)
                ModelBreakdownTable(rows: rows, scale: colorScale, hoveredModel: $hoveredModel)
            }
        }
    }
}

/// Donut (SectorMark) of per-model cost share (AC5), coloured by the shared scale (AC12).
///
/// EXB-3.7 AC5/AC6/AC7: `chartAngleSelection` maps the pointer angle to a model; the hovered sector
/// stays full-opacity (others dim to 0.4) and a tooltip shows model · in/out tokens · cost · share.
/// The hover binds upward so the matching table row highlights in lockstep.
private struct ModelCostDonut: View {
    let rows: [DashboardModelEntry]
    let scale: (domain: [String], range: [Color])
    let totalCost: Double
    @Binding var hoveredModel: String?

    /// The angle (cumulative cost value) the pointer last selected, mapped back to a model.
    @State private var selectedValue: Double?

    /// The model whose cumulative-cost band contains `selectedValue`.
    private func model(forAngleValue value: Double) -> String? {
        var running = 0.0
        for row in rows {
            running += row.costUSD
            if value <= running { return row.model }
        }
        return rows.last?.model
    }

    private var hoveredEntry: DashboardModelEntry? {
        guard let hoveredModel else { return nil }
        return rows.first { $0.model == hoveredModel }
    }

    var body: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value(L("dashboard.models.col.cost"), row.costUSD),
                innerRadius: .ratio(0.6),
                angularInset: hoveredModel == row.model ? 0.5 : 1.5)
                .foregroundStyle(by: .value(L("dashboard.models.col.model"), row.model))
                .cornerRadius(3)
                .opacity(hoveredModel == nil || hoveredModel == row.model ? 1.0 : 0.4)
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartAngleSelection(value: $selectedValue)
        .chartLegend(.hidden)
        .onChange(of: selectedValue) { _, value in
            hoveredModel = value.flatMap { model(forAngleValue: $0) }
        }
        .overlay(alignment: .center) {
            if let hoveredEntry {
                DonutTooltip(entry: hoveredEntry, totalCost: totalCost)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Donut hover tooltip (EXB-3.7 AC6): model · input · output · cost · share of total.
private struct DonutTooltip: View {
    let entry: DashboardModelEntry
    let totalCost: Double

    private var sharePercent: Int {
        guard totalCost > 0 else { return 0 }
        return Int((entry.costUSD / totalCost * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.model)
                .font(.caption.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(L("dashboard.donut.tooltip.tokens",
                   DashboardFormat.tokenCount(entry.inputTokens),
                   DashboardFormat.tokenCount(entry.outputTokens)))
                .font(.system(.caption2, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(L("dashboard.donut.tooltip.cost_share",
                   PopoverFormatter.currency(entry.costUSD), sharePercent))
                .font(.system(.caption2, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

/// Per-model totals, sorted by token volume desc (EXB-5.7 §6). Columns: swatch · model · input ·
/// output · cost — the cost column stays, as the supporting figure it now is.
///
/// EXB-3.7 AC7: a per-row `.onHover` drives the shared `hoveredModel`, and the bound value back-lights
/// the matching row — so hovering the donut highlights here, and hovering here highlights the donut.
private struct ModelBreakdownTable: View {
    let rows: [DashboardModelEntry]
    let scale: (domain: [String], range: [Color])
    @Binding var hoveredModel: String?

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
                    Text(DashboardFormat.tokenCount(row.inputTokens))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                    Text(DashboardFormat.tokenCount(row.outputTokens))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                    Text(PopoverFormatter.currency(row.costUSD))
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hoveredModel == row.model ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
                .onHover { inside in hoveredModel = inside ? row.model : (hoveredModel == row.model ? nil : hoveredModel) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Models per day (EXB-3.7 AC4)

/// Stacked bars of per-day token *volume*, stacked by model (EXB-3.7 AC4). Colours come from the same
/// `DashboardPalette.scale(for: sortedModelNames)` the donut uses (AC11), so a model reads identically
/// across the donut, the table and here. Hover surfaces a per-model breakdown for the day (AC13).
private struct ModelsByDayChart: View {
    @Environment(\.popoverTheme) private var popoverTheme
    let data: DashboardData
    private var entries: [DailyModelEntry] { data.byDayByModel }

    private var hasData: Bool { entries.contains { $0.tokens > 0 } }

    /// The stable model→colour scale (shared with the donut, AC11). Computed once per render from the
    /// view model's pre-sorted model names — never recomputed inside the chart closure (anti-freeze).
    private var colorScale: (domain: [String], range: [Color]) {
        DashboardPalette.scale(for: data.sortedModelNames, theme: self.popoverTheme)
    }

    /// Total token volume over the window — the header highlight number.
    private var totalTokens: Int { entries.reduce(0) { $0 + $1.tokens } }

    /// The day under the pointer (AC13) — drives the RuleMark + per-model breakdown.
    @State private var selectedDate: Date?

    /// All `(model, tokens)` for the hovered day, sorted by volume desc.
    private var selectedDayBreakdown: [DailyModelEntry] {
        guard let selectedDate else { return [] }
        let target = Calendar.current.startOfDay(for: selectedDate)
        return entries.filter { $0.date == target && $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.models_by_day.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                explanation: L("dashboard.models_by_day.sub"),
                total: DashboardFormat.totalTokensAndCost(totalTokens, data.totalCost))
            if hasData {
                chart
            } else {
                ChartEmptyState(systemImage: "chart.bar.doc.horizontal", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(entries) { entry in
                BarMark(
                    x: .value(L("dashboard.chart.axis.date"), entry.date, unit: .day),
                    y: .value(L("dashboard.chart.tokens.y_label"), entry.tokens))
                    .foregroundStyle(by: .value(L("dashboard.models.col.model"), entry.modelName))
                    .opacity(selectedDate == nil || isSelected(entry.date) ? 1 : 0.45)
            }
            if let selectedDate, !selectedDayBreakdown.isEmpty {
                RuleMark(x: .value(L("dashboard.chart.axis.date"), Calendar.current.startOfDay(for: selectedDate), unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ModelsByDayTooltip(date: Calendar.current.startOfDay(for: selectedDate), rows: selectedDayBreakdown)
                    }
            }
        }
        .chartForegroundStyleScale(domain: colorScale.domain, range: colorScale.range)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: DashboardFormat.axisStride(forDays: data.spanDays))) { value in
                AxisGridLine()
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotAnchor = proxy.plotFrame else { selectedDate = nil; return }
                            let origin = geo[plotAnchor].origin
                            selectedDate = proxy.value(atX: location.x - origin.x, as: Date.self)
                        case .ended:
                            selectedDate = nil
                        }
                    }
            }
        }
        .frame(height: 220)
    }

    private func isSelected(_ date: Date) -> Bool {
        guard let selectedDate else { return false }
        return date == Calendar.current.startOfDay(for: selectedDate)
    }
}

/// Models-per-day hover tooltip (EXB-3.7 AC13): date + per-model token volume in K/M/B.
private struct ModelsByDayTooltip: View {
    let date: Date
    let rows: [DailyModelEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DashboardFormat.dayMonth.string(from: date))
                .font(.caption.bold())
            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 8) {
                    Text(row.modelName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(DashboardFormat.tokenCount(row.tokens))
                        .font(.system(.caption2, design: .rounded).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 140, maxWidth: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

// MARK: - Project breakdown table (AC6)

private struct ProjectBreakdownTable: View {
    let rows: [ProjectUsageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.projects.title"),
                explanation: L("dashboard.projects.sub"))

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
    private var maxTokens: Int { cells.map(\.tokens).max() ?? 0 }
    /// Smallest non-zero hour — the lower anchor of the active colour range (EXB-4.2 min-max scale).
    private var minTokens: Int { cells.map(\.tokens).filter { $0 > 0 }.min() ?? 0 }

    /// The cell currently under the pointer (EXB-3.7 AC4) — drives the tooltip.
    @State private var hoveredCell: HeatmapBucket?

    /// Localized weekday short labels, Sun…Sat, ordered to match `weekday` 0…6.
    private static let weekdaySymbols: [String] = {
        let cal = Calendar.current
        return cal.shortWeekdaySymbols // index 0 = Sunday in Gregorian
    }()

    private static func weekdayLabel(_ weekday: Int) -> String {
        weekdaySymbols[safe: weekday] ?? "\(weekday)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionHeader(
                title: L("dashboard.heatmap.title"),
                subtitle: DashboardFormat.rangeSubtitle(data.rangeStart, data.rangeEnd),
                explanation: L("dashboard.heatmap.sub"),
                total: L("dashboard.total.tokens", DashboardFormat.tokenCount(data.totalHeatmapTokens)))
            if hasData {
                chart
                // EXB-3.7 AC1/AC3: a custom K/M/B gradient legend — the auto-legend renders raw Int
                // domain ticks ("1.0E8"), which the AC forbids.
                HeatmapLegend(maxTokens: maxTokens)
            } else {
                ChartEmptyState(systemImage: "flame", message: L("dashboard.empty.period"))
            }
        }
    }

    private var chart: some View {
        // `min`/`max` captured once here (never recomputed inside the cell closure). The fill comes
        // from the min-max log-scale type, giving the heatmap full-range colour gradation.
        let max = maxTokens
        let min = minTokens
        return Chart {
            ForEach(cells, id: \.cellID) { cell in
                RectangleMark(
                    // Hour MUST be a categorical (String) x value. With a numeric `Int` x, Swift
                    // Charts gives `RectangleMark` no band width and draws nothing — the real cause
                    // of the "invisible heatmap" (no colour could fix an unrendered cell).
                    x: .value(L("dashboard.heatmap.hour"), String(format: "%02d", cell.hour)),
                    y: .value(L("dashboard.heatmap.day"), Self.weekdayLabel(cell.weekday)),
                    width: .ratio(0.92),
                    height: .ratio(0.92))
                    .cornerRadius(3)
                    // Min-max log-normalized terracota ramp per cell; zero hours get the neutral wash.
                    .foregroundStyle(HeatmapColorScale.color(tokens: cell.tokens, min: min, max: max))
                    .opacity(hoveredCell == nil || hoveredCell == cell ? 1 : 0.45)
            }
        }
        // The per-cell `.foregroundStyle` is a fixed `Color`, so no `chartForegroundStyleScale` /
        // legend domain is involved — the custom `HeatmapLegend` documents the (log) scale instead.
        .chartXAxis {
            AxisMarks(values: ["00", "06", "12", "18", "23"]) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading)
        }
        // The auto-legend renders raw token ticks in scientific notation → replaced by HeatmapLegend.
        .chartLegend(.hidden)
        // EXB-3.7 AC4: hover tooltip — map pointer to (hour, weekday) cell.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hoveredCell = cell(at: location, proxy: proxy, geo: geo)
                        case .ended:
                            hoveredCell = nil
                        }
                    }
            }
        }
        // AC9: keep the tooltip inside the card by overlaying it (not a chart annotation) so it never
        // spills to the window footer.
        .overlay(alignment: .topTrailing) {
            if let hoveredCell {
                HeatmapTooltip(cell: hoveredCell)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 220)
    }

    /// Map a pointer location to the `(hour, weekday)` bucket under it, or `nil` outside the plot.
    private func cell(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> HeatmapBucket? {
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let origin = geo[plotAnchor].origin
        let x = location.x - origin.x
        let y = location.y - origin.y
        // X is now a categorical hour label ("00"…"23"), so read it as String and parse back to Int.
        guard let hourLabel: String = proxy.value(atX: x),
              let clampedHour = Int(hourLabel),
              let weekdayLabel: String = proxy.value(atY: y)
        else { return nil }
        guard let weekday = Self.weekdaySymbols.firstIndex(of: weekdayLabel) else { return nil }
        return cells.first { $0.hour == clampedHour && $0.weekday == weekday }
    }
}

/// Heatmap hover tooltip (EXB-3.7 AC4): weekday · hour range + K/M/B token volume.
private struct HeatmapTooltip: View {
    let cell: HeatmapBucket

    private var weekday: String { ActivityHeatmapChart.weekdayLabelPublic(cell.weekday) }
    private var hourRange: String {
        L("dashboard.heatmap.hour_range", String(format: "%02d", cell.hour), String(format: "%02d", (cell.hour + 1) % 24))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(weekday) · \(hourRange)")
                .font(.caption.bold())
            Text(L("dashboard.summary.tokens", DashboardFormat.tokenCount(cell.tokens)))
                .font(.system(.caption2, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}

/// Custom heatmap intensity legend (EXB-4.1 AC3): a brand gradient bar whose three anchor labels
/// (`0`, the log mid-point, `max`) are spaced to match the **logarithmic** cell scale, plus a
/// "Log scale" caption so the non-linear mapping is self-documenting. All token labels go through
/// `DashboardFormat.tokenCount` (K/M/B) — never scientific notation (AC3-#7).
private struct HeatmapLegend: View {
    let maxTokens: Int

    /// The three log-space anchor token values: zero, the geometric mid-point, and the peak (AC3-#7).
    private var anchors: [Int] {
        [0, HeatmapColorScale.logMidpoint(max: maxTokens), maxTokens]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L("dashboard.heatmap.less"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // The bar shades from the zero/neutral wash through the floor-clamped non-zero range
                // up to the saturated brand — the same dark→colour ramp the cells use.
                LinearGradient(
                    colors: [
                        HeatmapColorScale.zeroFill,
                        HeatmapColorScale.solidColor(t: HeatmapColorScale.minimumNonZero),
                        HeatmapColorScale.solidColor(t: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                // Three K/M/B anchor labels under the log scale: 0 · mid · max.
                HStack(spacing: 6) {
                    ForEach(Array(anchors.enumerated()), id: \.offset) { _, value in
                        Text(DashboardFormat.tokenCount(value))
                            .font(.system(.caption2, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // AC3-#8: surface that the scale is logarithmic.
            Text(L("dashboard.heatmap.log_scale"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

extension ActivityHeatmapChart {
    /// Bridges the private static weekday helper to `HeatmapTooltip` in the same file.
    static func weekdayLabelPublic(_ weekday: Int) -> String { weekdayLabel(weekday) }
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
