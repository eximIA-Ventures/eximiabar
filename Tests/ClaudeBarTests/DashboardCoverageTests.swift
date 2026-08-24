import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.7 §5 — "sem uso" e "sem dado" param de ser a mesma barra de altura zero.
///
/// O par de asserções no fim do primeiro teste é o coração disto: **dois dias com `costUSD == 0` e
/// significados opostos**. Uma implementação que só olhasse o valor não conseguiria distingui-los, e
/// é exatamente o que o gráfico fazia.
struct DashboardCoverageTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    private func entry(_ date: Date, cost: Double) -> ModelCostEntry {
        ModelCostEntry(
            model: "claude-sonnet-4", date: date,
            inputTokens: 1_000, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, cost: cost)
    }

    private func analytics(_ entries: [ModelCostEntry], covered: Set<Date> = []) -> UsageAnalytics {
        UsageAnalytics(
            byDayModel: entries, byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0, coveredDays: covered)
    }

    /// Janela de 30 dias, histórico começando 9 dias atrás: 10 dias cobertos, 20 descobertos —
    /// e os 20 NÃO são zeros legítimos.
    @Test
    func diasAnterioresAoHistoricoNaoSaoZeros() {
        let data = DashboardData.build(
            from: analytics([entry(day(9), cost: 1.0), entry(day(0), cost: 1.0)]),
            period: .thirtyDays, now: now)

        #expect(data.dailyCosts.count == 30)                       // o eixo continua 30
        #expect(data.dailyCosts.filter(\.coberto).count == 10)
        #expect(data.dailyCosts.filter { !$0.coberto }.count == 20)

        // O dia SEM USO dentro da cobertura é coberto, e vale zero legitimamente.
        let semUso = data.dailyCosts.first { $0.date == day(5) }
        #expect(semUso?.coberto == true)
        #expect(semUso?.costUSD == 0)

        // O dia FORA da cobertura também vale zero — mas não é a mesma coisa.
        let semDado = data.dailyCosts.first { $0.date == day(20) }
        #expect(semDado?.coberto == false)
        #expect(semDado?.costUSD == 0)
    }

    /// A âncora da cobertura é a mesma da §1: uma definição, dois consumidores.
    @Test
    func aMesmaAncoraGovernaODivisorEOsGraficos() {
        let data = DashboardData.build(
            from: analytics([entry(day(9), cost: 1.0), entry(day(0), cost: 1.0)]),
            period: .thirtyDays, now: now)

        #expect(data.diasComDado == data.dailyCosts.filter(\.coberto).count)
    }

    /// `coveredDays` alarga a cobertura para além da atividade — os dias observados sem uso deixam de
    /// ser desenhados como lacuna.
    @Test
    func coveredDaysAlargaACoberturaAlemDaAtividade() {
        let covered = Set((0...14).map { day($0) })
        let data = DashboardData.build(
            from: analytics([entry(day(2), cost: 1.0)], covered: covered),
            period: .thirtyDays, now: now)

        #expect(data.dailyCosts.filter(\.coberto).count == 15)
        #expect(data.dailyCosts.first { $0.date == day(10) }?.coberto == true)
        #expect(data.dailyCosts.first { $0.date == day(20) }?.coberto == false)
    }

    /// O domínio do eixo X permanece o da janela PEDIDA, mesmo com metade dela descoberta —
    /// senão trocaríamos um zero mentiroso por um eixo mentiroso.
    @Test
    func oEixoContinuaAbrangendoAJanelaPedida() {
        let data = DashboardData.build(
            from: analytics([entry(day(9), cost: 1.0), entry(day(0), cost: 1.0)]),
            period: .thirtyDays, now: now)

        let domain = try! #require(data.windowDomain)
        #expect(domain.lowerBound == day(29))
        #expect(domain.upperBound > day(0))
    }
}
