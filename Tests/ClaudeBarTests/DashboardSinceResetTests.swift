import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-6.3 — the "since reset" period and the week's attribution on the dashboard.
@MainActor
struct DashboardSinceResetTests {
    private let agora = Date(timeIntervalSince1970: 1_790_000_000)

    private final class Fonte: DashboardSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _pedidos: [Date] = []
        var pedidos: [Date] { lock.withLock { _pedidos } }

        func carregarHistoria(now: Date) async -> DashboardHistoria {
            DashboardHistoria(fingerprint: "fp", inicio: Calendar.current.date(byAdding: .day, value: -60, to: now))
        }

        func fatiar(_ intervalo: ClosedRange<Date>, now: Date) async -> UsageAnalytics {
            UsageAnalytics(
                byDayModel: [ModelCostEntry(model: "claude-sonnet-4", date: intervalo.upperBound,
                                            inputTokens: 1_000, outputTokens: 0,
                                            cacheReadTokens: 0, cacheWriteTokens: 0, cost: 1)],
                byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
                monthToDateCost: 0, monthToDateTokens: 0, coveredDays: [])
        }

        func atribuirSemana(desde: Date) async -> WeeklyAttribution {
            lock.withLock { _pedidos.append(desde) }
            return WeeklyAttribution(
                since: desde,
                byProject: [.init(name: "web-app", weight: 3, tokens: 30, share: 0.75),
                            .init(name: "api", weight: 1, tokens: 10, share: 0.25)],
                byAgent: [.init(name: WeeklyAttribution.mainAgentName, weight: 4, tokens: 40, share: 1)],
                totalWeight: 4)
        }
    }

    @Test
    func sinceResetSpanStartsAtResetMinusSevenDays() {
        let reset = agora.addingTimeInterval(2 * 86_400)
        let info = SemanaInfo(resetsAt: reset, utilization: 40)
        let span = DashboardPeriod.sinceReset.span(inicioDoHistorico: nil, inicioDaSemana: info.inicio, now: agora)
        #expect(span.inicio == Calendar.current.startOfDay(for: reset.addingTimeInterval(-7 * 86_400)))
        #expect(span.fim == Calendar.current.startOfDay(for: agora))
    }

    @Test
    func sinceResetWithoutWeeklyWindowFallsBackToSevenDays() {
        let span = DashboardPeriod.sinceReset.span(inicioDoHistorico: nil, inicioDaSemana: nil, now: agora)
        #expect(span == DashboardSpan.ultimos(7, now: agora))
    }

    @Test
    func attributionIsAttachedOnlyForSinceResetAndCachedPerStart() async {
        let fonte = Fonte()
        let instante = agora
        let reset = agora.addingTimeInterval(86_400)
        let m = DashboardRangeModel(
            source: fonte, atalhoInicial: .thirtyDays, agora: { instante },
            semana: { SemanaInfo(resetsAt: reset, utilization: 40) })
        await m.carregarUmaVez()
        #expect(m.dados?.semana == nil)

        await m.aplicarAtalho(.sinceReset)?.value
        let semana = m.dados?.semana
        #expect(semana?.pontosConsumidos == 40)
        #expect(semana?.inicioConhecido == true)
        let web = semana?.atribuicao.byProject.first
        #expect(web.map { abs($0.points(of: 40) - 30) < 1e-9 } == true)   // 75% of 40 p.p.
        #expect(fonte.pedidos == [reset.addingTimeInterval(-7 * 86_400)])

        await m.aplicarAtalho(.sevenDays)?.value
        #expect(m.dados?.semana == nil)
        await m.aplicarAtalho(.sinceReset)?.value
        #expect(fonte.pedidos.count == 1)   // cached: the window only moves at a reset
    }

    @Test
    func pointsLabelAndLocalizedAgentNames() {
        let slice = WeeklyAttribution.Slice(name: WeeklyAttribution.mainAgentName, weight: 1, tokens: 1, share: 0.5)
        #expect(WeeklyAttributionSection.pontos(slice, de: 30) == "15.0 p.p.")
        #expect(WeeklyAttributionSection.pontos(slice, de: nil) == nil)
        #expect(WeeklyAttributionSection.rotulado(slice).name == "main session")
        let week = WeeklyAttribution(
            since: agora,
            byProject: [],
            byAgent: [.init(name: WeeklyAttribution.mainAgentName, weight: 6, tokens: 6, share: 0.6),
                      .init(name: "dev", weight: 4, tokens: 4, share: 0.4)],
            totalWeight: 10)
        #expect(abs(WeeklyAttributionSection.subagentShare(week) - 0.4) < 1e-9)
    }
}
