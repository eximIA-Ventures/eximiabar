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
    }
}

// MARK: - Header (AC7)

private struct HeaderSection: View {
    let snapshot: DisplaySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.headerLineSpacing) {
            // Line 1: "Claude" + email.
            HStack(alignment: .firstTextBaseline, spacing: PopoverStyle.headerColumnSpacing) {
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
                    Text(plan.compactLoginMethod)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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

    private var weeklyPace: UsagePace? {
        guard let weekly = self.snapshot?.weekly else { return nil }
        return UsagePace.compute(window: weekly)
    }

    /// Alarm horizon (minutes): the forecast line shows only when the projected run-out is within
    /// this many minutes — i.e. when it actually changes the user's decision (EXB redesign #4).
    /// Sub-windows (sonnet/opus/daily) return `nil` → forecast never shown there.
    private func forecastHorizon(for windowId: String) -> Double? {
        switch windowId {
        case RateWindowID.session: return 60
        case RateWindowID.weekly: return 720
        default: return nil
        }
    }

    /// The localized exhaustion-forecast line for `windowId`, shown only when it crosses the alarm
    /// horizon for that window (#4); otherwise `nil` so the row renders no forecast line. The bar and
    /// headline already tell the calm story — the text appears only when it's an alarm.
    private func forecastText(for windowId: String) -> String? {
        guard let forecast = self.snapshot?.forecast(for: windowId),
              let minutes = forecast.minutesRemaining,
              minutes.isFinite, minutes >= 0
        else { return nil }
        // Text mode: the forecast IS the chosen pace indicator, so show it always. Bar mode: the
        // stripe carries pace, so the text appears only when it crosses the alarm horizon (#4).
        if self.options.paceDisplayMode == .text {
            return PopoverFormatter.forecastText(minutesRemaining: minutes)
        }
        guard let horizon = self.forecastHorizon(for: windowId), minutes < horizon else { return nil }
        return PopoverFormatter.forecastText(minutesRemaining: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricRowSpacing) {
            if let session = self.snapshot?.session {
                MetricRow(
                    title: L("popover.metric.session"),
                    window: session,
                    warningMarkerPercents: self.markers(thresholds: self.options.sessionThresholds, isWeekly: false),
                    showUsed: self.options.showUsed,
                    showAbsoluteReset: self.options.showAbsoluteReset,
                    prominence: .primary,
                    forecastText: self.forecastText(for: RateWindowID.session))
            }
            if let weekly = self.snapshot?.weekly {
                let pace = self.weeklyPace
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
                    forecastText: self.forecastText(for: RateWindowID.weekly))
            }
            // Per-model sub-windows (Opus + Sonnet). The "Por modelo" group label appears only with
            // 2+ models — a label over a single child is empty ceremony (refinement). Rotinas Diárias
            // removed; Haiku and routines fold into the weekly global cap (no separate API window).
            let models: [(id: String, title: String, window: RateWindow)] = [
                self.snapshot?.opus.map { (RateWindowID.opus, L("popover.metric.opus"), $0) },
                self.snapshot?.sonnet.map { (RateWindowID.sonnet, L("popover.metric.sonnet"), $0) },
            ].compactMap { $0 }
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if models.count >= 2 {
                        Text(L("popover.metric.by_model"))
                            .font(DesignTokens.Label.section)
                            .foregroundStyle(.tertiary)
                            .tracking(DesignTokens.sectionTracking)
                    }
                    ForEach(models, id: \.id) { model in
                        ModelRow(title: model.title, window: model.window)
                    }
                }
            }
        }
    }
}

/// A thin "per-model" row (Opus / Sonnet): name, a slim bar, and the consumed %. No reset line —
/// the models share the weekly reset shown above, so repeating it would be noise (EXB redesign #3).
private struct ModelRow: View {
    let title: String
    let window: RateWindow

    var body: some View {
        HStack(spacing: 10) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            UsageProgressBar(
                percent: self.window.utilization,
                tint: PopoverStyle.zoneBarColor(utilization: self.window.utilization),
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
                    .font(DesignTokens.Numeral.large)
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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(self.cost.byModel.enumerated()), id: \.offset) { _, entry in
                        Text(L(
                            "popover.cost.model_line",
                            entry.model,
                            PopoverFormatter.currency(entry.cost),
                            PopoverFormatter.tokenCount(entry.totalTokens)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 2)
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
