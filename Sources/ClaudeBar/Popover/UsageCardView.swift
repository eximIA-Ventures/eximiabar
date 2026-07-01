import AppKit
import ClaudeBarCore
import SwiftUI

/// The actions the card can trigger. The panel controller supplies a concrete implementation;
/// `UsageCardView` stays a pure function of the snapshot plus this callback set.
struct UsageCardActions {
    var refresh: () -> Void = {}
    /// Opens the local Swift Charts dashboard window (EXB-2.3 AC1).
    var openLocalDashboard: () -> Void = {}
    /// Opens the Anthropic web usage page in the browser (EXB-2.3 AC1 — renamed "Claude Usage (Web)").
    var openUsageDashboard: () -> Void = {}
    var openStatusPage: () -> Void = {}
    var openSettings: () -> Void = {}
    var openRelogin: () -> Void = {}
    var quit: () -> Void = {}
}

/// The dropdown card (AC7–AC17). Assembles every section top-to-bottom from a single immutable
/// `DisplaySnapshot`. Purely a function of its inputs (AC21) — no state beyond the local copy-button
/// animation. Width is fixed at 310 pt (AC4); height is left to SwiftUI auto-sizing (AC2).
struct UsageCardView: View {
    let snapshot: DisplaySnapshot?
    let actions: UsageCardActions
    /// The four "Menu Content" display preferences (AC5), resolved from `SettingsStore`. The default
    /// keeps SwiftUI previews and tests that build the card without settings visually stable.
    var options: MenuDisplayOptions = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeaderSection(snapshot: self.snapshot)

            Divider() // AC8

            MetricsSection(snapshot: self.snapshot, options: self.options)

            if let extra = self.snapshot?.extraUsage, extra.isEnabled {
                Divider()
                ExtraUsageSection(extra: extra)
            }

            // AC11: the cost section is present only when a scan produced a `ProviderCost`
            // (`costEnabled == true`). When cost is disabled it is `nil` and the section is hidden.
            if let cost = self.snapshot?.cost {
                Divider()
                CostSection(cost: cost, plan: self.snapshot?.plan)
            }

            Divider()
            ActionSection(showRelogin: self.snapshot?.error?.isAuthOrScope == true, actions: self.actions)
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: PopoverStyle.panelWidth, alignment: .leading)
        // Meter skin (v2.2.0): paint a deep near-black card over the window material so the amber
        // accent reads on black. Classic keeps the translucent material untouched.
        .background {
            if self.options.popoverTheme == .meter {
                RoundedRectangle(cornerRadius: PopoverStyle.cornerRadius)
                    .fill(DesignTokens.meterSurface)
            }
        }
        // Inject the skin once so every descendant (rows, header badge) reads it from the environment.
        .environment(\.popoverTheme, self.options.popoverTheme)
    }
}

// MARK: - Header (AC7)

private struct HeaderSection: View {
    let snapshot: DisplaySnapshot?
    @Environment(\.popoverTheme) private var popoverTheme

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.headerLineSpacing) {
            // Line 1: eximIA symbol + "Claude" + email. The symbol is a template image tinted with the
            // theme accent (terracotta classic / amber meter), so the popover carries the brand mark.
            HStack(spacing: 8) {
                if let logo = EximiaLogo.image(height: 16) {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .foregroundStyle(PopoverStyle.accent(for: self.popoverTheme))
                        .accessibilityHidden(true)
                }
                Text(L("popover.provider_name"))
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer()
                if let email = self.snapshot?.identity.email, !email.isEmpty {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Line 2: status (updated / refreshing / error) + plan.
            let isError = self.snapshot?.error != nil
            HStack(alignment: isError ? .top : .firstTextBaseline, spacing: PopoverStyle.headerColumnSpacing) {
                StatusLine(snapshot: self.snapshot)
                    .layoutPriority(1)
                Spacer()
                if isError, let message = self.snapshot?.error?.message, !message.isEmpty {
                    CopyIconButton(copyText: message)
                }
                if let plan = self.snapshot?.plan {
                    PlanBadge(text: plan.compactLoginMethod, isMeter: self.popoverTheme == .meter)
                }
            }
        }
    }
}

/// The plan label ("Max"). Classic: plain secondary text. Meter: an amber outlined pill that echoes
/// the "Max · 20×" badge of the eximIA Meter reference, giving the header its signature accent.
private struct PlanBadge: View {
    let text: String
    let isMeter: Bool

    var body: some View {
        if self.isMeter {
            Text(self.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PopoverStyle.meterAccent)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(PopoverStyle.meterAccent.opacity(0.55), lineWidth: 1))
        } else {
            Text(self.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct StatusLine: View {
    let snapshot: DisplaySnapshot?

    var body: some View {
        if let error = self.snapshot?.error {
            Text(error.message)
                .font(.footnote)
                .foregroundStyle(Color(nsColor: .systemRed))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.snapshot?.isRefreshing == true {
            Text(L("popover.refreshing"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let updatedAt = self.snapshot?.updatedAt, updatedAt != .distantPast {
            Text(PopoverFormatter.updatedText(from: updatedAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(L("popover.not_fetched_yet"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Copy button (AC7): `doc.on.doc` → `checkmark` on tap, scale 0.94 while pressed, reverts after 2 s.
private struct CopyIconButton: View {
    let copyText: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(self.copyText, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { self.didCopy = true }
            self.resetTask?.cancel()
            self.resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.2)) { self.didCopy = false }
            }
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(self.didCopy ? L("popover.copied") : L("popover.copy_error"))
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Metrics (AC9–AC13)

private struct MetricsSection: View {
    let snapshot: DisplaySnapshot?
    let options: MenuDisplayOptions

    /// Merged warning + workday dash positions for one window's bar (AC5). `thresholds` are the
    /// window's percent-remaining warning levels; `isWeekly` enables the weekly workday pace dashes.
    private func markers(thresholds: [Int], isWeekly: Bool) -> [Double] {
        MenuMarkers.markerPercents(
            thresholds: thresholds,
            showWarningMarkers: self.options.showWarningMarkers,
            showUsed: self.options.showUsed,
            workdayMarkers: self.options.workdayMarkers,
            isWeekly: isWeekly)
    }

    /// Pace for any window with a usable `resetsAt`; `nil` when the window is missing or it is too
    /// early in the window to project (see `UsagePace.compute`). Used for BOTH Session and Weekly so
    /// each bar shows its own rhythm — the Session window has elapsed time too, so it gets the same
    /// reserve/deficit stripe and label as Weekly.
    private func pace(for window: RateWindow?) -> UsagePace? {
        guard let window else { return nil }
        return UsagePace.compute(window: window)
    }

    /// The localized "No ritmo atual…" forecast line for `windowId`.
    ///
    /// The two weekly pace indicators are normally mutually exclusive — the "Indicador de ritmo"
    /// toggle: in `.bar` mode the stripe on the bar carries pace and NO text is shown; in `.text`
    /// mode the bar drops its stripe and this line is shown instead.
    ///
    /// EXCEPTION (EXB pace-visibility fix): in `.bar` mode the stripe can be absent — `UsagePace`
    /// does not compute when the window has no `resetsAt` or less than 3% of it has elapsed (a fresh
    /// weekly window's first hours). Removing the text in `.bar` mode then left the row with NO
    /// indicator at all. So when `barStripeAbsent` is `true` we fall back to the text even in `.bar`
    /// mode — the row always shows *something* the moment a forecast exists, and the stripe and the
    /// text are still never shown together (the fallback only fires when the stripe is missing).
    ///
    /// Both the Session and Weekly rows now carry a pace stripe, so both pass `barStripeAbsent`: it
    /// makes a row fall back to the forecast text whenever its stripe would otherwise be missing.
    private func forecastText(for windowId: String, barStripeAbsent: Bool = false) -> String? {
        let showText = self.options.paceDisplayMode == .text
            || (self.options.paceDisplayMode == .bar && barStripeAbsent)
        guard showText,
              let forecast = self.snapshot?.forecast(for: windowId),
              let minutes = forecast.minutesRemaining,
              minutes.isFinite, minutes >= 0
        else { return nil }
        return PopoverFormatter.forecastText(minutesRemaining: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricRowSpacing) {
            if let session = self.snapshot?.session {
                let pace = self.pace(for: session)
                MetricRow(
                    title: L("popover.metric.session"),
                    window: session,
                    showPace: pace != nil,
                    pace: pace,
                    paceDetail: pace.map { UsagePaceText.detail(for: $0) },
                    warningMarkerPercents: self.markers(thresholds: self.options.sessionThresholds, isWeekly: false),
                    showUsed: self.options.showUsed,
                    showAbsoluteReset: self.options.showAbsoluteReset,
                    prominence: .primary,
                    paceMode: self.options.paceDisplayMode,
                    forecastText: self.forecastText(
                        for: RateWindowID.session,
                        barStripeAbsent: pace == nil))
            }
            if let weekly = self.snapshot?.weekly {
                let pace = self.pace(for: weekly)
                MetricRow(
                    title: L("popover.metric.weekly"),
                    window: weekly,
                    showPace: pace != nil,
                    pace: pace,
                    paceDetail: pace.map { UsagePaceText.detail(for: $0) },
                    warningMarkerPercents: self.markers(thresholds: self.options.weeklyThresholds, isWeekly: true),
                    showUsed: self.options.showUsed,
                    showAbsoluteReset: self.options.showAbsoluteReset,
                    prominence: .secondary,
                    paceMode: self.options.paceDisplayMode,
                    forecastText: self.forecastText(
                        for: RateWindowID.weekly,
                        barStripeAbsent: pace == nil))
            }
            // Opus weekly sub-limit only. Anthropic reworked usage limits: Sonnet no longer has its own
            // window — it folded into the single "all models" weekly cap, which IS the Semanal bar
            // above — so there is no Sonnet bar to show. Opus keeps a separate weekly cap that Anthropic
            // still exposes (`seven_day_opus`) for Max plans when Opus is used. Show it only when the API
            // actually reports it: no 0% placeholder for a limit that may not currently apply, and no
            // Sonnet bar for a limit that no longer exists.
            if let opus = self.snapshot?.opus {
                ModelRow(title: L("popover.metric.opus"), window: opus)
            }
        }
    }
}

/// A thin "per-model" row (Opus / Sonnet): name, a slim bar, and the consumed %. No reset line —
/// the models share the weekly reset shown above, so repeating it would be noise (EXB redesign #3).
private struct ModelRow: View {
    let title: String
    let window: RateWindow
    @Environment(\.popoverTheme) private var popoverTheme

    var body: some View {
        HStack(spacing: 10) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            UsageProgressBar(
                percent: self.window.utilization,
                tint: PopoverStyle.zoneBarColor(utilization: self.window.utilization, theme: self.popoverTheme),
                accessibilityLabel: L("popover.metric.usage_accessibility", self.title))
            Text(verbatim: "\(Int(self.window.utilization.rounded()))%")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - Extra usage (AC15)

private struct ExtraUsageSection: View {
    let extra: ExtraUsage

    private var percentUsed: Double {
        if let utilization = self.extra.utilization { return min(100, max(0, utilization)) }
        guard self.extra.monthlyLimit > 0 else { return 0 }
        return min(100, max(0, (self.extra.usedCredits / self.extra.monthlyLimit) * 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            Text(L("popover.extra.title"))
                .font(.body)
                .fontWeight(.medium)
            UsageProgressBar(
                percent: self.percentUsed,
                tint: Color(nsColor: .systemOrange),
                accessibilityLabel: L("popover.extra.spent_label"))
            HStack(alignment: .firstTextBaseline) {
                Text(L(
                    "popover.extra.this_month",
                    PopoverFormatter.currency(self.extra.usedCredits),
                    PopoverFormatter.currency(self.extra.monthlyLimit)))
                    .font(.footnote)
                Spacer()
                Text(L("popover.extra.percent_used", Int(self.percentUsed.rounded())))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Cost (AC16 / EXB-1.7 AC7–AC8)

/// Local cost estimate from the JSONL scan. The header summarizes today / window totals; tapping it
/// expands the per-`(day, model)` breakdown (`byModel`) — the "cost detail submenu" of AC8.
private struct CostSection: View {
    let cost: ProviderCost
    let plan: ClaudePlan?

    @State private var expanded = false

    /// The value multiplier: 30-day estimated API-equivalent cost over the plan's monthly price.
    /// `nil` when the plan or its price is unknown — then no ROI line is shown, just the number.
    private var roiMultiplier: Int? {
        guard let price = self.plan?.approxMonthlyPriceUSD, price > 0, self.cost.last30Days > 0
        else { return nil }
        return Int((self.cost.last30Days / price).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { self.expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("popover.cost.title"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(self.cost.byModel.isEmpty)

            // ROI is the hero (refinement): the multiplier is the big green number, the absolute
            // 30-day value drops to context below it. When the plan price is unknown there is no
            // multiplier, so the absolute value stands alone as the primary number instead.
            if let roi = self.roiMultiplier, let plan = self.plan {
                Label(
                    L("popover.cost.roi", roi, plan.compactLoginMethod),
                    systemImage: "arrow.up.right")
                    .font(DesignTokens.Numeral.compact)
                    .foregroundStyle(PopoverStyle.roiPositive)
                    .monospacedDigit()
                Text(PopoverFormatter.currency(self.cost.last30Days))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(PopoverFormatter.currency(self.cost.last30Days))
                    .font(.body)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            Text(L(
                "popover.cost.today",
                PopoverFormatter.currency(self.cost.today),
                PopoverFormatter.tokenCount(self.cost.todayTokens)))
                .font(.caption)
                .foregroundStyle(.secondary)

            if self.expanded, !self.cost.byModel.isEmpty {
                CostModelBreakdown(byModel: self.cost.byModel)
                    .padding(.top, 4)
            }
        }
    }
}

/// The expanded cost breakdown: one row per *distinct* model (not per day), capped at a readable
/// top-N with an overflow line, each row a name + a proportion mini-bar + right-aligned $ and tokens
/// in fixed columns. Aggregation lives here so the view is correct even though the upstream scanner
/// emits per-(day, model) rows — distinct models is the unit the human reasons about.
private struct CostModelBreakdown: View {
    let byModel: [ModelCostEntry]

    /// How many model rows to show before folding the rest into an overflow line.
    private static let topN = 5

    private struct ModelTotal: Identifiable {
        let model: String
        let cost: Double
        let tokens: Int
        var id: String { self.model }
    }

    /// One row per distinct model, summed across days, sorted by cost desc.
    private var totals: [ModelTotal] {
        var acc: [String: (cost: Double, tokens: Int)] = [:]
        for entry in self.byModel {
            acc[entry.model, default: (0, 0)].cost += entry.cost
            acc[entry.model, default: (0, 0)].tokens += entry.totalTokens
        }
        return acc
            .map { ModelTotal(model: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.cost > $1.cost }
    }

    var body: some View {
        let all = self.totals
        let shown = Array(all.prefix(Self.topN))
        let overflow = all.dropFirst(Self.topN)
        let maxCost = all.first?.cost ?? 1

        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { item in
                CostModelRow(
                    name: Self.displayName(item.model),
                    cost: item.cost,
                    tokens: item.tokens,
                    fraction: maxCost > 0 ? item.cost / maxCost : 0)
            }
            if !overflow.isEmpty {
                let restCost = overflow.reduce(0) { $0 + $1.cost }
                HStack(spacing: 8) {
                    Text(L("popover.cost.more_models", overflow.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(PopoverFormatter.currency(restCost))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.leading, 8)
    }

    /// Strips the `claude-` vendor prefix for the narrow popover; the family is obvious in context, so
    /// `opus-4` reads cleaner than `claude-opus-4` and leaves room for the columns.
    static func displayName(_ raw: String) -> String {
        raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
    }
}

/// One model row: truncated name + proportion mini-bar + fixed-width $ and token columns, so the eye
/// scans straight down the numbers. The bar shares the brand tint at low opacity — a proportion cue,
/// not a risk zone, so it stays neutral terracotta (no amber/red semantics).
private struct CostModelRow: View {
    let name: String
    let cost: Double
    let tokens: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(self.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 70, alignment: .leading)
            ProportionBar(fraction: self.fraction)
                .frame(height: 4)
            Text(PopoverFormatter.currency(self.cost))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Text(PopoverFormatter.tokenCount(self.tokens))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// A neutral proportion bar (largest model = full width). Distinct from `UsageProgressBar`: no zone
/// colour, no markers, no pace — it answers "how big is this slice", not "how close to the limit".
private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let width = max(2, geo.size.width * min(1, max(0, self.fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverStyle.progressTrack)
                Capsule().fill(DesignTokens.brand.opacity(0.55)).frame(width: width)
            }
        }
    }
}

// MARK: - Actions (AC17–AC19)

private struct ActionSection: View {
    let showRelogin: Bool
    let actions: UsageCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(symbol: "arrow.clockwise", label: L("popover.refresh_now"), shortcut: "⌘R", action: self.actions.refresh)
            // EXB-2.3 AC1: the local dashboard row sits above the web link with the ⌘D shortcut.
            ActionRow(symbol: "chart.bar.xaxis", label: L("popover.dashboard"), shortcut: "⌘D", action: self.actions.openLocalDashboard)
            ActionRow(symbol: "chart.bar", label: L("popover.claude_usage_web"), shortcut: nil, action: self.actions.openUsageDashboard)
            ActionRow(symbol: "dot.radiowaves.up.forward", label: L("popover.status_page"), shortcut: nil, action: self.actions.openStatusPage)
            if self.showRelogin {
                ActionRow(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    label: L("popover.relogin"),
                    shortcut: nil,
                    action: self.actions.openRelogin)
            }
            ActionRow(symbol: "gearshape", label: L("popover.settings"), shortcut: "⌘,", action: self.actions.openSettings)
            ActionRow(symbol: "power", label: L("popover.quit"), shortcut: "⌘Q", action: self.actions.quit)
        }
    }
}

/// A 28 pt action row with hover highlight (AC17/AC19): icon (16×16 template) + label + shortcut.
private struct ActionRow: View {
    let symbol: String
    let label: String
    let shortcut: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Image(systemName: self.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16, height: 16)
                Text(self.label)
                Spacer()
                if let shortcut = self.shortcut {
                    Text(shortcut)
                        .font(.system(size: NSFont.smallSystemFontSize))
                        .foregroundStyle(self.isHovered ? Color(nsColor: .selectedMenuItemTextColor) : .secondary)
                }
            }
            .foregroundStyle(self.isHovered ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .labelColor))
            .frame(height: PopoverStyle.actionRowHeight)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.isHovered ? Color(nsColor: .selectedContentBackgroundColor) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in self.isHovered = hovered }
    }
}
