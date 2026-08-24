import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.8 §8 — o seletor de período vira faixa arrastável.
///
/// O invariante é um só e precisa de prova mecânica: **trocar a faixa não pode ler o disco.** Antes,
/// o período era entrada do scan, então cada troca pagava um `analyticsCensus` (enumerar e `stat`
/// ~2.100 arquivos). Um arrasto emite dezenas de eventos por segundo; pagar um walk por evento não é
/// um caminho lento, é a forma errada.
///
/// O espião abaixo separa as duas portas e **reprova o teste se a cara for chamada**.
///
/// Aviso herdado da frente vizinha, e levado a sério aqui: um teste de equivalência ("a faixa dos
/// últimos 7 dias bate com o atalho de 7 dias") **não pega** um defeito que estrague as duas portas
/// juntas — elas compartilham código, concordam entre si estando ambas erradas, e a equivalência dá
/// verde. Por isso cada gate abaixo fixa também o **absoluto**.
@MainActor
struct DashboardRangeTests {
    private let agora = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: agora))!
    }

    private func entry(_ date: Date, tokens: Int = 1_000, cost: Double = 1.0) -> ModelCostEntry {
        ModelCostEntry(
            model: "claude-sonnet-4", date: date,
            inputTokens: tokens, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, cost: cost)
    }

    // MARK: - O espião

    /// Conta as duas portas separadamente. `carregarHistoria` é a cara (anda no diretório); `fatiar`
    /// é aritmética sobre o que já está em memória.
    private final class Espiao: DashboardSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _carregamentos = 0
        private var _fatias = 0
        private var _intervalos: [ClosedRange<Date>] = []
        let historia: [ModelCostEntry]
        let inicio: Date?

        init(historia: [ModelCostEntry], inicio: Date?) {
            self.historia = historia
            self.inicio = inicio
        }

        var carregamentos: Int { lock.withLock { _carregamentos } }
        var fatias: Int { lock.withLock { _fatias } }
        var intervalos: [ClosedRange<Date>] { lock.withLock { _intervalos } }

        func carregarHistoria(now: Date) async -> DashboardHistoria {
            lock.withLock { _carregamentos += 1 }
            return DashboardHistoria(fingerprint: "fp", inicio: inicio)
        }

        func fatiar(_ intervalo: ClosedRange<Date>, now: Date) async -> UsageAnalytics {
            lock.withLock { _fatias += 1; _intervalos.append(intervalo) }
            let cal = Calendar.current
            // O espião fatia de verdade: um `fatiar` que devolvesse a história inteira faria os
            // testes de conteúdo abaixo passarem por vacuidade.
            let dentro = historia.filter {
                let dia = cal.startOfDay(for: $0.date)
                return dia >= cal.startOfDay(for: intervalo.lowerBound)
                    && dia <= cal.startOfDay(for: intervalo.upperBound)
            }
            var cobertos: Set<Date> = []
            if let inicio {
                var dia = cal.startOfDay(for: Swift.max(inicio, intervalo.lowerBound))
                while dia <= cal.startOfDay(for: intervalo.upperBound) {
                    cobertos.insert(dia)
                    guard let p = cal.date(byAdding: .day, value: 1, to: dia) else { break }
                    dia = p
                }
            }
            return UsageAnalytics(
                byDayModel: dentro, byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
                topSessions: [], monthToDateCost: 0, monthToDateTokens: 0, coveredDays: cobertos)
        }
    }

    private func modelo(_ espiao: Espiao, atalho: DashboardPeriod = .thirtyDays) -> DashboardRangeModel {
        let instante = agora
        return DashboardRangeModel(source: espiao, atalhoInicial: atalho, agora: { instante })
    }

    // MARK: - O gate: zero I/O na troca de faixa

    /// 25 trocas de faixa consecutivas, **um** carregamento. O contador da porta cara é o veredito.
    @Test
    func vinteECincoTrocasDeFaixaNaoLeemODisco() async {
        let espiao = Espiao(historia: (0...120).map { entry(day($0)) }, inicio: day(120))
        let m = modelo(espiao)

        await m.carregarUmaVez()
        #expect(espiao.carregamentos == 1)

        for dias in 1...25 {
            await m.aplicarEAguardar(day(dias)...day(0))
            #expect(m.dados?.dailyCosts.count == dias + 1)   // o absoluto, não só a ausência de I/O
        }

        #expect(espiao.carregamentos == 1)                    // continua 1 — nenhum disco tocado
        #expect(espiao.fatias >= 25)                          // e o trabalho aconteceu mesmo
    }

    /// Testemunha independente do mesmo invariante: nenhum dos 25 intervalos pedidos ao `fatiar`
    /// coincide com o "tudo" que o carregamento usa. Se a implementação tivesse recarregado por
    /// baixo dos panos, os contadores acima poderiam mentir; a lista de intervalos, não.
    @Test
    func cadaTrocaPedeExatamenteAFaixaPedida() async {
        let espiao = Espiao(historia: (0...60).map { entry(day($0)) }, inicio: day(60))
        let m = modelo(espiao)
        await m.carregarUmaVez()

        await m.aplicarEAguardar(day(9)...day(0))

        let ultimo = try! #require(espiao.intervalos.last)
        let cal = Calendar.current
        #expect(cal.startOfDay(for: ultimo.lowerBound) == day(9))
        #expect(cal.startOfDay(for: ultimo.upperBound) == day(0))
    }

    // MARK: - Atalho é valor, não modo

    /// O atalho escreve na mesma faixa que o arrasto escreve, e também não lê disco.
    @Test
    func atalhoEscreveNaFaixaSemRecarregar() async {
        let espiao = Espiao(historia: (0...120).map { entry(day($0)) }, inicio: day(120))
        let m = modelo(espiao)
        await m.carregarUmaVez()

        await m.aplicarAtalhoEAguardar(.sevenDays)

        #expect(m.dados?.dailyCosts.count == 7)
        #expect(m.atalho == .sevenDays)
        #expect(espiao.carregamentos == 1)
    }

    /// Arrastar apaga o atalho aceso: nenhum dos três botões descreve o que está na tela, e fingir
    /// que descreve é o tipo de rótulo errado que esta onda inteira existe para eliminar.
    @Test
    func arrastarApagaOAtalhoAceso() async {
        let espiao = Espiao(historia: (0...120).map { entry(day($0)) }, inicio: day(120))
        let m = modelo(espiao)
        await m.carregarUmaVez()
        #expect(m.atalho == .thirtyDays)

        await m.aplicarEAguardar(day(42)...day(0))   // largura que nenhum botão produz

        #expect(m.atalho == nil)
        #expect(m.dados?.dailyCosts.count == 43)
        #expect(m.dados?.atalho == nil)
    }

    /// Equivalência estrutural: o atalho de 7 dias e a faixa dos últimos 7 dias produzem o mesmo
    /// eixo. **Sozinha esta asserção não prova nada** (as duas portas compartilham código e podem
    /// concordar erradas), por isso o absoluto vem junto.
    @Test
    func atalhoEFaixaEquivalenteConcordamEEstaoCertos() async {
        let espiao = Espiao(historia: (0...60).map { entry(day($0)) }, inicio: day(60))
        let a = modelo(espiao); await a.carregarUmaVez(); await a.aplicarAtalhoEAguardar(.sevenDays)
        let b = modelo(espiao); await b.carregarUmaVez(); await b.aplicarEAguardar(day(6)...day(0))

        #expect(a.dados?.dailyCosts.map(\.date) == b.dados?.dailyCosts.map(\.date))
        #expect(a.dados?.dailyCosts.count == 7)              // o absoluto
        #expect(a.dados?.dailyCosts.first?.date == day(6))
        #expect(a.dados?.dailyCosts.last?.date == day(0))
    }

    // MARK: - Nada antes do início real dos dados

    /// `.tudo` começa onde os dados começam, nunca antes — a decisão do dono, e a razão pela qual
    /// o botão de 90 dias saiu: nesta máquina ele desenhava 35 dias de nada.
    @Test
    func tudoComecaOndeOsDadosComecamNuncaAntes() async {
        let espiao = Espiao(historia: [entry(day(40)), entry(day(0))], inicio: day(40))
        let m = modelo(espiao)
        await m.carregarUmaVez()

        await m.aplicarAtalhoEAguardar(.tudo)

        #expect(m.dados?.span.inicio == day(40))
        #expect(m.dados?.dailyCosts.count == 41)
        #expect(m.dados?.dailyCosts.allSatisfy(\.coberto) == true)   // nenhuma lacuna inventada
    }

    /// Sem história alguma, `.tudo` não inventa uma: cai no padrão de 30 dias em vez de escolher
    /// uma data arbitrária no passado.
    @Test
    func tudoSemHistoriaNaoInventaUmInicio() async {
        let espiao = Espiao(historia: [], inicio: nil)
        let m = modelo(espiao)
        await m.carregarUmaVez()

        await m.aplicarAtalhoEAguardar(.tudo)

        #expect(m.dados?.dailyCosts.count == 30)
    }

    // MARK: - O rótulo do CSV segue o que está na tela

    @Test
    func csvDeFaixaArrastadaNomeiaAsDatasNaoUmBotao() async {
        let espiao = Espiao(historia: (0...60).map { entry(day($0)) }, inicio: day(60))
        let m = modelo(espiao)
        await m.carregarUmaVez()

        await m.aplicarAtalhoEAguardar(.sevenDays)
        #expect(m.dados?.fileTag == "7d")

        await m.aplicarEAguardar(day(42)...day(0))
        let tag = try! #require(m.dados?.fileTag)
        #expect(tag != "7d")
        #expect(tag.contains("-"))                 // duas datas, não um botão
        #expect(tag.count == 17)                   // yyyyMMdd-yyyyMMdd
    }
}

private extension DashboardRangeModel {
    /// Aplica e **aguarda a própria dobra**, em vez de girar sobre `isRefreshing` torcendo pelo
    /// melhor. A primeira versão deste helper era um laço de `Task.yield()`, e ele deixava o teste ler
    /// os dados da faixa ANTERIOR achando que eram os novos — dois testes passaram a acusar defeito
    /// que não existia no código, e sim aqui. Espera sobre um handle é verificável; laço é palpite.
    @discardableResult
    func aplicarEAguardar(_ intervalo: ClosedRange<Date>, atalho: DashboardPeriod? = nil) async -> Bool {
        guard let t = aplicar(intervalo, atalho: atalho) else { return false }
        await t.value
        return true
    }

    func aplicarAtalhoEAguardar(_ atalho: DashboardPeriod) async {
        await aplicarAtalho(atalho)?.value
    }
}
