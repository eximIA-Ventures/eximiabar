import ClaudeBarCore
import Foundation
import SwiftUI
import Testing
@testable import ClaudeBar

// MARK: - Shared fixtures

/// A calendar pinned so nothing below depends on the host's region, and dates built from components
/// so nothing depends on its time zone either — the suite runs under three zones, and a fixture
/// anchored to an epoch instant drifts a day west of Greenwich.
///
/// Deliberately *not* shared with `DashboardRepresentacoesTests`' own `Fixo`: that one is `private`
/// to its file, and reaching for it would mean widening a test double's visibility across suites so
/// two independent wavefronts could edit it. The production code is the thing that must have one
/// definition of everything; a four-line date helper in a test file is not.
private enum Base {
    static var calendario: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1
        return cal
    }

    static func dia(_ ano: Int, _ mes: Int, _ dia: Int) -> Date {
        calendario.date(from: DateComponents(year: ano, month: mes, day: dia))!
    }

    static func mes(_ ano: Int, _ mes: Int) -> Date {
        calendario.date(from: DateComponents(year: ano, month: mes, day: 1))!
    }

    static func sessao(_ id: String, tokens: Int, custo: Double = 0, projeto: String = "p") -> SessionUsageEntry {
        SessionUsageEntry(
            sessionId: id, date: dia(2026, 8, 1), project: projeto,
            dominantModel: "claude-sonnet-4", totalTokens: tokens, costUSD: custo)
    }

    /// Bucket counts computed by the **fold's own** binning, so a fixture can describe a world in
    /// sessions and let the histogram see the same buckets the scanner would have produced.
    static func baldes(_ sessoes: [SessionUsageEntry]) -> [Int] {
        var contagem = [Int](repeating: 0, count: UsageAnalytics.sessionTokenBucketCount)
        for sessao in sessoes {
            contagem[UsageAnalytics.sessionTokenBucketIndex(forTokens: sessao.totalTokens)] += 1
        }
        return contagem
    }

    static func mediana(_ sessoes: [SessionUsageEntry]) -> Int {
        let ordenados = sessoes.map(\.totalTokens).sorted()
        guard !ordenados.isEmpty else { return 0 }
        let meio = ordenados.count / 2
        return ordenados.count.isMultiple(of: 2)
            ? (ordenados[meio - 1] + ordenados[meio]) / 2
            : ordenados[meio]
    }

    static func histograma(_ sessoes: [SessionUsageEntry], cortarEm limite: Int? = nil) -> HistogramaDeSessoes {
        let porCusto = sessoes.sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.totalTokens > $1.totalTokens }
        let carregadas = limite.map { Array(porCusto.prefix($0)) } ?? porCusto
        return HistogramaDeSessoes(
            buckets: baldes(sessoes),
            mediana: mediana(sessoes),
            total: sessoes.count,
            topo: Array(porCusto.prefix(10)),
            sessoes: carregadas,
            truncado: carregadas.count < sessoes.count)
    }

    static func linha(
        _ dia: Date, _ projeto: String, _ tokens: Int, agregado: Bool = false) -> DayProjectEntry
    {
        DayProjectEntry(
            day: dia, project: agregado ? "" : projeto, totalTokens: tokens,
            costUSD: Double(tokens) / 1_000_000, isOthers: agregado)
    }

    static func cobertura(
        _ mesInicial: Date, noMes: Int, naSelecao: Int? = nil, cobertos: Int? = nil) -> MonthCoverage
    {
        MonthCoverage(
            month: mesInicial, daysInMonth: noMes,
            daysInRange: naSelecao ?? noMes, daysCovered: cobertos ?? naSelecao ?? noMes)
    }
}

// MARK: - V1 · Session size distribution

/// EXB-6.1 V1 — "does my spend live in a few monstrous sessions or in the habit of every day?"
///
/// The suite is built on the property that makes the chart worth its space: the **same ten sessions**
/// have to produce **opposite readings** in the two worlds that call for opposite actions. A fixture
/// with one shape could not tell a working derivation from a constant, which is the failure mode a
/// single-sample test is blind to by construction.
struct HistogramaDeSessoesTests {
    /// Ten monsters and a handful of ordinary sessions — attack the sessions.
    private func mundoDosMonstros() -> [SessionUsageEntry] {
        (0 ..< 10).map { Base.sessao("monstro-\($0)", tokens: 40_000_000, custo: 100 - Double($0)) }
            + (0 ..< 12).map { Base.sessao("normal-\($0)", tokens: 300_000, custo: 1) }
    }

    /// The **same ten monsters**, now beside two hundred ordinary sessions — the habit is the spend.
    private func mundoDoHabito() -> [SessionUsageEntry] {
        (0 ..< 10).map { Base.sessao("monstro-\($0)", tokens: 40_000_000, custo: 100 - Double($0)) }
            + (0 ..< 200).map { Base.sessao("normal-\($0)", tokens: 3_000_000, custo: 1) }
    }

    /// **The gate.** Identical top-ten, opposite conclusions. This is the whole reason the histogram
    /// exists: the ranked table on the screen shows the same ten names in both worlds and cannot
    /// distinguish them, because the evidence for the distinction is exactly the rows it drops.
    @Test
    func theSameTenSessionsReadOppositelyInTheTwoWorlds() {
        let monstros = Base.histograma(mundoDosMonstros())
        let habito = Base.histograma(mundoDoHabito())

        // The top ten really are the same list — otherwise the comparison below proves nothing.
        #expect(monstros.marcas.map(\.sessionId) == habito.marcas.map(\.sessionId))

        let concentrada = try! #require(monstros.concentracaoDoTopo)
        let difusa = try! #require(habito.concentracaoDoTopo)
        #expect(concentrada > 0.98)      // 400M of 403,6M
        #expect(difusa < 0.45)           // 400M of 1 000M
        #expect(concentrada > difusa + 0.5)

        // And the sample size, which is the other half of the distinction.
        #expect(monstros.totalDeSessoes == 22)
        #expect(habito.totalDeSessoes == 210)
        #expect(monstros.mediana != habito.mediana)
    }

    /// Marks are placed by ``UsageAnalytics/sessionTokenBucketIndex(forTokens:)``, the fold's own
    /// binning — never a second `floor(2·log₁₀ n)` written at the drawing end, which would agree today
    /// and drift the first time either side moved, with the picture still looking fine.
    @Test
    func everyMarkSitsOnTheBucketTheFoldWouldHaveCountedItIn() {
        let sessoes = [
            Base.sessao("a", tokens: 1, custo: 9),
            Base.sessao("b", tokens: 999, custo: 8),
            Base.sessao("c", tokens: 1_000, custo: 7),
            Base.sessao("d", tokens: 40_000_000, custo: 6),
        ]
        let histograma = Base.histograma(sessoes)

        for marca in histograma.marcas {
            #expect(marca.faixa == UsageAnalytics.sessionTokenBucketIndex(forTokens: marca.tokens))
            // The bar under the mark counts it: the mark's bucket is non-empty.
            #expect(histograma.faixas[marca.faixa].sessoes > 0)
        }
        // Absolutes, so the assertion above cannot pass by both sides being wrong together.
        #expect(histograma.marcas.first { $0.sessionId == "a" }?.faixa == 0)
        #expect(histograma.marcas.first { $0.sessionId == "c" }?.faixa == 6)  // floor(2·log₁₀1000)
    }

    /// The 20 bands and their edges do **not** move with the data. Two windows whose sessions live in
    /// completely different size ranges get the same axis, which is what makes them comparable — and
    /// what a "trim the empty tails" optimization would silently destroy.
    @Test
    func theAxisIsFixedAcrossTwoWindowsThatShareNoBucket() {
        let pequenas = Base.histograma((0 ..< 5).map { Base.sessao("p\($0)", tokens: 200) })
        let enormes = Base.histograma((0 ..< 5).map { Base.sessao("g\($0)", tokens: 900_000_000) })

        #expect(pequenas.faixas.count == UsageAnalytics.sessionTokenBucketCount)
        #expect(pequenas.faixas.map(\.minimo) == enormes.faixas.map(\.minimo))
        #expect(pequenas.faixas.map(\.maximo) == enormes.faixas.map(\.maximo))
        #expect(pequenas.faixas.map(\.minimo) == Array(UsageAnalytics.sessionTokenBucketEdges.dropLast()))
        // The counts differ, of course — the axis is what is being held still, not the bars.
        #expect(pequenas.faixas.map(\.sessoes) != enormes.faixas.map(\.sessoes))
        // And they really do share no occupied bucket.
        let ocupadasP = Set(pequenas.faixas.filter { $0.sessoes > 0 }.map(\.indice))
        let ocupadasG = Set(enormes.faixas.filter { $0.sessoes > 0 }.map(\.indice))
        #expect(ocupadasP.isDisjoint(with: ocupadasG))
    }

    /// A cut session list produces **no** share rather than a plausible one. The numerator would be
    /// the ten dearest and the denominator whatever survived the cut, which is a number that always
    /// looks reasonable and is never right.
    @Test
    func aTruncatedSessionListSuppressesTheShareInsteadOfFabricatingIt() {
        let inteiro = Base.histograma(mundoDoHabito())
        let cortado = Base.histograma(mundoDoHabito(), cortarEm: 30)

        #expect(inteiro.concentracaoDoTopo != nil)
        #expect(cortado.concentracaoDoTopo == nil)
        // Everything else survives the cut: the bars are counted over all sessions, not over the
        // carried ones, so the shape does not change with a payload decision.
        #expect(cortado.faixas.map(\.sessoes) == inteiro.faixas.map(\.sessoes))
        #expect(cortado.totalDeSessoes == inteiro.totalDeSessoes)
    }

    /// The median is **taken** from the fold, not read off the buckets — those are √10 apart, so a
    /// median inferred from them could be out by 3×.
    @Test
    func theMedianIsCarriedVerbatimAndBinnedWithTheSameRule() {
        let histograma = HistogramaDeSessoes(
            buckets: [Int](repeating: 3, count: 20), mediana: 7_321_004, total: 60, topo: [])

        #expect(histograma.mediana == 7_321_004)
        #expect(histograma.faixaDaMediana == UsageAnalytics.sessionTokenBucketIndex(forTokens: 7_321_004))
        #expect(histograma.faixaDaMediana == 13)
        // A bucket midpoint would be 10^6.5 ≈ 3,16M — a factor of 2,3 away from the real median.
        #expect(histograma.mediana != Int(pow(10.0, 6.5)))
    }

    /// The array's half of the contract: a band can be **named**. Binned by the fold's own function,
    /// so a hover can never list a session the bar underneath does not count.
    @Test
    func aBandCanNameTheSessionsTheBarCounts() {
        let histograma = Base.histograma(mundoDosMonstros())
        let faixaDosMonstros = UsageAnalytics.sessionTokenBucketIndex(forTokens: 40_000_000)

        let nomeados = histograma.nomes(naFaixa: faixaDosMonstros)
        #expect(nomeados.count == histograma.faixas[faixaDosMonstros].sessoes)
        #expect(nomeados.count == 10)
        #expect(nomeados.allSatisfy { $0.sessionId.hasPrefix("monstro-") })
        // Ordered by size, and carrying what makes a dot actionable rather than a coordinate.
        #expect(nomeados.map(\.totalTokens) == nomeados.map(\.totalTokens).sorted(by: >))
        #expect(nomeados.first?.project == "p")
        #expect(nomeados.first?.dominantModel == "claude-sonnet-4")
        // Every band's names add up to the sample, so no session is named in two places or in none.
        let todosOsNomes = (0 ..< UsageAnalytics.sessionTokenBucketCount)
            .flatMap { histograma.nomes(naFaixa: $0) }
        #expect(todosOsNomes.count == histograma.totalDeSessoes)
        #expect(Set(todosOsNomes.map(\.sessionId)).count == histograma.totalDeSessoes)
        // The marks carry the same identity, so the dot and the tooltip agree.
        #expect(histograma.marcas.allSatisfy { !$0.modeloDominante.isEmpty })
    }

    /// **The invariant the Core fixed, on the reading side.** The bars count every session; the names
    /// come from the carried list. When that list was cut, the tooltip has to say it is showing a
    /// subset — otherwise it silently redefines the bar it is standing on.
    @Test
    func aCutListStillCountsEveryBarAndAdmitsTheNamesAreASubset() {
        let inteiro = Base.histograma(mundoDoHabito())
        let cortado = Base.histograma(mundoDoHabito(), cortarEm: 30)

        #expect(inteiro.nomesIncompletos == false)
        #expect(cortado.nomesIncompletos)
        // The shape is identical — a cap is a payload decision, never a claim about the distribution.
        #expect(cortado.faixas.map(\.sessoes) == inteiro.faixas.map(\.sessoes))
        #expect(cortado.totalDeSessoes == inteiro.totalDeSessoes)
        // And the names really are fewer than the bar they sit under, which is why it must be said.
        let faixaDosMonstros = UsageAnalytics.sessionTokenBucketIndex(forTokens: 40_000_000)
        let faixaComum = UsageAnalytics.sessionTokenBucketIndex(forTokens: 3_000_000)
        #expect(cortado.nomes(naFaixa: faixaDosMonstros).count == 10)   // as dez mais caras sobrevivem
        #expect(cortado.nomes(naFaixa: faixaComum).count < cortado.faixas[faixaComum].sessoes)
    }

    /// One session draws a bar and a rule through it: an ornament implying a comparison it cannot
    /// make. The card says the count in words instead.
    @Test
    func aWindowWithFewerThanTwoSessionsDoesNotDraw() {
        #expect(Base.histograma([]).vaiDesenhar == false)
        #expect(Base.histograma([Base.sessao("única", tokens: 5_000)]).vaiDesenhar == false)
        #expect(Base.histograma((0 ..< 2).map { Base.sessao("s\($0)", tokens: 5_000) }).vaiDesenhar)
    }
}

// MARK: - V2 · Month-over-month waterfall

/// EXB-6.1 V2 — "who made the month change?", and the guard without which the answer is always
/// "everyone slowed down".
struct CascataMensalTests {
    private let outros = "Outros"

    /// A month of daily rows at a constant per-day rate for each project.
    private func mes(_ ano: Int, _ mes: Int, dias: Range<Int>, taxas: [String: Int]) -> [DayProjectEntry] {
        dias.flatMap { dia in
            taxas.map { projeto, tokens in Base.linha(Base.dia(ano, mes, dia), projeto, tokens) }
        }
    }

    /// **The gate this chart is built around.** July is whole (31 days), August is the 25th of a
    /// 31-day month, and every project ran at *exactly the same daily rate* in both. An unguarded
    /// comparison of month totals reports −19,4 % for every single project — every bar down, the chart
    /// in perfect agreement with itself, and the conclusion false by construction.
    @Test
    func anIncompleteMonthAgainstAWholeOneReportsNoChangeWhenTheRateDidNotChange() {
        let taxas = ["alfa": 10_000_000, "beta": 4_000_000, "gama": 1_000_000]
        let linhas = mes(2026, 7, dias: 1 ..< 32, taxas: taxas) + mes(2026, 8, dias: 1 ..< 26, taxas: taxas)
        let cascata = CascataMensal(
            porDiaProjeto: linhas,
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        #expect(cascata.vaiDesenhar)
        #expect(abs(cascata.variacaoTotal) < 1)
        for passo in cascata.passos where passo.tipo == .contribuicao {
            #expect(abs(passo.variacao) < 1, "\(passo.rotulo) moveu \(passo.variacao)")
        }
        // The absolute totals really are 19,4 % apart — the fixture does contain the trap.
        let julho = try! #require(cascata.anterior)
        let agosto = try! #require(cascata.atual)
        #expect(julho.tokens == 15_000_000 * 31)
        #expect(agosto.tokens == 15_000_000 * 25)
        #expect(Double(agosto.tokens) / Double(julho.tokens) < 0.81)
        // …and the per-day rates are identical, which is the reading the chart publishes.
        #expect(abs(julho.porDia - agosto.porDia) < 1)
    }

    /// The other direction, over the **same** incomplete-month geometry: a project that really did
    /// halve its daily rate produces a negative bar, and one that doubled produces a positive one. A
    /// derivation that always answered "zero" would pass the test above perfectly.
    @Test
    func realRateChangesStillMoveTheirBarsUnderTheSameGeometry() {
        let julho = mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 10_000_000, "beta": 4_000_000])
        let agosto = mes(2026, 8, dias: 1 ..< 26, taxas: ["alfa": 5_000_000, "beta": 8_000_000])
        let cascata = CascataMensal(
            porDiaProjeto: julho + agosto,
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        let contribuicoes = cascata.passos.filter { $0.tipo == .contribuicao }
        let alfa = try! #require(contribuicoes.first { $0.rotulo == "alfa" })
        let beta = try! #require(contribuicoes.first { $0.rotulo == "beta" })
        #expect(abs(alfa.variacao - -5_000_000) < 1)
        #expect(abs(beta.variacao - 4_000_000) < 1)
        // Positives before negatives, and the larger magnitude first inside each group.
        #expect(contribuicoes.map(\.rotulo) == ["beta", "alfa"])
        #expect(abs(cascata.variacaoTotal - -1_000_000) < 1)
    }

    /// The waterfall closes, **and every bar is right on its own**.
    ///
    /// The closure alone is worth less than it looks, and the mutation run said so: rewriting "others"
    /// as `total − Σ bars` came back **STILL GREEN**. It is an equivalent mutant — the month totals and
    /// the per-project movements are two folds of the same rows, so remainder and sum are the same
    /// number on every possible input, and no fixture can separate them. A test that stopped at the
    /// closure would have been an equivalence check between two paths that share their source: it
    /// proves agreement, never correctness.
    ///
    /// So each bar below is asserted against a figure computed **by hand from the fixture**: five
    /// movers at +900k/day, nine at −300k/day, the archive aggregate going 2M → 5M/day. That is what
    /// the mutation cannot survive, and it is why the numbers are spelled out instead of being derived
    /// from the very thing under test.
    @Test
    func theBarsAddUpToTheMonthTheyClaimToExplain() {
        var julho: [String: Int] = [:]
        var agosto: [String: Int] = [:]
        for indice in 0 ..< 14 {
            julho["p\(indice)"] = 1_000_000 * (indice + 1)
            agosto["p\(indice)"] = 1_000_000 * (indice + 1) + (indice % 3 == 0 ? 900_000 : -300_000)
        }
        let linhas = mes(2026, 7, dias: 1 ..< 32, taxas: julho)
            + mes(2026, 8, dias: 1 ..< 26, taxas: agosto)
            // Plus the archive's own aggregate rows, which are a sum of real projects and must land
            // in the "others" bar rather than being dropped.
            + (1 ..< 32).map { Base.linha(Base.dia(2026, 7, $0), "", 2_000_000, agregado: true) }
            + (1 ..< 26).map { Base.linha(Base.dia(2026, 8, $0), "", 5_000_000, agregado: true) }
        let cascata = CascataMensal(
            porDiaProjeto: linhas,
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        let base = try! #require(cascata.passos.first { $0.tipo == .base })
        let total = try! #require(cascata.passos.first { $0.tipo == .total })
        let movimentos = cascata.passos.filter { $0.tipo == .contribuicao || $0.tipo == .outros }
        let fecho = base.fim + movimentos.reduce(0) { $0 + $1.variacao }
        #expect(abs(fecho - total.fim) < 1)

        // The bars, one by one, against hand-computed values — the part a remainder cannot fake.
        // July: 1M…14M per project per day (105M) plus 2M aggregate → 107M/day.
        // August: the same, +900k on p0/p3/p6/p9/p12 and −300k on the other nine, aggregate 5M
        //         → 105M + 1,8M + 5M = 111,8M/day.
        #expect(abs(base.fim - 107_000_000) < 1)
        #expect(abs(total.fim - 111_800_000) < 1)
        let contribuicoes = cascata.passos.filter { $0.tipo == .contribuicao }
        #expect(contribuicoes.filter { abs($0.variacao - 900_000) < 1 }.count == 5)
        #expect(contribuicoes.filter { abs($0.variacao - -300_000) < 1 }.count == 1)
        // …and the five positives really do come before the single negative that made the cut.
        #expect(contribuicoes.map { $0.variacao > 0 } == [true, true, true, true, true, false])
        // The last mover's end really is the total's height — the bars are a chain, not a set.
        #expect(abs((movimentos.last?.fim ?? base.fim) - total.fim) < 1)
        // The cap holds, and the aggregate is declared.
        #expect(cascata.passos.filter { $0.tipo == .contribuicao }.count == CascataMensal.maximoDeMovimentadores)
        #expect(cascata.movimentadoresEmOutros == 8)
        #expect(cascata.incluiAgregadoDoArquivo)
        // "Others" is the tail **plus** the archive aggregate, each computed and added: the eight
        // movers past the cut are −300k/day apiece (−2,4M) and the aggregate went 2M → 5M (+3M), so
        // the bar is +600k. A remainder would land on the same number and would land on it for any
        // arithmetic above it, right or wrong — which is why the decomposition is asserted and not
        // just the closure.
        let outrosPasso = try! #require(cascata.passos.first { $0.tipo == .outros })
        #expect(abs(outrosPasso.variacao - 600_000) < 1)
    }

    /// `daysInRange` and `daysCovered` are **not** collapsed. Both shrink the divisor; only the second
    /// is a claim about missing history, and a cascade that blamed the archive for the Senhor's own
    /// drag would be reporting a defect that does not exist.
    @Test
    func theTwoReasonsForASmallerDivisorAreKeptApart() {
        #expect(RecorteDoMes(Base.cobertura(Base.mes(2026, 7), noMes: 31)) == .completo)
        #expect(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25))
            == .selecao(dias: 25, noMes: 31))
        #expect(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 31, cobertos: 20))
            == .historico(dias: 20, naSelecao: 31))
        #expect(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25, cobertos: 18))
            == .ambos(cobertos: 18, naSelecao: 25, noMes: 31))
        // And the three cases produce three different sentences on screen.
        let frases = [
            MonthlyCascadeChart.texto(RecorteDoMes(Base.cobertura(Base.mes(2026, 7), noMes: 31))),
            MonthlyCascadeChart.texto(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25))),
            MonthlyCascadeChart.texto(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 31, cobertos: 20))),
        ]
        #expect(Set(frases).count == 3)
    }

    /// **The two silences of a month, and only one of them is comparable.** A month the archive
    /// watched from end to end on which nothing ran is a *fact*: full coverage, zero tokens, and the
    /// comparison is drawn — every project of the previous month shows as a fall, correctly, because
    /// it really did stop. A month the archive never watched is **absent** from `monthCoverage`, and
    /// there the cascade has no pair and refuses. Painting the second as a zero would be asserting
    /// "nothing happened" about a stretch nobody observed.
    @Test
    func aWatchedEmptyMonthIsComparedAndAnUnwatchedOneIsRefused() {
        let vigiadoEVazio = CascataMensal(
            porDiaProjeto: mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 10_000_000]),
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                // Agosto inteiro dentro da seleção e inteiramente observado — e sem uma linha sequer.
                Base.cobertura(Base.mes(2026, 8), noMes: 31),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        #expect(vigiadoEVazio.recusa == nil)
        #expect(vigiadoEVazio.vaiDesenhar)
        #expect(vigiadoEVazio.atual?.tokens == 0)
        #expect(vigiadoEVazio.atual?.porDia == 0)
        #expect(RecorteDoMes(Base.cobertura(Base.mes(2026, 8), noMes: 31)) == .completo)
        // A queda é real e do tamanho certo: alfa perdeu os 10M/dia inteiros.
        let alfa = try! #require(vigiadoEVazio.passos.first { $0.rotulo == "alfa" })
        #expect(abs(alfa.variacao - -10_000_000) < 1)
        #expect(abs(vigiadoEVazio.variacaoTotal - -10_000_000) < 1)

        // O mesmo agosto, agora ausente do `monthCoverage` porque o acervo não o assistiu: sem par.
        let naoVigiado = CascataMensal(
            porDiaProjeto: mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 10_000_000]),
            cobertura: [Base.cobertura(Base.mes(2026, 7), noMes: 31)],
            rotuloDeOutros: outros,
            calendar: Base.calendario)
        #expect(naoVigiado.recusa == .parInsuficiente)
        #expect(naoVigiado.passos.isEmpty)
    }

    /// "Whole month" has **one** definition, and it is `MonthCoverage.isComplete`.
    ///
    /// **The grid alone does not prove that, and the mutation said so.** Re-deriving completeness as
    /// `daysInRange == daysInMonth && daysCovered == daysInRange` is arithmetically identical to
    /// `isComplete` for every **well-formed** row, so mutating the guard back to the reconstruction
    /// came back STILL GREEN over the whole grid below. The two only separate where the row is
    /// malformed — and that is precisely the case this guard exists for, since a malformed row is what
    /// a future change to the Core's own bookkeeping would look like from here.
    @Test
    func completenessIsTheContractsOwnDefinitionNotASecondOne() {
        for noMes in [28, 30, 31] {
            for naSelecao in 0 ... noMes {
                for cobertos in 0 ... naSelecao {
                    let cobertura = Base.cobertura(
                        Base.mes(2026, 8), noMes: noMes, naSelecao: naSelecao, cobertos: cobertos)
                    #expect((RecorteDoMes(cobertura) == .completo) == cobertura.isComplete,
                            "noMes \(noMes) naSelecao \(naSelecao) cobertos \(cobertos)")
                }
            }
        }

        // The row that separates the two definitions: the archive vouches for all 31 days while the
        // selection recorded only 25 — `daysCovered > daysInRange`, which the fold should never emit
        // and which is exactly the shape a drift in its bookkeeping would take. `isComplete` says the
        // month is whole; the reconstruction says the selection clipped it. The contract wins.
        let torta = MonthCoverage(
            month: Base.mes(2026, 8), daysInMonth: 31, daysInRange: 25, daysCovered: 31)
        #expect(torta.isComplete)
        #expect(RecorteDoMes(torta) == .completo)
        #expect(RecorteDoMes(torta) != .selecao(dias: 25, noMes: 31))
    }

    /// Below the floor the chart refuses and **says why**. A rate over two days is one day wearing the
    /// word "average", and a bar drawn from it reads as a change in behaviour.
    @Test
    func theCascadeRefusesRatherThanDrawingFromTwoDays() {
        let linhas = mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 10_000_000])
            + mes(2026, 8, dias: 1 ..< 3, taxas: ["alfa": 10_000_000])
        let cascata = CascataMensal(
            porDiaProjeto: linhas,
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 2),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        #expect(cascata.recusa == .coberturaFina(mes: Base.mes(2026, 8), dias: 2))
        #expect(cascata.passos.isEmpty)
        #expect(cascata.vaiDesenhar == false)
        // The months are still published, so the refusal message can name the thin one.
        #expect(cascata.atual?.diasComDado == 2)
        // One day above the floor and the same shape draws — the refusal is a threshold, not a wall.
        let comTres = CascataMensal(
            porDiaProjeto: mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 10_000_000])
                + mes(2026, 8, dias: 1 ..< 4, taxas: ["alfa": 10_000_000]),
            cobertura: [
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
                Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 3),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)
        #expect(comTres.recusa == nil)
        #expect(comTres.vaiDesenhar)
    }

    /// One month is not a pair. The chart says so instead of comparing a month with itself.
    @Test
    func aSingleMonthProducesARefusalNotAnEmptyChart() {
        let cascata = CascataMensal(
            porDiaProjeto: mes(2026, 8, dias: 1 ..< 26, taxas: ["alfa": 10_000_000]),
            cobertura: [Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 25)],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        #expect(cascata.recusa == .parInsuficiente)
        #expect(cascata.passos.isEmpty)
        #expect(cascata.anterior == nil)
    }

    /// The pair is the last two months **the archive can speak about**, not the last two on the
    /// calendar: a month absent from `monthCoverage` was never watched inside this selection, and
    /// reaching past it would compare across a hole.
    @Test
    func thePairIsTheLastTwoCoveredMonthsNotTheLastTwoCalendarMonths() {
        let linhas = mes(2026, 5, dias: 1 ..< 32, taxas: ["alfa": 1_000_000])
            + mes(2026, 7, dias: 1 ..< 32, taxas: ["alfa": 2_000_000])
        let cascata = CascataMensal(
            porDiaProjeto: linhas,
            cobertura: [
                Base.cobertura(Base.mes(2026, 5), noMes: 31),
                Base.cobertura(Base.mes(2026, 7), noMes: 31),
            ],
            rotuloDeOutros: outros,
            calendar: Base.calendario)

        #expect(cascata.anterior?.mes == Base.mes(2026, 5))
        #expect(cascata.atual?.mes == Base.mes(2026, 7))
        #expect(abs(cascata.variacaoTotal - 1_000_000) < 1)
    }
}

// MARK: - V3 · Project composition flow

/// EXB-6.1 V3 — "which project **rose**", which is not "which project is big".
struct FluxoDeProjetosTests {
    private let outros = "Outros"
    private let rankeados = ["alfa", "beta", "gama"]

    private func fluxo(_ linhas: [DayProjectEntry], agregados: Int = 0, eixo: [Date] = []) -> FluxoDeProjetos {
        FluxoDeProjetos(
            porDiaProjeto: linhas, rankeados: rankeados,
            projetosAgregados: agregados, rotuloDoAgregado: outros, eixo: eixo)
    }

    /// **The gate.** The colour a band gets is its position in the archive-wide ranking, and it does
    /// not move when the slice drops the band above it. Recomputing a top-N over the slice is what
    /// makes the same colour a different project halfway through a drag — the band appears to grow
    /// when it has merely changed owner, which is a lie told in the exact channel the chart uses to
    /// answer its question.
    @Test
    func aBandKeepsItsGlobalRankWhenTheSliceDropsTheBandAboveIt() {
        let comAlfa = fluxo([
            Base.linha(Base.dia(2026, 8, 1), "alfa", 900),
            Base.linha(Base.dia(2026, 8, 1), "beta", 300),
            Base.linha(Base.dia(2026, 8, 2), "alfa", 800),
            Base.linha(Base.dia(2026, 8, 2), "beta", 400),
        ])
        // The same window, dragged so that "alfa" has no volume in it at all.
        let semAlfa = fluxo([
            Base.linha(Base.dia(2026, 8, 3), "beta", 300),
            Base.linha(Base.dia(2026, 8, 4), "beta", 400),
        ])

        let betaCom = try! #require(comAlfa.bandas.first { $0.nome == "beta" })
        let betaSem = try! #require(semAlfa.bandas.first { $0.nome == "beta" })
        #expect(betaCom.ordemGlobal == 1)
        #expect(betaSem.ordemGlobal == 1)        // NOT 0 — the array shortened, the rank did not
        #expect(semAlfa.bandas.count == 1)       // the array really did shorten
        #expect(comAlfa.bandas.count == 2)
        // And the ranking's own order is preserved, never re-sorted by the slice's volumes.
        #expect(comAlfa.bandas.map(\.nome) == ["alfa", "beta"])
    }

    /// Every day's bands add up to that day's real total, aggregate included. The aggregate is a
    /// **sum**, so the stack height is comparable with every other total on the panel; discarding the
    /// tail instead would make this chart quietly smaller than the rest of the screen.
    @Test
    func theBandsOfADayAddUpToTheDaysRealTotal() {
        let dia = Base.dia(2026, 8, 1)
        let linhas = [
            Base.linha(dia, "alfa", 500),
            Base.linha(dia, "beta", 300),
            Base.linha(dia, "", 220, agregado: true),
            // A project outside the ranking: the fold should never emit one, and if it does the row
            // is summed into the aggregate rather than dropped.
            Base.linha(dia, "forasteiro", 80),
        ]
        let f = fluxo(linhas, agregados: 4)

        #expect(f.total(em: dia) == 1_100)
        let agregado = try! #require(f.pontos.first { $0.banda == outros && $0.dia == dia })
        #expect(agregado.tokens == 300)          // 220 + 80, summed rather than discarded
        #expect(f.truncado)
        #expect(f.projetosAgregados == 4)
    }

    /// The distortion this chart cannot design away, and the mitigation that answers it: a band that
    /// did not move reads as **zero** change in the tooltip even while the band beneath it doubles and
    /// visibly lifts it up the plot.
    @Test
    func aFlatBandReportsZeroChangeEvenWhenTheBandBelowItDoubles() {
        let d1 = Base.dia(2026, 8, 1), d2 = Base.dia(2026, 8, 2)
        let f = fluxo([
            Base.linha(d1, "alfa", 1_000), Base.linha(d1, "beta", 500),
            Base.linha(d2, "alfa", 2_000), Base.linha(d2, "beta", 500),
        ])

        let linhasDoDia2 = f.linhas(em: d2)
        let beta = try! #require(linhasDoDia2.first { $0.banda == "beta" })
        let alfa = try! #require(linhasDoDia2.first { $0.banda == "alfa" })
        #expect(beta.variacao == 0)              // flat, and said to be flat
        #expect(alfa.variacao == 1_000)
        #expect(beta.tokens == 500)
        // On the first day of the axis there is no previous day, and the tooltip says so rather than
        // reporting a change of zero — which would assert a stability nobody measured.
        #expect(f.linhas(em: d1).allSatisfy { $0.variacao == nil })
    }

    /// A covered day with no activity is drawn as a real zero, not left off the axis. Omitting it
    /// would let the stacked area interpolate straight across the gap — a smooth ramp over a day that
    /// measured nothing.
    @Test
    func aCoveredDayWithNoRowsIsAZeroOnTheAxisNotAHole() {
        let d1 = Base.dia(2026, 8, 1), d2 = Base.dia(2026, 8, 2), d3 = Base.dia(2026, 8, 3)
        let f = fluxo(
            [Base.linha(d1, "alfa", 1_000), Base.linha(d3, "alfa", 1_000)],
            eixo: [d1, d2, d3])

        #expect(f.dias == [d1, d2, d3])
        #expect(f.total(em: d2) == 0)
        #expect(f.pontos.filter { $0.dia == d2 }.count == f.bandas.count)
        // Without an axis the middle day would simply not exist — which is the defect, stated.
        let semEixo = fluxo([Base.linha(d1, "alfa", 1_000), Base.linha(d3, "alfa", 1_000)])
        #expect(semEixo.dias == [d1, d3])
    }

    /// Nothing to draw is nothing to draw: one day is not a flow, and an all-zero slice is not one
    /// either.
    @Test
    func aSingleDayOrAnAllZeroSliceDoesNotDraw() {
        let d1 = Base.dia(2026, 8, 1), d2 = Base.dia(2026, 8, 2)
        #expect(fluxo([Base.linha(d1, "alfa", 1_000)]).vaiDesenhar == false)
        #expect(fluxo([Base.linha(d1, "alfa", 0), Base.linha(d2, "alfa", 0)]).vaiDesenhar == false)
        #expect(fluxo([Base.linha(d1, "alfa", 1), Base.linha(d2, "alfa", 2)]).vaiDesenhar)
    }
}

// MARK: - The view model actually carries the grain

/// The three charts above are pure functions of fields `DashboardData` did not use to have. This is
/// the seam: the fold produces them, and the view model has to hand them over unchanged.
struct DimensoesNoViewModelTests {
    private func analytics(dias: [Date], projeto: String) -> UsageAnalytics {
        UsageAnalytics(
            byDayModel: dias.map {
                ModelCostEntry(
                    model: "claude-sonnet-4", date: $0,
                    inputTokens: 1_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                    cost: 0.01)
            },
            byProject: [ProjectUsageEntry(project: projeto, costUSD: 0.1, totalTokens: 10_000)],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [Base.sessao("s", tokens: 10_000, custo: 0.1)],
            monthToDateCost: 1,
            coveredDays: Set(dias),
            byDayProject: dias.map { Base.linha($0, projeto, 1_000) },
            rankedProjects: [projeto],
            otherProjectCount: 3,
            sessionTokenBuckets: Base.baldes([Base.sessao("s", tokens: 10_000)]),
            medianSessionTokens: 10_000,
            sessions: [Base.sessao("s", tokens: 10_000, custo: 0.1)],
            totalSessions: 9,
            monthCoverage: [Base.cobertura(Base.mes(2026, 8), noMes: 31, naSelecao: 3)])
    }

    @Test
    func theViewModelCarriesEveryNewDimensionVerbatim() {
        let dias = (1 ... 3).map { Base.dia(2026, 8, $0) }
        let dados = DashboardData.build(
            from: analytics(dias: dias, projeto: "alfa"),
            span: DashboardSpan(inicio: dias.first!, fim: dias.last!),
            now: dias.last!)

        #expect(dados.rankedProjects == ["alfa"])
        #expect(dados.otherProjectCount == 3)
        #expect(dados.projectsTruncated)
        #expect(dados.byDayProject.count == 3)
        #expect(dados.monthCoverage.count == 1)
        #expect(dados.medianSessionTokens == 10_000)
        #expect(dados.totalSessions == 9)
        #expect(dados.sessionsTruncated)                 // 1 carried, 9 real — stated, not hidden
        #expect(dados.sessionTokenBuckets.reduce(0, +) == 1)
    }

    /// The one transformation on the way in: rows outside the covered span are clipped, once, here —
    /// rather than by each chart filtering the same rule independently, which is the shape a rule
    /// takes just before one of its copies is forgotten.
    @Test
    func rowsOutsideTheCoveredSpanAreClippedOnceOnTheWayIn() {
        let dias = (1 ... 5).map { Base.dia(2026, 8, $0) }
        var bruto = analytics(dias: Array(dias.dropFirst(2)), projeto: "alfa")
        // A row on a day the archive never watched — the coverage anchor starts at day 3.
        bruto = UsageAnalytics(
            byDayModel: bruto.byDayModel,
            byProject: bruto.byProject,
            heatmap: bruto.heatmap,
            topSessions: bruto.topSessions,
            monthToDateCost: bruto.monthToDateCost,
            coveredDays: bruto.coveredDays,
            byDayProject: dias.map { Base.linha($0, "alfa", 1_000) },
            rankedProjects: bruto.rankedProjects,
            otherProjectCount: bruto.otherProjectCount,
            sessionTokenBuckets: bruto.sessionTokenBuckets,
            medianSessionTokens: bruto.medianSessionTokens,
            sessions: bruto.sessions,
            totalSessions: bruto.totalSessions,
            monthCoverage: bruto.monthCoverage)

        let dados = DashboardData.build(
            from: bruto,
            span: DashboardSpan(inicio: dias.first!, fim: dias.last!),
            now: dias.last!)

        #expect(dados.byDayProject.count == 3)                  // 5 rows in, 2 uncovered days dropped
        #expect(dados.byDayProject.map(\.day).min() == dias[2])
        #expect(dados.diasCobertos.count == 3)                  // and it agrees with the day axis
    }
}

// MARK: - Every new label exists in both tables

/// A key missing from a `.strings` table does not crash and does not blank the screen: `L` returns the
/// key itself, so `dashboard.cascade.refuse.thin` ships as a label. It reads like a debug artefact and
/// it is invisible to every test that only checks values.
struct RotulosDasDimensoesTests {
    static let chaves = [
        "dashboard.sessions.hist.title", "dashboard.sessions.hist.sub",
        "dashboard.sessions.hist.median", "dashboard.sessions.hist.headline",
        "dashboard.sessions.hist.headline.one",
        "dashboard.sessions.hist.concentration", "dashboard.sessions.hist.concentration.unknown",
        "dashboard.sessions.hist.axis.size", "dashboard.sessions.hist.axis.count",
        "dashboard.sessions.hist.thin",
        "dashboard.sessions.hist.tooltip.range", "dashboard.sessions.hist.tooltip.count",
        "dashboard.sessions.hist.tooltip.more", "dashboard.sessions.hist.tooltip.subset",
        "dashboard.cascade.title", "dashboard.cascade.sub", "dashboard.cascade.axis",
        "dashboard.cascade.others", "dashboard.cascade.delta.up", "dashboard.cascade.delta.down",
        "dashboard.cascade.divisor", "dashboard.cascade.clip.complete",
        "dashboard.cascade.clip.selection", "dashboard.cascade.clip.history",
        "dashboard.cascade.clip.both", "dashboard.cascade.refuse.pair",
        "dashboard.cascade.refuse.thin", "dashboard.cascade.others.count",
        "dashboard.cascade.others.aggregate",
        "dashboard.flow.title", "dashboard.flow.sub", "dashboard.flow.axis", "dashboard.flow.others",
        "dashboard.flow.truncated", "dashboard.flow.tooltip.total",
        "dashboard.flow.tooltip.first_day", "dashboard.flow.empty",
    ]

    /// "1 sessions · median 139.6K" is what the first render actually produced, and the thin case is
    /// exactly when that header is read: the chart refuses to draw, so the count is all there is.
    @MainActor
    @Test
    func theSessionHeadlineAgreesWithItsOwnCount() {
        func manchete(_ total: Int) -> String {
            SessionSizeHistogramChart(histograma: HistogramaDeSessoes(
                buckets: [Int](repeating: 0, count: 20), mediana: 139_600, total: total, topo: []))
                .manchete
        }
        for idioma in ["en", "pt-BR"] {
            ClaudeBarLocalization.$languageOverride.withValue(idioma) {
                resetClaudeBarLocalizationCache()
                defer { resetClaudeBarLocalizationCache() }
                let uma = manchete(1)
                let duas = manchete(2)
                #expect(uma.hasPrefix("1 "))
                #expect(duas.hasPrefix("2 "))
                #expect(uma != duas)
                // The singular is a different noun, not the same one with a different number in front.
                let palavraUma = uma.split(separator: " ")[1]
                let palavraDuas = duas.split(separator: " ")[1]
                #expect(palavraUma != palavraDuas, "\(idioma): \"\(uma)\" vs \"\(duas)\"")
                #expect(uma.contains("139.6K"))
            }
        }
    }

    /// The hover box parks in the corner **opposite** the band it names, so it can never cover the bar
    /// and the dots the reader just pointed at. Anchored to the band — the obvious choice — it did
    /// exactly that, and no assertion in the suite could see it; only the render could.
    @MainActor
    @Test
    func theBandTooltipParksOppositeTheBandItNames() {
        func canto(_ faixa: Int) -> Alignment {
            var baldes = [Int](repeating: 0, count: UsageAnalytics.sessionTokenBucketCount)
            baldes[faixa] = 7
            return SessionSizeHistogramChart(
                histograma: HistogramaDeSessoes(
                    buckets: baldes, mediana: 1_000, total: 7, topo: []),
                faixaInicial: faixa)
                .cantoDaDica
        }

        #expect(canto(0) == .topTrailing)     // band on the left → box on the right
        #expect(canto(9) == .topTrailing)
        #expect(canto(10) == .topLeading)     // and it flips at the middle of the axis
        #expect(canto(19) == .topLeading)     // band on the right → box on the left
        // With no band open there is no box; the default is stated rather than left to chance.
        #expect(SessionSizeHistogramChart(histograma: HistogramaDeSessoes(
            buckets: [Int](repeating: 0, count: 20), mediana: 0, total: 0, topo: []))
            .cantoDaDica == .topTrailing)
    }

    @Test
    func everyNewKeyResolvesInBothLanguages() {
        for idioma in ["en", "pt-BR"] {
            ClaudeBarLocalization.$languageOverride.withValue(idioma) {
                resetClaudeBarLocalizationCache()
                defer { resetClaudeBarLocalizationCache() }
                for chave in Self.chaves {
                    #expect(L(chave) != chave, "\(idioma)/\(chave) is missing from the table")
                }
            }
        }
    }
}
