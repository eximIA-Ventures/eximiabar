import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.7 §1 — the daily average divides by the days the source **covers**, never by the width of the
/// requested window.
///
/// The three divisors that could plausibly be used all disagree on the fixtures below, on purpose: a
/// test that only distinguished "the bug" from "the fix" would pass just as happily on the opposite
/// error (dividing by days *with usage*), which overstates the average instead of understating it.
struct DashboardDenominatorTests {
    /// A fixed instant so the day arithmetic never straddles a real midnight.
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    private func entry(_ date: Date, cost: Double) -> ModelCostEntry {
        ModelCostEntry(
            model: "claude-sonnet-4", date: date,
            inputTokens: 5_000, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, cost: cost)
    }

    private func analytics(_ entries: [ModelCostEntry], covered: Set<Date> = []) -> UsageAnalytics {
        UsageAnalytics(
            byDayModel: entries, byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0, coveredDays: covered)
    }

    /// Cobertura de 10 dias dentro de uma janela de 90, com atividade em apenas 2 deles.
    ///
    ///   divisor 90 (o bug) → 0,333…   ·   divisor 2 (o erro oposto) → 15,0   ·   divisor 10 → 3,0
    @Test
    func mediaDiariaDividePelosDiasCobertos() {
        let data = DashboardData.build(
            from: analytics([entry(day(9), cost: 15.0), entry(day(0), cost: 15.0)]),
            span: DashboardSpan(inicio: day(89), fim: day(0)), now: now)

        #expect(data.diasComDado == 10)
        #expect(abs(data.averageDailyCost - 3.0) < 1e-9)
        #expect(abs(data.averageDailyCost - 0.3333333333) > 1e-3) // não é a janela (90)
        #expect(abs(data.averageDailyCost - 15.0) > 1e-9)         // nem os dias com uso (2)
    }

    /// Um dia de NÃO USO dentro da cobertura é dado legítimo e conta no denominador. Sem esta
    /// asserção, a correção erraria para o outro lado.
    @Test
    func diaSemUsoDentroDaCoberturaEntraNoDenominador() {
        let data = DashboardData.build(
            from: analytics([entry(day(4), cost: 10.0), entry(day(0), cost: 10.0)]),
            period: .thirtyDays, now: now)

        #expect(data.diasComDado == 5)
        #expect(abs(data.averageDailyCost - 4.0) < 1e-9)  // 20 ÷ 5, não 20 ÷ 2 = 10
    }

    /// Janela menor que a cobertura: o divisor é a janela, não a história inteira.
    @Test
    func janelaMenorQueACoberturaLimitaODenominador() {
        let data = DashboardData.build(
            from: analytics((0...20).map { entry(day($0), cost: 1.0) }),
            period: .sevenDays, now: now)

        #expect(data.diasComDado == 7)
        #expect(abs(data.averageDailyCost - 1.0) < 1e-9)
    }

    /// `coveredDays` é a fonte preferida: ela sabe de dias que o arquivo observou e que a atividade
    /// sozinha não revela. Aqui a atividade começa 2 dias atrás, mas a cobertura alcança 6 —
    /// o divisor tem de seguir a cobertura, não a atividade.
    @Test
    func coveredDaysVenceAAtividadeQuandoPresente() {
        let covered = Set((0...6).map { day($0) })
        let data = DashboardData.build(
            from: analytics([entry(day(2), cost: 14.0)], covered: covered),
            period: .thirtyDays, now: now)

        #expect(data.diasComDado == 7)
        #expect(abs(data.averageDailyCost - 2.0) < 1e-9)  // 14 ÷ 7, não 14 ÷ 3
    }
}
