import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.7 §2 + §6 — o badge de hoje compara TOKENS e normaliza pela fração do dia decorrida.
///
/// O defeito que isto substitui era aritmeticamente inevitável, não intermitente: o dia de hoje,
/// ainda em curso, era comparado contra uma média de dias INTEIROS. Às 9h, 37,5% do dia decorreu,
/// então o badge era obrigado a dizer "abaixo da média" numa manhã recordista. A fixture principal
/// abaixo é escolhida para **inverter o sinal** — a implementação antiga dizia −25%, a certa diz +100%.
struct DashboardDeltaTests {
    /// Um instante fixo às `horas:minutos` locais de um dia qualquer.
    private func hoje(as horas: Int, _ minutos: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_787_000_000))
        return cal.date(byAdding: .init(hour: horas, minute: minutos), to: base)!
    }

    // MARK: - A normalização

    /// Às 9h, com 3.000 tokens e média de 4.000/dia, o ritmo real é 8.000/dia — o DOBRO da média.
    /// A comparação crua (3.000 vs 4.000) daria −25%.
    @Test
    func deltaNormalizaPelaFracaoDoDiaDecorrida() {
        let delta = DashboardData.dailyDelta(
            todayTokens: 3_000, averageDailyTokens: 4_000, now: hoje(as: 9))

        let valor = try! #require(delta)
        #expect(abs(valor - 1.0) < 1e-9)       // +100%
        #expect(valor > 0)                     // o sinal, que é o que o Senhor lê
        #expect(abs(valor + 0.25) > 1e-9)      // e NÃO os −25% da comparação crua
    }

    /// Fim do dia: a normalização converge para a comparação direta.
    @Test
    func fimDoDiaConvergeParaComparacaoDireta() {
        let delta = DashboardData.dailyDelta(
            todayTokens: 4_000, averageDailyTokens: 4_000, now: hoje(as: 23, 59))

        #expect(abs(try! #require(delta)) < 0.001)
    }

    // MARK: - Os dois limites

    /// Primeira hora do dia: não há base para comparar. Sem esta zona morta, 00:05 divide por 0,0035
    /// e transforma uma única mensagem em "+28.000% acima da média".
    @Test
    func primeiraHoraNaoProduzDelta() {
        #expect(DashboardData.dailyDelta(
            todayTokens: 500, averageDailyTokens: 4_000, now: hoje(as: 0, 30)) == nil)
    }

    /// Piso de 3h: às 2h, 500 tokens são projetados como 4.000/dia (delta 0), não como 6.000/dia
    /// (delta +0,5) que a fração crua daria. O piso faz a projeção SUBESTIMAR nessa faixa, de propósito.
    @Test
    func pisoDeTresHorasAmorteceOInicioDoDia() {
        let delta = try! #require(DashboardData.dailyDelta(
            todayTokens: 500, averageDailyTokens: 4_000, now: hoje(as: 2)))

        #expect(abs(delta - 0.0) < 1e-9)
        #expect(abs(delta - 0.5) > 1e-9)       // não é a fração crua
    }

    /// A amplificação sem freio é o que o par zona-morta/piso existe para impedir: às 00:05 a fração
    /// crua é 0,0035, e 100 tokens virariam ~28.800/dia.
    @Test
    func semOsLimitesAAmplificacaoSeriaAbsurda() {
        let fracaoCrua = DashboardData.fracaoDoDiaDecorrida(now: hoje(as: 0, 5))
        #expect(fracaoCrua < DashboardData.deltaZonaMorta)
        #expect(100.0 / fracaoCrua > 25_000)   // o número que a zona morta impede de aparecer
    }

    // MARK: - Os quatro estados

    @Test
    func estadoCedoDemaisSeparaSeDeSemUso() {
        #expect(DashboardData.dailyDeltaState(
            todayTokens: 0, averageDailyTokens: 4_000, now: hoje(as: 0, 20)) == .cedoDemais)
        #expect(DashboardData.dailyDeltaState(
            todayTokens: 0, averageDailyTokens: 4_000, now: hoje(as: 15)) == .semUsoHoje)
    }

    @Test
    func semMediaNaoHaBase() {
        #expect(DashboardData.dailyDeltaState(
            todayTokens: 1_000, averageDailyTokens: 0, now: hoje(as: 15)) == .semBase)
    }

    @Test
    func estadoComparadoCarregaOValor() {
        #expect(DashboardData.dailyDeltaState(
            todayTokens: 3_000, averageDailyTokens: 4_000, now: hoje(as: 9)) == .comparado(1.0))
    }
}

/// EXB-5.7 §6 — tokens em primeiro plano: ordenações e a projeção mensal.
struct DashboardTokensFirstTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    private func model(_ name: String, _ date: Date, input: Int, output: Int, cost: Double) -> ModelCostEntry {
        ModelCostEntry(
            model: name, date: date, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, cost: cost)
    }

    /// A fixture separa os dois critérios: o modelo mais CARO é o de MENOS tokens. Uma ordenação por
    /// custo devolveria a ordem oposta, então o teste não pode passar por acidente.
    @Test
    func modelosOrdenamPorVolumeDeTokensNaoPorCusto() {
        let a = UsageAnalytics(
            byDayModel: [
                model("claude-opus-4", day(0), input: 50, output: 50, cost: 40.0),      // caro, pouco
                model("claude-sonnet-4", day(0), input: 5_000, output: 5_000, cost: 1.0), // barato, muito
            ],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.byModel.first?.model == "claude-sonnet-4")
        #expect(data.sortedModelNames == ["claude-sonnet-4", "claude-opus-4"])
        // E o custo continua lá, como número de apoio.
        #expect(data.byModel.first?.costUSD == 1.0)
    }

    /// Projetos também: o mais caro NÃO é o de mais tokens nesta fixture.
    @Test
    func projetosOrdenamPorVolumeDeTokens() {
        let a = UsageAnalytics(
            byDayModel: [model("claude-sonnet-4", day(0), input: 10, output: 10, cost: 1.0)],
            byProject: [
                ProjectUsageEntry(project: "caro", costUSD: 90.0, totalTokens: 100),
                ProjectUsageEntry(project: "volumoso", costUSD: 1.0, totalTokens: 900_000),
            ],
            heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.byProject.map(\.project) == ["volumoso", "caro"])
    }

    /// A projeção mensal em tokens vem de `monthToDateTokens`, não de uma regra de três sobre o custo.
    ///
    /// A fixture é construída para que os dois caminhos DISCORDEM: a razão tokens÷custo da janela é
    /// 20/$1 = 20, e a projeção de custo é $300, o que daria 6.000 tokens pelo caminho antigo. O
    /// caminho certo, medindo o mês, dá 3.000.
    @Test
    func projecaoDeTokensMedeOMesNaoDerivaDoCusto() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 10; comps.hour = 12 // 10 dias, mês de 30
        let agora = Calendar.current.date(from: comps)!

        let a = UsageAnalytics(
            byDayModel: [ModelCostEntry(
                model: "claude-sonnet-4",
                date: Calendar.current.startOfDay(for: agora),
                inputTokens: 10, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0, cost: 1.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
            monthToDateCost: 100.0, monthToDateTokens: 1_000)

        let data = DashboardData.build(from: a, period: .thirtyDays, now: agora)

        #expect(abs(data.monthProjection - 300.0) < 1e-6)  // (100 ÷ 10) × 30, inalterado
        #expect(data.projectedTokens == 3_000)             // (1.000 ÷ 10) × 30
        #expect(data.projectedTokens != 6_000)             // e NÃO a regra de três sobre o custo
    }

    /// Sem volume medido no mês, a projeção de tokens é zero — não se inventa uma a partir do custo.
    @Test
    func semVolumeMedidoAProjecaoDeTokensEZero() {
        let a = UsageAnalytics(
            byDayModel: [model("claude-sonnet-4", day(0), input: 1_000, output: 1_000, cost: 5.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
            monthToDateCost: 100.0, monthToDateTokens: 0)

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.projectedTokens == 0)
        #expect(data.monthProjection > 0)   // o custo ainda projeta; só o token não se inventa
    }

    /// EXB-5.8: a projeção do mês NÃO se move quando a faixa se move.
    ///
    /// Um defeito pré-existente acumulava `monthToDateTokens` DENTRO do filtro de janela: o campo
    /// dizia "mês corrente" e entregava "mês corrente ∩ período selecionado". A frente vizinha o
    /// corrigiu na fonte; este teste fixa o comportamento do MEU lado, que é o que o Senhor lê na
    /// tela: arrastar a linha do tempo não pode mexer numa projeção que é sobre o mês, não sobre a
    /// faixa. Sem esta asserção, uma regressão lá em baixo voltaria a aparecer aqui em silêncio.
    @Test
    func projecaoDoMesNaoSeMoveQuandoAFaixaSeMove() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 20; comps.hour = 12  // 20 dias, mês de 30
        let agora = Calendar.current.date(from: comps)!
        let cal = Calendar.current
        let hoje = cal.startOfDay(for: agora)

        let a = UsageAnalytics(
            byDayModel: (0...15).map { off in
                ModelCostEntry(
                    model: "claude-sonnet-4",
                    date: cal.date(byAdding: .day, value: -off, to: hoje)!,
                    inputTokens: 100, outputTokens: 0,
                    cacheReadTokens: 0, cacheWriteTokens: 0, cost: 1.0)
            },
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
            monthToDateCost: 200.0, monthToDateTokens: 2_000)

        let estreita = DashboardData.build(
            from: a, span: DashboardSpan(inicio: cal.date(byAdding: .day, value: -6, to: hoje)!, fim: hoje),
            now: agora)
        let larga = DashboardData.build(
            from: a, span: DashboardSpan(inicio: cal.date(byAdding: .day, value: -15, to: hoje)!, fim: hoje),
            now: agora)

        // As faixas medem coisas diferentes...
        #expect(estreita.dailyCosts.count == 7)
        #expect(larga.dailyCosts.count == 16)
        #expect(estreita.totalTokens != larga.totalTokens)
        // ...mas a projeção do mês é a mesma, porque é sobre o mês. (2.000 ÷ 20) × 30 = 3.000.
        #expect(estreita.projectedTokens == 3_000)
        #expect(larga.projectedTokens == 3_000)
        #expect(abs(estreita.monthProjection - larga.monthProjection) < 1e-9)
    }

    /// A média diária em tokens usa o MESMO divisor da média em dólar (§1) e a mesma medida de token
    /// de `todayTokens` — senão o badge compararia duas grandezas diferentes com precisão inútil.
    @Test
    func mediaDiariaDeTokensUsaODivisorDaCobertura() {
        let a = UsageAnalytics(
            byDayModel: [
                model("claude-sonnet-4", day(4), input: 500, output: 500, cost: 1.0),
                model("claude-sonnet-4", day(0), input: 500, output: 500, cost: 1.0),
            ],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: a, period: .thirtyDays, now: now)

        #expect(data.diasComDado == 5)
        #expect(data.thirtyDayTokens == 2_000)          // 2 dias × (500 in + 500 out)
        #expect(data.averageDailyTokens == 400)         // 2.000 ÷ 5 dias cobertos, não ÷ 2 nem ÷ 30
    }
}
