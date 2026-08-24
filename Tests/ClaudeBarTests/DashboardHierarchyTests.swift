import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.9 — the screen adopts the information hierarchy `painel.html` established.
///
/// Three things are pinned here, and the third is the one that earns the file.
///
/// 1. **The derivations, in absolute terms.** A fixture where the three plausible divisors — window
///    (30), coverage (21) and days-with-usage (5) — are all different, so a wrong divisor produces a
///    visibly wrong number instead of coincidentally the right one.
/// 2. **Agreement with `PainelData`.** The app screen and the exported panel now publish the same
///    figures; two independent derivations of one number is how they would come to disagree with
///    nobody able to say which is lying.
/// 3. **That (2) is not proved by (1) alone.** Equivalence between two paths says they agree, not that
///    they are right — if both shared a defect they would agree on the defect. So every equivalence
///    assertion below sits beside an absolute assertion of the same quantity.
struct DashboardHierarchyTests {
    // MARK: - Fixture

    /// A fixed instant so day bucketing is deterministic regardless of when the suite runs.
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    /// One usage day: 42 000 tokens across the four kinds, $2.10.
    ///
    /// The split matters. `input + output` is 30 000 while the full volume is 42 000, which is what
    /// makes the two token measures on this screen visibly different rather than accidentally equal —
    /// see ``averagesDoNotSilentlyMixTwoTokenMeasures``.
    private func usageDay(_ offset: Int) -> ModelCostEntry {
        ModelCostEntry(
            model: "claude-sonnet-4", date: day(offset),
            inputTokens: 20_000, outputTokens: 10_000,
            cacheReadTokens: 10_000, cacheWriteTokens: 2_000, cost: 2.10)
    }

    /// 30-day window · coverage anchored 20 days back (21 covered days) · 5 days of actual usage.
    ///
    /// Totals: 5 × 42 000 = **210 000** tokens and 5 × $2.10 = **$10.50**. Chosen so each divisor
    /// yields a distinct, exactly-expressible average: 210 000 ÷ 21 = 10 000, ÷ 30 = 7 000, ÷ 5 = 42 000.
    private func fixture() -> DashboardData {
        let usage = [0, 3, 7, 11, 19].map(usageDay)
        let analytics = UsageAnalytics(
            byDayModel: usage,
            byProject: [],
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 0,
            coveredDays: Set((0...20).map(day)))
        return DashboardData.build(from: analytics, period: .thirtyDays, now: now)
    }

    /// The fixture's own control: unless the three divisors really are distinct, every assertion below
    /// could pass with the wrong one. This is the assertion that makes the others mean something.
    @Test
    func theThreeDivisorsAreDistinctInThisFixture() {
        let data = fixture()
        let janela = data.spanDays
        let cobertura = data.diasComDado
        let comUso = data.dailyCosts.filter { $0.tokens > 0 }.count

        #expect(janela == 30)
        #expect(cobertura == 21)
        #expect(comUso == 5)
        #expect(Set([janela, cobertura, comUso]).count == 3)
    }

    // MARK: - 1. The derivations, in absolute terms

    @Test
    func coverageReportsTheSpanTheChartsActuallyDrew() {
        let data = fixture()

        #expect(data.primeiroDiaComDado == day(20))
        #expect(data.ultimoDiaComDado == day(0))
        #expect(data.diasComDado == 21)
        #expect(data.diasSemDado == 9)
        #expect(data.cobreJanelaInteira == false)

        // The block at the top has to describe the same days the charts below it drew, and it does so
        // by reading the very flag they filter on — not a second opinion about coverage.
        let desenhados = data.dailyCosts.filter(\.coberto)
        #expect(desenhados.count == data.diasComDado)
        #expect(desenhados.first?.date == data.primeiroDiaComDado)
        #expect(desenhados.last?.date == data.ultimoDiaComDado)
    }

    @Test
    func coverageOfAWholeWindowSaysSoInsteadOfCountingDown() {
        let analytics = UsageAnalytics(
            byDayModel: [usageDay(0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
            monthToDateCost: 0,
            coveredDays: Set((0...40).map(day)))
        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)

        #expect(data.diasComDado == 30)
        #expect(data.diasSemDado == 0)
        #expect(data.cobreJanelaInteira)
    }

    @Test
    func theTwoAveragesDifferOnlyByTheirDivisor() {
        let data = fixture()

        #expect(data.totalTokens == 210_000)
        // 210 000 ÷ 21 covered days.
        #expect(data.tokensPorDiaComUso == 10_000)
        // 210 000 ÷ 30 requested days.
        #expect(data.tokensPorDiaDaJanela == 7_000)
        // Same numerator on both sides — the divisor is the *only* difference, which is precisely what
        // the two labels on screen claim.
        #expect(data.tokensPorDiaComUso * Double(data.diasComDado) == Double(data.totalTokens))
        #expect(data.tokensPorDiaDaJanela * Double(data.spanDays) == Double(data.totalTokens))
    }

    @Test
    func theTwoCostAveragesDifferOnlyByTheirDivisor() {
        let data = fixture()

        #expect(abs(data.totalCost - 10.50) < 0.000_001)
        #expect(abs(data.custoPorDiaComUso - 0.50) < 0.000_001)   // 10.50 ÷ 21
        #expect(abs(data.custoPorDiaDaJanela - 0.35) < 0.000_001) // 10.50 ÷ 30
        // `custoPorDiaComUso` is an alias, not a second division: it must be bit-identical to the
        // field the view model already computed, or the screen would show two "same" numbers that
        // disagree in the last decimal.
        #expect(data.custoPorDiaComUso == data.averageDailyCost)
    }

    /// The trap this whole section exists to avoid.
    ///
    /// `averageDailyTokens` counts `input + output` only — it is the badge's baseline, and the badge
    /// compares it against `todayTokens`, which counts the same two. Every *volume* figure on screen
    /// counts all four kinds. Putting `averageDailyTokens` on a card under a total of all four would
    /// produce two numbers no reader could reconcile: 7 142 × 21 ≠ 210 000, with nothing on screen
    /// explaining the gap. So the cards use ``DashboardData/tokensPorDiaComUso`` and the badge keeps
    /// its own measure.
    @Test
    func averagesDoNotSilentlyMixTwoTokenMeasures() {
        let data = fixture()

        // The measures really are different in this fixture — 30 000/day vs 42 000/day.
        #expect(data.thirtyDayTokens == 150_000)
        #expect(data.totalTokens == 210_000)
        #expect(data.averageDailyTokens == 150_000 / 21)

        // And so the card's average is NOT the badge's baseline. If a future edit points the card at
        // `averageDailyTokens`, this fails.
        #expect(data.tokensPorDiaComUso != Double(data.averageDailyTokens))
        #expect(data.tokensPorDiaComUso == 10_000)
    }

    @Test
    func anEmptyAxisYieldsNoCoverageDatesRatherThanAWrongOne() {
        let analytics = UsageAnalytics(
            byDayModel: [], byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)
        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)

        // No usage at all: the averages divide something by something and must not produce a NaN.
        #expect(data.tokensPorDiaComUso == 0)
        #expect(data.tokensPorDiaDaJanela == 0)
        #expect(data.custoPorDiaDaJanela == 0)
    }

    // MARK: - 2 + 3. Agreement with `PainelData`, each beside an absolute

    /// Fills a `PainelData` the way the panel adapter must: reading the app's derivations, never
    /// re-deriving them. Everything the panel then computes on top (`diasSemDado`, the four averages)
    /// has to land on the same numbers the screen shows.
    private func painel(from data: DashboardData) -> PainelData {
        let cobertura = PainelCobertura(
            janelaRotulo: "30 dias",
            janelaDias: data.spanDays,
            primeiroDia: data.primeiroDiaComDado,
            ultimoDia: data.ultimoDiaComDado,
            diasComDado: data.diasComDado)
        let indicadores = PainelIndicadores(
            tokensTotais: data.totalTokens,
            tokensHoje: data.todayTokens,
            modeloLiderNome: data.topModelByTokens?.name,
            modeloLiderTokens: data.topModelByTokens?.tokens ?? 0,
            taxaAcertoCache: data.cacheHitRate,
            tokensDeCache: data.tokensDeCache,
            tokensDeEntrada: data.tokensDeEntrada,
            horaPico: data.peakHour,
            custoTotal: data.totalCost,
            custoHoje: data.todayCost,
            projecaoMes: data.monthProjection)
        return PainelData(
            cobertura: cobertura,
            indicadores: indicadores,
            diario: data.dailyCosts.map {
                PainelDia(
                    dia: $0.date, entrada: $0.inputTokens, saida: $0.outputTokens,
                    cacheLeitura: $0.cacheReadTokens, cacheEscrita: $0.cacheWriteTokens,
                    custoUSD: $0.costUSD)
            },
            modelos: [], projetos: [], matrizModelos: .vazia, heatmap: [])
    }

    @Test
    func appAndPanelAgreeOnCoverage() {
        let data = fixture()
        let painel = painel(from: data)

        // Agreement…
        #expect(painel.cobertura.diasSemDado == data.diasSemDado)
        #expect(painel.cobertura.cobreJanelaInteira == data.cobreJanelaInteira)
        #expect(painel.cobertura.primeiroDia == data.primeiroDiaComDado)
        #expect(painel.cobertura.ultimoDia == data.ultimoDiaComDado)
        // …and the absolute, so agreement on a shared error would still fail here.
        #expect(painel.cobertura.diasSemDado == 9)
        #expect(painel.cobertura.cobreJanelaInteira == false)
        #expect(painel.cobertura.primeiroDia == day(20))
    }

    @Test
    func appAndPanelAgreeOnAllFourAverages() {
        let data = fixture()
        let painel = painel(from: data)

        #expect(painel.tokensPorDiaComUso == data.tokensPorDiaComUso)
        #expect(painel.tokensPorDiaDaJanela == data.tokensPorDiaDaJanela)
        #expect(abs(painel.custoPorDiaComUso - data.custoPorDiaComUso) < 0.000_001)
        #expect(abs(painel.custoPorDiaDaJanela - data.custoPorDiaDaJanela) < 0.000_001)

        // Pinned absolutely on the panel side too. Both sides now name the same four numbers, and a
        // divisor swapped on either side breaks this even though the other side stayed put.
        #expect(painel.tokensPorDiaComUso == 10_000)
        #expect(painel.tokensPorDiaDaJanela == 7_000)
        #expect(abs(painel.custoPorDiaComUso - 0.50) < 0.000_001)
        #expect(abs(painel.custoPorDiaDaJanela - 0.35) < 0.000_001)
    }

    /// The clipping rule is the same on both sides: the panel refuses to draw the uncovered days, and
    /// it refuses exactly the 9 the screen announced as missing.
    @Test
    func appAndPanelClipTheSeriesAtTheSameDay() {
        let data = fixture()
        let painel = painel(from: data)

        #expect(painel.diario.count == data.spanDays)
        #expect(painel.diarioCoberto.count == data.diasComDado)
        #expect(painel.diarioCoberto.count == 21)
        #expect(painel.diarioCoberto.first?.dia == data.primeiroDiaComDado)
        #expect(painel.diario.count - painel.diarioCoberto.count == data.diasSemDado)
    }

    // MARK: - The date the coverage block prints

    /// Written from calendar components, not a `DateFormatter`, so the string does not change with the
    /// machine's region — and matches `PainelDatas.longa` character for character, which is what lets
    /// the screen and the exported file be compared without translating between them.
    @Test
    func theCoverageDateIsLocaleIndependentAndMatchesThePanel() {
        let date = day(20)
        #expect(DashboardFormat.longDate(date) == PainelDatas.longa(date))

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 9
        let fixed = Calendar.current.date(from: components)!
        #expect(DashboardFormat.longDate(fixed) == "09/08/2026")
    }
}

// MARK: - Structure and localization

/// The hierarchy is the deliverable, so it is asserted as such rather than left to a screenshot.
struct DashboardHierarchyStructureTests {
    nonisolated private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Coverage before volume before cost — the panel's order, and the reason it is the order.
    ///
    /// A window the source does not cover makes every number under it a lie, so coverage cannot come
    /// second; the plan is a subscription, so tokens cannot come after dollars. Reordering these is a
    /// decision, not a layout tweak, and it should have to break a test to happen.
    @Test
    func theLoadedScreenDeclaresCoverageThenVolumeThenCost() throws {
        let source = try Self.source("Sources/ClaudeBar/Dashboard/DashboardView.swift")
        let body = source
            .components(separatedBy: "private struct LoadedDashboard").dropFirst().joined()
            .components(separatedBy: "// MARK: - Coverage banner").first ?? ""

        let coverage = try #require(body.range(of: "CoverageBanner(data: data)"))
        let volume = try #require(body.range(of: "VolumeSection(data: data)"))
        let cost = try #require(body.range(of: "CostSection(data: data)"))
        let charts = try #require(body.range(of: "StackedTokensChart(data: data"))

        #expect(coverage.lowerBound < volume.lowerBound)
        #expect(volume.lowerBound < cost.lowerBound)
        #expect(cost.lowerBound < charts.lowerBound)
    }

    /// Every string this reorganization introduced exists in **both** tables. A key present in one
    /// language only falls back silently to English for half the users — the coverage sentence is the
    /// last place on this screen where that would be acceptable.
    @Test
    func newHierarchyKeysAreLocalizedInBothTables() throws {
        func keys(_ language: String) throws -> Set<String> {
            let source = try Self.source("Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
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

        let introduced: Set<String> = [
            "dashboard.coverage.title",
            "dashboard.coverage.first_day",
            "dashboard.coverage.last_day",
            "dashboard.coverage.days_with",
            "dashboard.coverage.days_without",
            "dashboard.coverage.none",
            "dashboard.coverage.full",
            "dashboard.coverage.partial",
            "dashboard.section.volume",
            "dashboard.section.cost",
            "dashboard.section.charts",
            "dashboard.volume.total",
            "dashboard.volume.avg_covered",
            "dashboard.volume.avg_window",
            "dashboard.avg.divisor_covered",
            "dashboard.avg.divisor_window",
            "dashboard.cost.caveat",
            "dashboard.cost.total",
            "dashboard.cost.today",
            "dashboard.chart.tokens.sub",
            "dashboard.chart.cost.sub",
            "dashboard.models.sub",
            "dashboard.models_by_day.sub",
            "dashboard.projects.sub",
            "dashboard.heatmap.sub",
        ]

        let english = try keys("en")
        let portuguese = try keys("pt-BR")
        #expect(introduced.subtracting(english).isEmpty)
        #expect(introduced.subtracting(portuguese).isEmpty)
    }

    /// Each average names its divisor, in both languages. A label that dropped its `%d` would render
    /// as a bare "divide por dias com dado" — the exact ambiguity the pair of cards exists to remove.
    @Test
    func bothDivisorLabelsCarryTheirNumberPlaceholder() throws {
        for language in ["en", "pt-BR"] {
            let source = try Self.source("Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
            for key in ["dashboard.avg.divisor_covered", "dashboard.avg.divisor_window"] {
                let line = try #require(
                    source.components(separatedBy: .newlines).first { $0.hasPrefix("\"\(key)\"") })
                #expect(line.contains("%d"))
            }
        }
        // And the partial-coverage sentence needs both of its positional arguments.
        for language in ["en", "pt-BR"] {
            let source = try Self.source("Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
            let line = try #require(
                source.components(separatedBy: .newlines)
                    .first { $0.hasPrefix("\"dashboard.coverage.partial\"") })
            #expect(line.contains("%1$d"))
            #expect(line.contains("%2$d"))
        }
    }
}
