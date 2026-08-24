import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.7 §7 — a régua mensal compara FAIXAS EQUIVALENTES, não mês-até-agora contra mês inteiro.
///
/// A armadilha tem sinal fixo, e é isso que a torna perigosa: em 24 de agosto, 24 dias contra 31
/// dão −22,6% mesmo com ritmo rigorosamente idêntico. O painel anunciaria "consumo caindo" todo dia
/// primeiro de cada mês, para sempre, e seria acreditado. As fixtures abaixo usam ritmo constante de
/// propósito: a resposta certa é sempre 0%, então qualquer implementação que erre a faixa aparece.
struct DashboardMonthlyComparisonTests {
    private let cal = Calendar.current

    private func data(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = cal.timeZone
        return f.date(from: iso)!
    }

    /// Um mapa dia → tokens com ritmo constante em todo o intervalo, inclusive.
    private func ritmoConstante(de inicio: String, ate fim: String, tokensDia: Int) -> [Date: Int] {
        var mapa: [Date: Int] = [:]
        var dia = cal.startOfDay(for: data(inicio))
        let ultimo = cal.startOfDay(for: data(fim))
        while dia <= ultimo {
            mapa[dia] = tokensDia
            guard let proximo = cal.date(byAdding: .day, value: 1, to: dia) else { break }
            dia = proximo
        }
        return mapa
    }

    /// Julho e agosto com 100 tokens/dia idênticos. Em 24 de agosto:
    ///   correto   (1–24 jul vs 1–24 ago): 2.400 vs 2.400 →   0%
    ///   armadilha (jul inteiro vs ago até agora): 3.100 vs 2.400 → −22,6%
    @Test
    func comparaFaixasEquivalentesNaoMesInteiro() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-07-01", ate: "2026-08-24", tokensDia: 100),
            coberturaInicio: data("2026-07-01"),
            now: data("2026-08-24"))

        let c = try! #require(comp)
        #expect(c.diasComparados == 24)
        #expect(c.tokensAtual == 2_400)
        #expect(c.tokensAnterior == 2_400)          // 1–24 de julho, NÃO os 3.100 do mês inteiro
        #expect(abs(c.variacao - 0.0) < 1e-9)
        #expect(abs(c.variacao + 0.226) > 0.01)     // e NÃO a armadilha
        #expect(c.truncado == false)
    }

    /// Sem mês anterior completo, não há comparação — e não se inventa uma. Este é exatamente o caso
    /// da máquina do Senhor: o histórico do Claude Code começa em 01/07 e os meses antes disso foram
    /// apagados pela retenção.
    @Test
    func semMesAnteriorCompletoNaoComparaNada() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-07-15", ate: "2026-08-24", tokensDia: 100),
            coberturaInicio: data("2026-07-15"),     // julho está incompleto
            now: data("2026-08-24"))

        #expect(comp == nil)
    }

    /// 31 de março contra fevereiro: trunca ao mês menor e MARCA o recorte.
    @Test
    func mesesDeComprimentosDiferentesTruncamAoMenor() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-02-01", ate: "2026-03-31", tokensDia: 100),
            coberturaInicio: data("2026-02-01"),
            now: data("2026-03-31"))

        let c = try! #require(comp)
        #expect(c.diasComparados == 28)             // não 31
        #expect(c.truncado == true)                 // e o rótulo tem de dizer isso
        #expect(abs(c.variacao - 0.0) < 1e-9)
    }

    /// Variação real é detectada com o sinal certo: agosto no dobro do ritmo de julho.
    @Test
    func variacaoRealApareceComOSinalCerto() {
        var mapa = ritmoConstante(de: "2026-07-01", ate: "2026-07-31", tokensDia: 100)
        for (dia, _) in ritmoConstante(de: "2026-08-01", ate: "2026-08-10", tokensDia: 200) {
            mapa[dia] = 200
        }
        let c = try! #require(DashboardData.comparacaoMensal(
            tokensPorDia: mapa, coberturaInicio: data("2026-07-01"), now: data("2026-08-10")))

        #expect(c.diasComparados == 10)
        #expect(c.tokensAtual == 2_000)
        #expect(c.tokensAnterior == 1_000)
        #expect(abs(c.variacao - 1.0) < 1e-9)       // +100%
    }

    /// Mês anterior sem consumo não vira divisão por zero nem "+∞%".
    @Test
    func mesAnteriorZeradoNaoProduzComparacao() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-08-01", ate: "2026-08-24", tokensDia: 100),
            coberturaInicio: data("2026-07-01"),     // coberto, mas sem consumo
            now: data("2026-08-24"))

        #expect(comp == nil)
    }

    // MARK: - Ligado ao build

    /// A janela de 7 dias nunca alcança o mês anterior, então o cartão simplesmente não existe nela.
    @Test
    func janelaDeSeteDiasNaoAlcancaOMesAnterior() {
        let agora = data("2026-08-24")
        let a = UsageAnalytics(
            byDayModel: [ModelCostEntry(
                model: "claude-sonnet-4", date: cal.startOfDay(for: agora),
                inputTokens: 100, outputTokens: 100,
                cacheReadTokens: 0, cacheWriteTokens: 0, cost: 1.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 1.0)

        #expect(DashboardData.build(from: a, period: .sevenDays, now: agora).comparacaoMensal == nil)
    }
}
