import AppKit
import ClaudeBarCore
import SwiftUI

/// The "System" section of the dropdown card: physical-RAM headroom plus the Claude CLI footprint
/// (summed RSS + session count). Self-sampling: unlike the usage sections it is not fed by the
/// fetch pipeline — it owns a lightweight loop that re-samples every 5 s while the panel is open,
/// always off the main thread (anti-freeze invariant; the sampler is pure syscalls, no subprocess).
struct SystemSection: View {
    /// Re-sample cadence while the section is visible.
    private static let sampleInterval: Duration = .seconds(5)

    @State private var stats: SystemStats?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverStyle.metricInternalSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("popover.system.title"))
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                if let stats = self.stats {
                    Text(L("popover.system.free", Int(stats.memoryFreePercent.rounded())))
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(Self.statusColor(freePercent: stats.memoryFreePercent))
                }
            }

            if let stats = self.stats {
                UsageProgressBar(
                    percent: 100 - stats.memoryFreePercent,
                    tint: Self.statusColor(freePercent: stats.memoryFreePercent),
                    accessibilityLabel: L("popover.system.free", Int(stats.memoryFreePercent.rounded())))

                Text(Self.claudeLine(stats))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("popover.system.sampling"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await self.sampleLoop() }
    }

    // MARK: - Presentation

    /// 🟢 comfortable / 🟡 tightening / 🔴 under pressure, keyed on free RAM.
    private static func statusColor(freePercent: Double) -> Color {
        if freePercent >= 40 { return Color(nsColor: .systemGreen) }
        if freePercent >= 20 { return Color(nsColor: .systemYellow) }
        return Color(nsColor: .systemRed)
    }

    private static func claudeLine(_ stats: SystemStats) -> String {
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: stats.claudeResidentBytes),
            countStyle: .memory)
        return stats.claudeSessionCount == 1
            ? L("popover.system.claude_line_one", bytes)
            : L("popover.system.claude_line", bytes, stats.claudeSessionCount)
    }

    // MARK: - Sampling

    private func sampleLoop() async {
        while !Task.isCancelled {
            let sample = await Task.detached(priority: .utility) { SystemStatsSampler.sample() }.value
            if Task.isCancelled { return }
            self.stats = sample
            do {
                try await Task.sleep(for: Self.sampleInterval)
            } catch {
                return
            }
        }
    }
}
