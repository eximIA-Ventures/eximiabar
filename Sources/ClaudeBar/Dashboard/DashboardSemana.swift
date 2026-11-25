import ClaudeBarCore
import SwiftUI

/// "What ate the week" (EXB-6.3): since the weekly window's last reset, how the consumed percentage
/// points split across projects and across the main session vs. each sub-agent.
///
/// Labelled as an **estimated proportion** in the section itself: the API reports one weekly number,
/// and the split is the local transcripts' estimated cost, not a measurement Anthropic made.
struct WeeklyAttributionSection: View {
    let semana: SemanaAtribuida

    /// Rows shown per list before the tail folds into one line.
    static let topN = 6

    /// `"12.4 p.p."` for a slice, or `nil` when the weekly reading is unknown.
    static func pontos(_ slice: WeeklyAttribution.Slice, de consumidos: Double?) -> String? {
        guard let consumidos else { return nil }
        return L("dashboard.week.points", String(format: "%.1f", slice.points(of: consumidos)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionLabel(text: L("dashboard.week.title"))
            Text(self.subtitulo)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if self.semana.atribuicao.isEmpty {
                Text(L("dashboard.week.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    WeeklySliceList(
                        titulo: L("dashboard.week.by_project"),
                        fatias: self.semana.atribuicao.byProject,
                        consumidos: self.semana.pontosConsumidos)
                    WeeklySliceList(
                        titulo: L("dashboard.week.by_agent"),
                        fatias: self.semana.atribuicao.byAgent.map(Self.rotulado),
                        consumidos: self.semana.pontosConsumidos,
                        rodape: L("dashboard.week.subagents_total",
                                  Int((Self.subagentShare(self.semana.atribuicao) * 100).rounded())))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var subtitulo: String {
        var partes = [L("dashboard.week.since", DashboardFormat.longDate(self.semana.atribuicao.since))]
        if let pontos = self.semana.pontosConsumidos {
            partes.append(L("dashboard.week.consumed", Int(pontos.rounded())))
        }
        if !self.semana.inicioConhecido { partes.append(L("dashboard.week.no_reset")) }
        partes.append(L("dashboard.week.estimated"))
        return partes.joined(separator: " · ")
    }

    /// Share of the week that ran in sub-agents (everything but the main session).
    static func subagentShare(_ week: WeeklyAttribution) -> Double {
        week.byAgent.filter { $0.name != WeeklyAttribution.mainAgentName }.reduce(0) { $0 + $1.share }
    }

    /// The main session and the unnamed sub-agent carry localized labels; named agents keep theirs.
    static func rotulado(_ slice: WeeklyAttribution.Slice) -> WeeklyAttribution.Slice {
        let nome: String
        switch slice.name {
        case WeeklyAttribution.mainAgentName: nome = L("dashboard.week.agent.main")
        case WeeklyAttribution.unnamedSubagentName: nome = L("dashboard.week.agent.unnamed")
        default: return slice
        }
        return WeeklyAttribution.Slice(name: nome, weight: slice.weight, tokens: slice.tokens, share: slice.share)
    }
}

/// One ranked list: name, proportion bar, share and the slice's percentage points.
private struct WeeklySliceList: View {
    let titulo: String
    let fatias: [WeeklyAttribution.Slice]
    let consumidos: Double?
    var rodape: String? = nil

    var body: some View {
        let mostradas = Array(self.fatias.prefix(WeeklyAttributionSection.topN))
        let resto = self.fatias.dropFirst(WeeklyAttributionSection.topN)
        VStack(alignment: .leading, spacing: 6) {
            Text(self.titulo)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(mostradas) { fatia in
                HStack(spacing: 8) {
                    Text(fatia.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 130, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(DesignTokens.ModelPalette.ramp[0])
                                .frame(width: max(2, geo.size.width * fatia.share))
                        }
                    }
                    .frame(height: 6)
                    Text(verbatim: "\(Int((fatia.share * 100).rounded()))%")
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                    if let pontos = WeeklyAttributionSection.pontos(fatia, de: self.consumidos) {
                        Text(pontos)
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            if !resto.isEmpty {
                let share = resto.reduce(0) { $0 + $1.share }
                Text(L("dashboard.week.more", resto.count, Int((share * 100).rounded())))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let rodape = self.rodape {
                Text(rodape)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
