import AppKit
import ClaudeBarCore
import SwiftUI

/// The actions the card can trigger. The panel controller supplies a concrete implementation;
/// `UsageCardView` stays a pure function of the snapshot plus this callback set.
struct UsageCardActions {
    var refresh: () -> Void = {}
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeaderSection(snapshot: self.snapshot)

            Divider() // AC8

            MetricsSection(snapshot: self.snapshot)

            if let extra = self.snapshot?.extraUsage, extra.isEnabled {
                Divider()
                ExtraUsageSection(extra: extra)
            }

            // AC11: the cost section is present only when a scan produced a `ProviderCost`
            // (`costEnabled == true`). When cost is disabled it is `nil` and the section is hidden.
            if let cost = self.snapshot?.cost {
                Divider()
                CostSection(cost: cost)
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
                Text("Claude")
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
            Text("Refreshing…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let updatedAt = self.snapshot?.updatedAt, updatedAt != .distantPast {
            Text(PopoverFormatter.updatedText(from: updatedAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("Not fetched yet")
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
        .accessibilityLabel(self.didCopy ? "Copied" : "Copy error")
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

    private var weeklyPace: UsagePace? {
        guard let weekly = self.snapshot?.weekly else { return nil }
        return UsagePace.compute(window: weekly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricRowSpacing) {
            if let session = self.snapshot?.session {
                MetricRow(title: "Session", window: session)
            }
            if let weekly = self.snapshot?.weekly {
                let pace = self.weeklyPace
                MetricRow(
                    title: "Weekly",
                    window: weekly,
                    showPace: pace != nil,
                    pace: pace,
                    paceDetail: pace.map { UsagePaceText.detail(for: $0) })
            }
            // Sonnet (AC11): hidden when nil.
            if let sonnet = self.snapshot?.sonnet {
                MetricRow(title: "Sonnet", window: sonnet)
            }
            // Daily Routines (AC12): conditional.
            if let daily = self.snapshot?.dailyRoutines {
                MetricRow(title: "Daily Routines", window: daily)
            }
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
            Text("Extra usage")
                .font(.body)
                .fontWeight(.medium)
            UsageProgressBar(
                percent: self.percentUsed,
                tint: Color(nsColor: .systemOrange),
                accessibilityLabel: "Extra usage spent")
            HStack(alignment: .firstTextBaseline) {
                Text("This month: \(PopoverFormatter.currency(self.extra.usedCredits)) / \(PopoverFormatter.currency(self.extra.monthlyLimit))")
                    .font(.footnote)
                Spacer()
                Text("\(Int(self.percentUsed.rounded()))% used")
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

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { self.expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Estimated cost")
                        .font(.body)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(self.cost.byModel.isEmpty)

            Text("Today: \(PopoverFormatter.currency(self.cost.today)) · \(PopoverFormatter.tokenCount(self.cost.todayTokens)) tokens")
                .font(.footnote)
            Text("Last 30 days: \(PopoverFormatter.currency(self.cost.last30Days)) · \(PopoverFormatter.tokenCount(self.cost.last30DaysTokens)) tokens")
                .font(.footnote)

            if self.expanded, !self.cost.byModel.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(self.cost.byModel.enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.model): \(PopoverFormatter.currency(entry.cost)) · \(PopoverFormatter.tokenCount(entry.totalTokens)) tokens")
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
            ActionRow(symbol: "arrow.clockwise", label: "Refresh Now", shortcut: "⌘R", action: self.actions.refresh)
            ActionRow(symbol: "chart.bar", label: "Usage Dashboard", shortcut: nil, action: self.actions.openUsageDashboard)
            ActionRow(symbol: "dot.radiowaves.up.forward", label: "Status Page", shortcut: nil, action: self.actions.openStatusPage)
            if self.showRelogin {
                ActionRow(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    label: "Re-login at claude.ai",
                    shortcut: nil,
                    action: self.actions.openRelogin)
            }
            ActionRow(symbol: "gearshape", label: "Settings…", shortcut: "⌘,", action: self.actions.openSettings)
            ActionRow(symbol: "power", label: "Quit", shortcut: "⌘Q", action: self.actions.quit)
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
