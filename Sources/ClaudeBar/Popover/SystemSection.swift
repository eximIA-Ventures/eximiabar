import AppKit
import ClaudeBarCore
import SwiftUI

/// The "System" section of the dropdown card: physical-RAM headroom, the Claude CLI footprint,
/// and — expanded — one row per live session (folder, RAM, idle time, terminate button for idle
/// ones) plus a warning when 2+ sessions share the same git working tree.
///
/// Data comes from the app-level `SystemStatsProvider` (continuous 30 s sampling so idle tracking
/// works while the popover is closed); this view only adds a faster 5 s cadence while visible.
struct SystemSection: View {
    /// Extra re-sample cadence while the section is on screen.
    private static let visibleSampleInterval: Duration = .seconds(5)

    let provider: SystemStatsProvider

    @State private var expanded = false
    /// Active popover skin — the RAM numeral/bar use the same zone palette as the metric rows.
    @Environment(\.popoverTheme) private var popoverTheme

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            self.header

            if let stats = self.provider.stats {
                let usedPercent = 100 - stats.memoryFreePercent
                UsageProgressBar(
                    percent: usedPercent,
                    tint: PopoverStyle.zoneBarColor(utilization: usedPercent, theme: self.popoverTheme),
                    accessibilityLabel: L("popover.system.free", Int(stats.memoryFreePercent.rounded())))

                HStack(alignment: .firstTextBaseline) {
                    Text(L("popover.system.free", Int(stats.memoryFreePercent.rounded())))
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.claudeLine(stats))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ForEach(self.provider.collisionPaths, id: \.self) { path in
                    CollisionWarningRow(path: path)
                }

                if self.expanded, !stats.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(stats.sessions) { session in
                            SessionRow(
                                session: session,
                                idleDuration: self.provider.idleByPid[session.pid],
                                terminate: { self.confirmAndTerminate(session) })
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.top, 2)
                }
            } else {
                Text(L("popover.system.sampling"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                await self.provider.sampleNow()
                do {
                    try await Task.sleep(for: Self.visibleSampleInterval)
                } catch {
                    return
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { self.expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("popover.system.title"))
                    .font(MetricRow.Prominence.secondary.titleFont)
                    .foregroundStyle(.secondary)
                    .tracking(DesignTokens.sectionTracking)
                    .lineLimit(1)
                Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let stats = self.provider.stats {
                    // Big numeral = RAM **used** percent, same zone palette and weight as the
                    // Weekly row, so every big number in the card means "how much is consumed".
                    let usedPercent = 100 - stats.memoryFreePercent
                    Text(verbatim: "\(Int(usedPercent.rounded()))%")
                        .font(MetricRow.Prominence.secondary.numberFont)
                        .foregroundStyle(PopoverStyle.zoneTextColor(
                            utilization: usedPercent, theme: self.popoverTheme))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.provider.stats?.sessions.isEmpty != false)
    }

    private static func claudeLine(_ stats: SystemStats) -> String {
        let bytes = PopoverFormatter.bytes(stats.claudeResidentBytes)
        return stats.claudeSessionCount == 1
            ? L("popover.system.claude_line_one", bytes)
            : L("popover.system.claude_line", bytes, stats.claudeSessionCount)
    }

    /// AppKit confirmation before SIGTERM — termination must never be a single accidental click.
    private func confirmAndTerminate(_ session: ClaudeSessionInfo) {
        let idleText = UsagePaceText.durationText(
            seconds: self.provider.idleByPid[session.pid] ?? 0)
        let alert = NSAlert()
        alert.messageText = L("popover.system.kill_title")
        alert.informativeText = L(
            "popover.system.kill_body",
            PopoverFormatter.abbreviatePath(session.workingDirectory),
            idleText,
            PopoverFormatter.bytes(session.residentBytes))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("popover.system.kill_confirm"))
        alert.addButton(withTitle: L("popover.system.kill_cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.provider.terminateSession(pid: session.pid)
        Task { await self.provider.sampleNow() }
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: ClaudeSessionInfo
    /// `nil` while activity is still unknown (first sample).
    let idleDuration: TimeInterval?
    let terminate: () -> Void

    private var isIdle: Bool {
        (self.idleDuration ?? 0) >= SystemStatsProvider.idleThreshold
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(self.session.workingDirectory.isEmpty
                ? L("popover.system.session_unknown_dir")
                : PopoverFormatter.abbreviatePath(self.session.workingDirectory))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if self.isIdle, let idle = self.idleDuration {
                Text(L("popover.system.session_idle", UsagePaceText.durationText(seconds: idle)))
                    .font(.caption2)
                    .foregroundStyle(PopoverStyle.brand)
                    .lineLimit(1)
            }
            Text(PopoverFormatter.bytes(self.session.residentBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if self.isIdle {
                Button(action: self.terminate) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("popover.system.kill_title"))
            }
        }
    }
}

// MARK: - Collision warning

private struct CollisionWarningRow: View {
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(L("popover.system.collision", PopoverFormatter.abbreviatePath(self.path)))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color(nsColor: .systemOrange))
    }
}
