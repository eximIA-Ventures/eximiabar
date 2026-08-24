import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.7 §3 — a taxa de cache com o denominador completo e uma formatação que não afirma absolutos
/// que não ocorreram.
///
/// O valor em dólar que acompanhava esta taxa saiu da tela por decisão do dono, e com ele saiu o
/// teste que o fixava: `DashboardInsightsTests.estimatedCacheSavingsUsesDominantModelPricing`
/// assertava `0.0147`, que é `1000 × (output − 0,1·input)` — a conta que precifica token de ENTRADA
/// pela tabela de SAÍDA, inflando 5,444× exatos. Um teste verde que fixa o defeito impede a correção
/// e ainda parece diligência.
struct DashboardCacheRateTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    // MARK: - O denominador

    /// `cacheWrite` entra no denominador. Sem ele a taxa é 0,75; com ele, 0,60.
    @Test
    func taxaIncluiCacheWriteNoDenominador() {
        let taxa = DashboardData.cacheHitRate(input: 1_000, cacheRead: 3_000, cacheWrite: 1_000)

        #expect(abs(taxa - 0.60) < 1e-9)
        #expect(abs(taxa - 0.75) > 1e-9)   // não é a conta antiga
    }

    /// Denominador zero não vira NaN.
    @Test
    func semAtividadeNaoProduzNaN() {
        #expect(DashboardData.cacheHitRate(input: 0, cacheRead: 0, cacheWrite: 0) == 0)
    }

    /// O `build` inteiro usa o denominador completo, não só o helper.
    @Test
    func buildPropagaODenominadorCompleto() {
        let a = UsageAnalytics(
            byDayModel: [ModelCostEntry(
                model: "claude-sonnet-4", date: day(0),
                inputTokens: 1_000, outputTokens: 500,
                cacheReadTokens: 3_000, cacheWriteTokens: 1_000, cost: 1.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: a, period: .sevenDays, now: now)

        #expect(abs(data.cacheHitRate - 0.60) < 1e-9)
        #expect(data.tokensDeCache == 3_000)
        #expect(data.tokensDeEntrada == 5_000)   // input + cacheRead + cacheWrite, sem o output
    }

    // MARK: - A formatação

    /// 0,9996 é 99,9%, nunca 100,0% — o absoluto que não ocorreu.
    @Test
    func taxaTruncaEmVezDeArredondar() {
        let taxa = DashboardData.cacheHitRate(input: 1, cacheRead: 2_499, cacheWrite: 0)
        #expect(abs(taxa - 0.9996) < 1e-9)

        #expect(DashboardFormat.taxaCache(taxa) == "99.9%")
        #expect(DashboardFormat.taxaCache(1.0) == "100.0%")   // o absoluto real ainda aparece
    }

    /// O truncamento vale em toda a faixa, não só na borda dos 100%.
    @Test
    func truncamentoValeEmTodaAFaixa() {
        #expect(DashboardFormat.taxaCache(0.63499) == "63.4%")   // arredondar daria 63.5%
        #expect(DashboardFormat.taxaCache(0.0) == "0.0%")
        #expect(DashboardFormat.taxaCache(0.5) == "50.0%")
    }
}
