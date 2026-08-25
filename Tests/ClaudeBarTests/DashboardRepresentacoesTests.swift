import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

// MARK: - Shared fixtures

/// A calendar pinned so nothing below depends on the host's region or first weekday, and dates built
/// from components so nothing depends on the host's time zone either. The suite runs under three
/// zones; a fixture anchored to an epoch instant would drift a day west of Greenwich.
private enum Fixo {
    static var calendario: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    static func dia(_ ano: Int, _ mes: Int, _ dia: Int) -> Date {
        calendario.date(from: DateComponents(year: ano, month: mes, day: dia))!
    }

    static func entrada(_ data: Date, tokens: Int, coberto: Bool = true) -> DashboardDailyEntry {
        DashboardDailyEntry(
            date: data, costUSD: 0, tokens: tokens,
            inputTokens: tokens, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, coberto: coberto)
    }
}

// MARK: - G1 · Project concentration curve

/// EXB-5.10 G1 — the curve that turns an ordered list of 101 projects into one actionable count.
///
/// The suite is built around the property that makes the chart worth drawing: it has to be **decisive
/// in both directions**. A derivation that always answered "3", or always answered "n", would satisfy
/// a single fixture perfectly — so every claim below is checked against two inputs that differ on the
/// exact axis being measured (how concentrated the volume is), never one.
struct ParetoCurvaTests {
    private func projeto(_ nome: String, _ tokens: Int) -> ProjectUsageEntry {
        ProjectUsageEntry(project: nome, costUSD: 0, totalTokens: tokens)
    }

    /// Three projects carry ~97 %, ninety-seven carry the rest.
    private func concentrado() -> [ProjectUsageEntry] {
        (0 ..< 3).map { projeto("grande-\($0)", 1_000) }
            + (0 ..< 97).map { projeto("cauda-\(String(format: "%02d", $0))", 1) }
    }

    /// A hundred projects of identical size — there is no lever at the project level here.
    private func plano() -> [ProjectUsageEntry] {
        (0 ..< 100).map { projeto("igual-\(String(format: "%03d", $0))", 100) }
    }

    /// The reading changes with the input, which is the only thing that makes the chart informative.
    /// A constant answer passes any single-fixture test and fails this one.
    @Test
    func theCrossingIsDecisiveInBothDirections() {
        let cheio = ParetoCurva(projetos: concentrado())
        let raso = ParetoCurva(projetos: plano())

        #expect(cheio.rankNoLimiar == 3)
        #expect(raso.rankNoLimiar == 80)
        #expect(cheio.quantidadeDeProjetos == 100)
        #expect(raso.quantidadeDeProjetos == 100)
        // Same project count, same threshold, opposite conclusions.
        #expect(cheio.rankNoLimiar != raso.rankNoLimiar)
    }

    /// The crossing is the **smallest** rank that reaches the threshold. Every later rank reaches it
    /// too, so a derivation that kept the last one would still return a number — and would answer
    /// "100 projects" for an archive where three carry everything.
    @Test
    func theCrossingIsTheSmallestQualifyingRankNotTheLast() {
        let curva = ParetoCurva(projetos: concentrado())
        let rank = try! #require(curva.rankNoLimiar)

        #expect(curva.pontos[rank - 1].acumulado >= curva.limiar)
        #expect(curva.pontos[rank - 2].acumulado < curva.limiar)
        // The last rank always clears the threshold — so "clears it" cannot be the selection rule.
        #expect(curva.pontos.last!.acumulado >= curva.limiar)
        #expect(rank < curva.pontos.count)
    }

    @Test
    func theCurveIsMonotoneAndClosesAtOne() {
        let curva = ParetoCurva(projetos: concentrado())

        #expect(curva.pontos.count == 100)
        #expect(curva.total == 3_097)
        var anterior = 0.0
        for ponto in curva.pontos {
            #expect(ponto.acumulado >= anterior)
            anterior = ponto.acumulado
        }
        #expect(abs(curva.pontos.last!.acumulado - 1.0) < 1e-12)
        #expect(curva.pontos.first!.rank == 1)
    }

    /// The curve sorts its own input. `DashboardData.build` already hands `byProject` over in
    /// descending order, but a cumulative curve over an unsorted list is not a noisier curve — it is a
    /// different, meaningless one, and it draws exactly as convincingly.
    @Test
    func anUnsortedInputProducesTheSameCurve() {
        let ordenado = ParetoCurva(projetos: concentrado())
        let embaralhado = ParetoCurva(projetos: concentrado().reversed())

        #expect(embaralhado.pontos == ordenado.pontos)
        #expect(embaralhado.rankNoLimiar == ordenado.rankNoLimiar)
        // And the first rank really is the biggest project, not whatever came first in the array.
        #expect(embaralhado.pontos.first!.tokens == 1_000)
    }

    @Test
    func anEmptyOrZeroInputProducesNoCurveRatherThanANaN() {
        let vazio = ParetoCurva(projetos: [])
        #expect(vazio.pontos.isEmpty)
        #expect(vazio.rankNoLimiar == nil)
        #expect(vazio.total == 0)

        let zerado = ParetoCurva(projetos: [projeto("a", 0), projeto("b", 0)])
        #expect(zerado.pontos.isEmpty)
        #expect(zerado.rankNoLimiar == nil)
    }
}

// MARK: - G2 · Composition normalized to 100 %

/// EXB-5.10 G2 — separating "I used more" from "I used it differently".
///
/// The central test is ``sameMixAtTenTimesTheVolumeNormalizesIdentically``, and its shape is the
/// point: a convergence test over **one** day is blind to any derivation that happens to return that
/// day's own numbers. The fixture therefore differs on the measured axis — same mix at different
/// volume, and same volume at different mix — so neither "returns the absolute" nor "returns a
/// constant" survives.
struct ComposicaoDiariaTests {
    private let d1 = Fixo.dia(2026, 8, 20)
    private let d2 = Fixo.dia(2026, 8, 21)
    private let d3 = Fixo.dia(2026, 8, 22)

    private func linha(_ data: Date, _ modelo: String, _ tokens: Int) -> DailyModelEntry {
        DailyModelEntry(date: data, modelName: modelo, tokens: tokens)
    }

    @Test
    func sameMixAtTenTimesTheVolumeNormalizesIdentically() {
        let entradas = [
            linha(d1, "opus", 300), linha(d1, "sonnet", 100),   // total 400
            linha(d2, "opus", 3_000), linha(d2, "sonnet", 1_000), // total 4 000 — same mix, 10×
        ]
        let fracoes = ComposicaoDiaria.fracoes(entradas: entradas, datasCobertas: [d1, d2])

        let dia1 = fracoes.filter { $0.date == d1 }
        let dia2 = fracoes.filter { $0.date == d2 }
        #expect(dia1.map(\.fracao) == dia2.map(\.fracao))
        // …and the shared value is the mix, not the volume: a derivation returning the absolute would
        // also make the two lists "equal" only if the volumes were equal, which is why they are not.
        #expect(dia1.first(where: { $0.modelName == "opus" })!.fracao == 0.75)
        #expect(dia1.first(where: { $0.modelName == "sonnet" })!.fracao == 0.25)
    }

    /// The other half of the same guard: identical volume with a different mix must NOT normalize to
    /// the same fractions, or the function is a constant that the test above would happily bless.
    @Test
    func sameVolumeWithADifferentMixDoesNotNormalizeIdentically() {
        let entradas = [
            linha(d1, "opus", 300), linha(d1, "sonnet", 100),
            linha(d3, "opus", 100), linha(d3, "sonnet", 300), // same 400 total, mix inverted
        ]
        let fracoes = ComposicaoDiaria.fracoes(entradas: entradas, datasCobertas: [d1, d3])

        #expect(fracoes.filter { $0.date == d1 }.map(\.fracao) == [0.75, 0.25])
        #expect(fracoes.filter { $0.date == d3 }.map(\.fracao) == [0.25, 0.75])
    }

    @Test
    func everyDaySumsToOne() {
        let entradas = [
            linha(d1, "opus", 7), linha(d1, "sonnet", 11), linha(d1, "haiku", 3),
            linha(d2, "opus", 1),
        ]
        let fracoes = ComposicaoDiaria.fracoes(entradas: entradas, datasCobertas: [d1, d2])

        for data in [d1, d2] {
            let soma = fracoes.filter { $0.date == data }.reduce(0.0) { $0 + $1.fracao }
            #expect(abs(soma - 1.0) < 1e-12)
        }
    }

    /// A day with nothing in it has no denominator. Dividing anyway yields `NaN`, which Swift Charts
    /// does not reject — it drops the mark or draws it at the top of the plot, either of which is a
    /// picture of a mix that never happened.
    @Test
    func aDayWithZeroTotalDrawsNothingInsteadOfDividingByZero() {
        let entradas = [
            linha(d1, "opus", 0), linha(d1, "sonnet", 0),
            linha(d2, "opus", 50),
        ]
        let fracoes = ComposicaoDiaria.fracoes(entradas: entradas, datasCobertas: [d1, d2])

        #expect(fracoes.allSatisfy { $0.date != d1 })
        #expect(fracoes.allSatisfy { $0.fracao.isFinite })
        #expect(fracoes.count == 1)
    }

    /// The same rule every chart on this screen follows: a day the source never watched is a gap. A
    /// normalized chart makes the temptation worse, because an uncovered day would otherwise draw a
    /// perfectly plausible full-height band.
    @Test
    func anUncoveredDayDrawsNothing() {
        let entradas = [linha(d1, "opus", 300), linha(d2, "opus", 400)]
        let fracoes = ComposicaoDiaria.fracoes(entradas: entradas, datasCobertas: [d2])

        #expect(fracoes.count == 1)
        #expect(fracoes.first!.date == d2)
    }
}

// MARK: - G3 · Today among its peers

/// EXB-5.10 G3 — the strip that survives the skew the mean does not.
struct DistribuicaoDiariaTests {
    private func eixo(_ valores: [Int], primeiroDia: Date) -> [DashboardDailyEntry] {
        valores.enumerated().map { indice, tokens in
            Fixo.entrada(
                Fixo.calendario.date(byAdding: .day, value: indice, to: primeiroDia)!,
                tokens: tokens)
        }
    }

    /// The reason this strip exists rather than one more percentage against the average.
    ///
    /// Ten ordinary days and one enormous one put the mean an order of magnitude above the day the
    /// Senhor actually has. A badge reading "-90 % abaixo da média" would be describing his *typical*
    /// Tuesday; the median describes it correctly.
    @Test
    func theMedianSurvivesASkewThatDefeatsTheMean() {
        let inicio = Fixo.dia(2026, 8, 1)
        let dias = eixo(Array(repeating: 1_000, count: 10) + [100_000], primeiroDia: inicio)
        let distribuicao = DistribuicaoDiaria(
            dias: dias, hoje: inicio, calendar: Fixo.calendario)

        let media = Double(dias.reduce(0) { $0 + $1.tokens }) / Double(dias.count)
        #expect(distribuicao.mediana == 1_000)
        #expect(media == 10_000)
        #expect(media > distribuicao.mediana * 5)
    }

    /// A day tied with most of the axis sits in the middle of its tie band, not at the top of it.
    /// Counting `<=` would report "acima de 91% dos dias" about the single most ordinary day there is.
    @Test
    func aTiedDayLandsInTheMiddleOfItsBandNotAtTheTop() {
        let inicio = Fixo.dia(2026, 8, 1)
        let dias = eixo(Array(repeating: 1_000, count: 10) + [100_000], primeiroDia: inicio)
        let distribuicao = DistribuicaoDiaria(dias: dias, hoje: inicio, calendar: Fixo.calendario)

        // 0 days strictly below, 10 at or below, out of 11 → 5/11.
        let posicao = try! #require(distribuicao.posicaoDeHoje)
        #expect(abs(posicao - 5.0 / 11.0) < 1e-12)
        #expect(posicao < 0.5)
    }

    /// And the position still moves with the day, so it is not a constant dressed as a statistic.
    @Test
    func thePositionMovesWithTheDay() {
        let inicio = Fixo.dia(2026, 8, 1)
        let valores = [10, 20, 30, 40, 50]
        let dias = eixo(valores, primeiroDia: inicio)
        let cal = Fixo.calendario

        let primeiro = DistribuicaoDiaria(dias: dias, hoje: inicio, calendar: cal)
        let ultimo = DistribuicaoDiaria(
            dias: dias, hoje: cal.date(byAdding: .day, value: 4, to: inicio)!, calendar: cal)

        #expect(primeiro.tokensDeHoje == 10)
        #expect(ultimo.tokensDeHoje == 50)
        #expect(abs(primeiro.posicaoDeHoje! - 0.1) < 1e-12) // (0 + 1) / 2 / 5
        #expect(abs(ultimo.posicaoDeHoje! - 0.9) < 1e-12)   // (4 + 5) / 2 / 5
        #expect(primeiro.mediana == 30)
    }

    @Test
    func medianHandlesEvenAndOddCounts() {
        #expect(DistribuicaoDiaria.mediana(deOrdenados: [1, 2, 3]) == 2)
        #expect(DistribuicaoDiaria.mediana(deOrdenados: [1, 2, 3, 4]) == 2.5)
        #expect(DistribuicaoDiaria.mediana(deOrdenados: []) == 0)
    }

    /// A dragged range that ends before today has no "today" dot. Highlighting the last day of the
    /// range instead would answer a question nobody asked, in the colour reserved for the one they did.
    @Test
    func todayOutsideTheWindowLeavesNoHighlightRatherThanBorrowingOne() {
        let inicio = Fixo.dia(2026, 8, 1)
        let dias = eixo([10, 20, 30], primeiroDia: inicio)
        let distribuicao = DistribuicaoDiaria(
            dias: dias, hoje: Fixo.dia(2026, 8, 30), calendar: Fixo.calendario)

        #expect(distribuicao.tokensDeHoje == nil)
        #expect(distribuicao.posicaoDeHoje == nil)
        #expect(distribuicao.dias.allSatisfy { !$0.ehHoje })
        // The rule line survives — the median of the window is still a fact about it.
        #expect(distribuicao.mediana == 20)
    }

    /// An axis with no spread produces a strip on which every position looks identical — an ornament
    /// implying a comparison it cannot make. The card then shows the badge alone.
    @Test
    func aFlatOrTinyAxisRefusesToDraw() {
        let inicio = Fixo.dia(2026, 8, 1)
        let cal = Fixo.calendario

        let plano = DistribuicaoDiaria(
            dias: eixo([500, 500, 500, 500], primeiroDia: inicio), hoje: inicio, calendar: cal)
        #expect(plano.vaiDesenhar == false)

        let curto = DistribuicaoDiaria(
            dias: eixo([1, 900], primeiroDia: inicio), hoje: inicio, calendar: cal)
        #expect(curto.vaiDesenhar == false)

        let bom = DistribuicaoDiaria(
            dias: eixo([1, 500, 900], primeiroDia: inicio), hoje: inicio, calendar: cal)
        #expect(bom.vaiDesenhar)
    }
}

// MARK: - G4 · Rolling 12-month calendar

/// EXB-5.10 G4 — the two fatal traps, pinned.
struct CalendarioAnualTests {
    private let cal = Fixo.calendario
    private let fim = Fixo.dia(2026, 8, 24)

    private func entradas(_ pares: [(Date, Int)]) -> [DashboardDailyEntry] {
        pares.map { Fixo.entrada($0.0, tokens: $0.1) }
    }

    // MARK: Trap 1 — zero and no-data are different channels

    /// **The trap the whole chart turns on.** A watched day with zero tokens is a fact; an unwatched
    /// day is the absence of one. They must not share a ramp, so they do not share a *channel*: zero
    /// is a drawn cell at the floor, no-data is no cell at all.
    @Test
    func aWatchedZeroIsDrawnAndAnUnwatchedDayIsAHole() {
        let zero = Fixo.dia(2026, 8, 20)
        let ausente = Fixo.dia(2026, 8, 21)
        let usado = Fixo.dia(2026, 8, 22)

        // Only the covered days ever reach the grid — the wiring passes `data.diasCobertos`.
        let grade = CalendarioAnual(
            entradas: entradas([(zero, 0), (usado, 5_000)]), fim: fim, calendar: cal)

        #expect(grade.dias.contains { $0.data == zero })
        #expect(grade.dias.contains { $0.data == usado })
        #expect(grade.dias.allSatisfy { $0.data != ausente })

        // And the drawn zero really does sit at the floor of the ramp, distinct from the faintest
        // active level — two tones of one ramp is exactly what this must not become.
        #expect(grade.quantis.nivel(tokens: 0) == 0)
        #expect(grade.quantis.nivel(tokens: 5_000) >= 1)
        #expect(grade.quantis.intensidade(tokens: 0) == 0)
        #expect(grade.quantis.intensidade(tokens: 5_000) > 0)
    }

    /// The screen wires the grid from the coverage flag, not from the raw axis — proved through a
    /// real `DashboardData` rather than by passing a hand-made array, because the wiring is the part
    /// that can silently regress.
    @Test
    func theGridIsFedFromTheCoveredAxisOnly() {
        let agora = Fixo.dia(2026, 8, 24)
        func dia(_ recuo: Int) -> Date { cal.date(byAdding: .day, value: -recuo, to: agora)! }
        let uso = [0, 2, 5].map {
            ModelCostEntry(
                model: "claude-sonnet-4", date: dia($0),
                inputTokens: 1_000, outputTokens: 500,
                cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0.1)
        }
        let analytics = UsageAnalytics(
            byDayModel: uso, byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0,
            coveredDays: Set((0 ... 9).map(dia)))
        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: agora)

        // 30-day window, 10 covered days: the other 20 are gaps and must not reach the grid.
        #expect(data.spanDays == 30)
        #expect(data.diasCobertos.count == 10)

        let grade = CalendarioAnual(entradas: data.diasCobertos, fim: agora, calendar: cal)
        #expect(grade.dias.count == 10)
        #expect(grade.dias.allSatisfy { $0.data >= dia(9) })
        // A full year of grid, ten days of it painted — the shape the chart exists to show.
        #expect(grade.totalDeDias >= 365)
        #expect(grade.diasSemCelula == grade.totalDeDias - 10)
    }

    // MARK: Trap 2 — the ramp is cut by quantile, not by value

    /// **The second trap.** With this distribution a linear ramp over `0 … max` puts almost every day
    /// in the bottom bucket and the calendar renders as one pale sheet with three bright squares.
    ///
    /// The fixture is built so the two rules give visibly different answers: 20 days spread from 1M to
    /// 20M plus four days at 100M / 300M / 900M / 2 700M. Quantiles split them 6/6/6/6. A linear
    /// ramp over `0 … 2 700M` would put everything at or below 675M — 22 of the 24 days — into level 1,
    /// leaving three of its four colours for the two outliers.
    @Test
    func theRampSpendsColourEvenlyAcrossTheDaysNotAcrossTheRange() {
        let valores = (1 ... 20).map { $0 * 1_000_000 } + [100_000_000, 300_000_000, 900_000_000, 2_700_000_000]
        let quantis = CalendarioQuantis(tokens: valores)

        #expect(quantis.amostra == 24)
        #expect(quantis.cortes == [6_000_000, 12_000_000, 18_000_000])

        var porNivel = [Int: Int]()
        for valor in valores { porNivel[quantis.nivel(tokens: valor), default: 0] += 1 }
        #expect(porNivel[1] == 6)
        #expect(porNivel[2] == 6)
        #expect(porNivel[3] == 6)
        #expect(porNivel[4] == 6)
        #expect(porNivel[0] == nil)

        // What a linear ramp would have done to the same data, stated so the comparison is on record.
        let linear = valores.filter { $0 <= 2_700_000_000 / 4 }.count
        #expect(linear == 22)
        #expect(linear > porNivel[1]!)
    }

    /// Ties are resolved by value, so two days of identical volume can never be painted differently —
    /// a rank-based cut would split a run of equal days across two colours.
    @Test
    func identicalVolumesAlwaysGetTheSameLevel() {
        let quantis = CalendarioQuantis(tokens: Array(repeating: 7, count: 4) + [1, 2, 3, 99])
        #expect(quantis.nivel(tokens: 7) == quantis.nivel(tokens: 7))
        let niveis = Set([7, 7, 7, 7].map { quantis.nivel(tokens: $0) })
        #expect(niveis.count == 1)
    }

    /// Zeros stay out of the sample. Let them in on a fresh install and all three cuts collapse to
    /// `0`, folding the four active levels into one.
    @Test
    func zeroDaysDoNotFeedTheQuantiles() {
        let comZeros = CalendarioQuantis(tokens: Array(repeating: 0, count: 300) + [10, 20, 30, 40])
        let semZeros = CalendarioQuantis(tokens: [10, 20, 30, 40])

        #expect(comZeros.cortes == semZeros.cortes)
        #expect(comZeros.amostra == 4)
        #expect(comZeros.nivel(tokens: 10) == 1)
        #expect(comZeros.nivel(tokens: 40) == 4)
    }

    @Test
    func anEmptySampleProducesNoCutsRatherThanZeroCuts() {
        let vazio = CalendarioQuantis(tokens: [])
        #expect(vazio.cortes.isEmpty)
        #expect(vazio.amostra == 0)
        #expect(vazio.nivel(tokens: 0) == 0)
        // With no cuts, any active day is simply level 1 — never a division by an empty sample.
        #expect(vazio.nivel(tokens: 999) == 1)
    }

    // MARK: Geometry

    /// A rolling year: twelve months back from the end of the axis, never the calendar year and never
    /// the whole archive — both of those change the cell size with the date the chart is read.
    @Test
    func theGridSpansTwelveMonthsBackFromTheEndOfTheAxis() {
        let grade = CalendarioAnual(entradas: [], fim: fim, calendar: cal)

        #expect(grade.fim == fim)
        #expect(grade.inicio == Fixo.dia(2025, 8, 25))
        #expect(grade.totalDeDias == 365)
        // Weeks, so the column count is the year divided into whole weeks (plus the partial edges).
        #expect(grade.colunas.count >= 52)
        #expect(grade.colunas.count <= 54)
        #expect(grade.linhas.count == 7)
    }

    @Test
    func aDayOlderThanTheGridIsNotPainted() {
        let velho = Fixo.dia(2025, 6, 1)
        let dentro = Fixo.dia(2026, 6, 1)
        let grade = CalendarioAnual(
            entradas: entradas([(velho, 100), (dentro, 100)]), fim: fim, calendar: cal)

        #expect(grade.dias.count == 1)
        #expect(grade.dias.first!.data == dentro)
    }

    /// **The boundary, which a far-away fixture cannot reach.**
    ///
    /// Columns are whole weeks, so the grid's first *column* starts up to six days before the grid's
    /// first *day*. That band is where the window's edge is actually decided, and a test that rejects
    /// a day from June of the previous year proves nothing about it: such a day is thrown out by the
    /// column arithmetic long before the range check is consulted. Two guards, one of them untested,
    /// is how a rule ends up with no gate at all.
    ///
    /// Swept across seven consecutive end dates so the band has every possible width — with a single
    /// end date the band can be empty and the sweep degenerates back into the blind test above.
    @Test
    func theEdgeOfTheGridHoldsAcrossEveryWeekdayAlignment() {
        for deslocamento in 0 ..< 7 {
            let fimVarrido = cal.date(byAdding: .day, value: deslocamento, to: fim)!
            let referencia = CalendarioAnual(entradas: [], fim: fimVarrido, calendar: cal)
            let primeiro = referencia.inicio
            let vespera = cal.date(byAdding: .day, value: -1, to: primeiro)!

            let semanaSeguinte = cal.date(byAdding: .day, value: 7, to: primeiro)!
            let grade = CalendarioAnual(
                entradas: entradas([
                    (vespera, 100), (primeiro, 100), (semanaSeguinte, 100), (fimVarrido, 100),
                ]),
                fim: fimVarrido, calendar: cal)

            // The first day of the rolling year is inside it…
            #expect(grade.dias.contains { $0.data == primeiro },
                    "offset \(deslocamento): the grid dropped its own first day")
            // …the day before it is not, even when it shares the first column's week…
            #expect(grade.dias.allSatisfy { $0.data != vespera },
                    "offset \(deslocamento): a day older than the window was painted")
            // …and the last day is still there.
            #expect(grade.dias.contains { $0.data == fimVarrido })
            #expect(grade.dias.count == 3)

            // The first column is a column, not a bucket that swallowed two weeks. Anchoring the grid
            // anywhere but a week boundary does not drop days — it folds the opening partial week into
            // the one after it, so both land on column 0 and a whole week of history disappears
            // *underneath* another one, which no count of painted cells would reveal.
            let a = grade.dias.first { $0.data == primeiro }!
            let b = grade.dias.first { $0.data == semanaSeguinte }!
            #expect(a.coluna == 0, "offset \(deslocamento): the grid does not start at column 0")
            #expect(b.coluna == 1,
                    "offset \(deslocamento): week 2 collapsed onto column \(b.coluna)")
        }
    }

    /// Rows mean weekday and columns mean week — so seven days apart is one column across and the same
    /// row, and one day apart is the next row down within the week.
    @Test
    func columnsAreWeeksAndRowsAreWeekdays() {
        let segunda = Fixo.dia(2026, 6, 1) // a Monday
        let terca = Fixo.dia(2026, 6, 2)
        let segundaSeguinte = Fixo.dia(2026, 6, 8)
        let grade = CalendarioAnual(
            entradas: entradas([(segunda, 1), (terca, 1), (segundaSeguinte, 1)]),
            fim: fim, calendar: cal)

        let a = grade.dias.first { $0.data == segunda }!
        let b = grade.dias.first { $0.data == terca }!
        let c = grade.dias.first { $0.data == segundaSeguinte }!

        #expect(b.coluna == a.coluna)
        #expect(b.linha == a.linha + 1)
        #expect(c.coluna == a.coluna + 1)
        #expect(c.linha == a.linha)
        // Sunday-first calendar: Monday is the second row.
        #expect(a.linha == 1)
    }

    /// Month labels anchor to the column where the month starts, one per month the grid reaches.
    @Test
    func everyMonthTheGridReachesGetsExactlyOneLabel() {
        let grade = CalendarioAnual(entradas: [], fim: fim, calendar: cal)

        #expect(grade.rotulosDeMes.count == 12)
        #expect(Set(grade.rotulosDeMes.map(\.coluna)).count == 12)
        #expect(grade.rotulosDeMes.allSatisfy { $0.coluna >= 0 && $0.coluna < grade.colunas.count })
        // Ascending, so the axis reads left to right in time.
        #expect(grade.rotulosDeMes.map(\.coluna) == grade.rotulosDeMes.map(\.coluna).sorted())
    }
}

// MARK: - Structure and localization

/// The two placement decisions of EXB-5.10 are decisions, not layout, so they are asserted rather
/// than left to a screenshot.
///
/// G2 is an **alternância on the existing per-model chart** and G3 lives **inside the today card**.
/// Both could be "implemented" as two more sections stacked on the scroll view, which would compile,
/// pass every derivation test above, and leave a menu-bar window with eight charts nobody can read.
/// That regression has no other gate.
struct DashboardRepresentacoesEstruturaTests {
    nonisolated private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func view() throws -> String {
        try source("Sources/ClaudeBar/Dashboard/DashboardView.swift")
    }

    /// The share mode is a toggle on `ModelsByDayChart`, not a section of its own.
    @Test
    func shareModeIsAToggleOnTheExistingChartAndNotANewSection() throws {
        let source = try Self.view()

        // It is declared inside `ModelsByDayChart`…
        let chart = source
            .components(separatedBy: "struct ModelsByDayChart").dropFirst().joined()
            .components(separatedBy: "/// Models-per-day hover tooltip").first ?? ""
        #expect(chart.contains("@State private var modo: ModoComposicao"))
        #expect(chart.contains("private var chartProporcao"))
        #expect(chart.contains("Picker(\"\", selection: $modo)"))
        // …and the share view is *reached*, not merely declared. Asserting that `chartProporcao`
        // appears would pass just as happily on a chart that defines it and never renders it — a
        // toggle that moves and changes nothing. So: once for the declaration, once for the call.
        //
        // Counted rather than matched against the dispatch expression, because `modo == .absoluto`
        // also appears in the header's explanation ternary — a substring test on it stays green with
        // the body dispatch deleted, which is how this assertion failed its own mutation the first
        // time it was written.
        let mencoes = chart.components(separatedBy: "chartProporcao").count - 1
        #expect(mencoes >= 2, "chartProporcao is declared but never rendered")

        // …and it is NOT wired into the screen as a sibling of the other sections.
        let tela = source
            .components(separatedBy: "private struct LoadedDashboard").dropFirst().joined()
            .components(separatedBy: "// MARK: - Coverage banner").first ?? ""
        #expect(!tela.contains("chartProporcao"))
        #expect(!tela.contains("ComposicaoDiaria"))
    }

    /// The peer strip is a slot on `MetricCard`, reached from the today card — not an eighth section.
    @Test
    func thePeerStripLivesInsideTheTodayCard() throws {
        let source = try Self.view()

        let card = source
            .components(separatedBy: "private struct MetricCard: View").dropFirst().joined()
            .components(separatedBy: "/// Today against every day").first ?? ""
        #expect(card.contains("var distribuicao: DistribuicaoDiaria?"))
        #expect(card.contains("DiaEntreParesStrip(distribuicao: distribuicao)"))

        let tela = source
            .components(separatedBy: "private struct LoadedDashboard").dropFirst().joined()
            .components(separatedBy: "// MARK: - Coverage banner").first ?? ""
        #expect(!tela.contains("DiaEntreParesStrip"))
    }

    /// The two new sections that ARE sections sit where they were placed: the curve under the table it
    /// reads out of, the calendar beside the other grid.
    @Test
    func theTwoNewSectionsSitWhereTheyWerePlaced() throws {
        let source = try Self.view()
        let tela = source
            .components(separatedBy: "private struct LoadedDashboard").dropFirst().joined()
            .components(separatedBy: "// MARK: - Coverage banner").first ?? ""

        let tabela = try #require(tela.range(of: "ProjectBreakdownTable(rows:"))
        let pareto = try #require(tela.range(of: "ProjectParetoChart(curva:"))
        let heatmap = try #require(tela.range(of: "ActivityHeatmapChart(data: data)"))
        let calendario = try #require(tela.range(of: "AnnualCalendarChart("))

        #expect(tabela.lowerBound < pareto.lowerBound)
        #expect(pareto.lowerBound < heatmap.lowerBound)
        #expect(heatmap.lowerBound < calendario.lowerBound)
    }

    /// The calendar's axes are **categorical**. With a numeric axis Swift Charts hands `RectangleMark`
    /// no band width and renders nothing — the defect that cost this repo the v1.4.1 release on the
    /// hour×weekday heatmap, where no colour could fix a cell that was never drawn. Both domains are
    /// also pinned, or an unobserved stretch would collapse instead of staying a gap.
    @Test
    func theCalendarAxesAreCategoricalAndPinned() throws {
        let source = try Self.view()
        let chart = source
            .components(separatedBy: "struct AnnualCalendarChart").dropFirst().joined()
            .components(separatedBy: "/// The calendar's legend").first ?? ""

        #expect(chart.contains("String(format: \"%03d\", coluna)"))
        #expect(chart.contains(".chartXScale(domain: dominioX)"))
        #expect(chart.contains(".chartYScale(domain: dominioY)"))
        // The cell reads a String on both axes, never an Int.
        #expect(chart.contains("x: .value(eixoSemana, Self.chave(dia.coluna))"))
        #expect(chart.contains("y: .value(eixoDia, grade.linhas[dia.linha])"))

        // **Rows read downwards.** The y domain is passed in order. The first version reversed it,
        // on the belief that Charts stacks a categorical y domain bottom-up, and the render came back
        // with Saturday on the top row and Sunday on the bottom — a calendar that reads upwards. No
        // value assertion can see this; only the rendered image could, and only once.
        #expect(chart.contains("private var dominioY: [String] { grade.linhas }"))
        #expect(!chart.contains("grade.linhas.reversed()"))
    }

    /// The row labels themselves start at the calendar's own first weekday, which is what makes the
    /// unreversed domain above read as a calendar in every locale.
    @Test
    func theRowLabelsStartAtTheCalendarsFirstWeekday() {
        var domingo = Calendar(identifier: .gregorian)
        domingo.locale = Locale(identifier: "en_US_POSIX")
        domingo.firstWeekday = 1
        var segunda = domingo
        segunda.firstWeekday = 2

        let fim = domingo.date(from: DateComponents(year: 2026, month: 8, day: 24))!
        let gradeDomingo = CalendarioAnual(entradas: [], fim: fim, calendar: domingo)
        let gradeSegunda = CalendarioAnual(entradas: [], fim: fim, calendar: segunda)

        #expect(gradeDomingo.linhas.first == domingo.shortWeekdaySymbols[0]) // Sun
        #expect(gradeSegunda.linhas.first == domingo.shortWeekdaySymbols[1]) // Mon
        #expect(gradeDomingo.linhas.count == 7)
        #expect(Set(gradeDomingo.linhas) == Set(gradeSegunda.linhas))
    }

    /// The peer strip is on a **log** axis, and that is not a style choice.
    ///
    /// The linear version was rendered and was unreadable at 21 and at 90 days alike: the few enormous
    /// days set the scale, so every ordinary day collapsed into one blob at the left edge and today's
    /// position among them — the entire purpose of the strip — could not be seen. It is the same skew
    /// that made the mean useless one level up, so fixing the statistic and leaving the axis linear
    /// kept exactly the picture that hid the problem.
    @Test
    func thePeerStripIsPlottedOnALogAxis() throws {
        let source = try Self.view()
        let strip = source
            .components(separatedBy: "struct DiaEntreParesStrip").dropFirst().joined()
            .components(separatedBy: "/// The today-vs-average comparison badge").first ?? ""

        #expect(strip.contains(".chartXScale(type: .symmetricLog)"))
        // `symmetricLog`, not `log`: a covered day of genuine zero is a real day and belongs on the
        // axis, and plain log has nothing to say about zero.
        #expect(!strip.contains(".chartXScale(type: .log)"))
    }

    /// **The wiring, which the derivation tests cannot reach.**
    ///
    /// Every test above hands the derivations a covered axis by hand and proves they behave. None of
    /// them can see what the screen actually passes in — and swapping `diasCobertos` for `dailyCosts`
    /// at these two call sites compiles, keeps every derivation test green, and silently reintroduces
    /// the defect the whole coverage flag exists to prevent: an unwatched day carries `tokens == 0`,
    /// so it would pile onto the peer strip as a real quiet day and paint a real zero cell on the
    /// calendar. Both charts would then assert, confidently, about days nobody observed.
    @Test
    func bothNewChartsAreFedFromTheCoveredAxis() throws {
        let source = try Self.view()

        #expect(source.contains("DistribuicaoDiaria(dias: data.diasCobertos, hoje: hoje)"))
        #expect(source.contains("CalendarioAnual(entradas: data.diasCobertos, fim: fim)"))
        // Neither reads the raw axis. `dailyCosts` is zero-filled across the whole window by design.
        #expect(!source.contains("DistribuicaoDiaria(dias: data.dailyCosts"))
        #expect(!source.contains("CalendarioAnual(entradas: data.dailyCosts"))
    }

    /// Every key the four representations introduced exists in **both** tables. A key in one language
    /// only falls back silently to English for half the users.
    @Test
    func newKeysAreLocalizedInBothTables() throws {
        func keys(_ language: String) throws -> Set<String> {
            let source = try Self.source(
                "Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
            let regex = try NSRegularExpression(pattern: #"^"([^"]+)"\s*="#)
            var found: Set<String> = []
            for line in source.components(separatedBy: .newlines) {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let keyRange = Range(match.range(at: 1), in: line)
                else { continue }
                found.insert(String(line[keyRange]))
            }
            return found
        }

        let introduzidas: Set<String> = [
            "dashboard.pareto.title",
            "dashboard.pareto.sub",
            "dashboard.pareto.crossing",
            "dashboard.pareto.threshold",
            "dashboard.pareto.axis.rank",
            "dashboard.pareto.axis.share",
            "dashboard.pareto.empty",
            "dashboard.models_by_day.mode.absolute",
            "dashboard.models_by_day.mode.share",
            "dashboard.models_by_day.sub.share",
            "dashboard.models_by_day.y_share",
            "dashboard.today.distribution.with_today",
            "dashboard.today.distribution.without_today",
            "dashboard.today.distribution.axis",
            "dashboard.calendar.title",
            "dashboard.calendar.sub",
            "dashboard.calendar.painted",
            "dashboard.calendar.legend.less",
            "dashboard.calendar.legend.more",
            "dashboard.calendar.legend.zero",
            "dashboard.calendar.legend.missing",
            "dashboard.calendar.legend.scale",
            "dashboard.calendar.empty",
        ]

        let ingles = try keys("en")
        let portugues = try keys("pt-BR")
        #expect(introduzidas.subtracting(ingles).isEmpty)
        #expect(introduzidas.subtracting(portugues).isEmpty)
    }

    /// The sentences that carry numbers keep their placeholders, in both languages. A dropped `%d`
    /// renders "N de projetos concentram" — the crossing count silently gone from the one line the
    /// whole curve exists to produce.
    @Test
    func thePlaceholderCarryingSentencesKeepTheirArguments() throws {
        let esperado: [String: [String]] = [
            "dashboard.pareto.crossing": ["%1$d", "%2$d", "%3$d"],
            "dashboard.calendar.painted": ["%1$d", "%2$d"],
            "dashboard.calendar.legend.scale": ["%d"],
            "dashboard.today.distribution.with_today": ["%1$@", "%2$d", "%3$d"],
            "dashboard.today.distribution.without_today": ["%1$@", "%2$d"],
        ]
        for language in ["en", "pt-BR"] {
            let source = try Self.source(
                "Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
            let linhas = source.components(separatedBy: .newlines)
            for (key, marcadores) in esperado {
                let linha = try #require(linhas.first { $0.hasPrefix("\"\(key)\"") })
                for marcador in marcadores {
                    #expect(linha.contains(marcador), "\(language)/\(key) lost \(marcador)")
                }
            }
        }
    }
}
