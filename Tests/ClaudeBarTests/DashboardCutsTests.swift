import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-6.4 — fewer blocks, one reading per question, CSV-only export.
struct DashboardCutsTests {
    // MARK: Single metric for the model breakdown

    private let rows = [
        DashboardModelEntry(model: "claude-opus-5-5", inputTokens: 100, outputTokens: 0, costUSD: 9),
        DashboardModelEntry(model: "claude-haiku-5-5", inputTokens: 900, outputTokens: 0, costUSD: 1),
    ]

    @Test
    func donutAndTableShareOneOrder() {
        #expect(ModelMetric.ordenados(rows, por: .tokens).map(\.model) == ["claude-haiku-5-5", "claude-opus-5-5"])
        #expect(ModelMetric.ordenados(rows, por: .custo).map(\.model) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(ModelMetric.custo.valor(rows[0]) == 9)
        #expect(ModelMetric.tokens.valor(rows[0]) == 100)
    }

    // MARK: Pareto as a column

    @Test
    func projectTableCarriesShareAndCumulative() {
        let projetos = [
            ProjectUsageEntry(project: "a", costUSD: 0, totalTokens: 60),
            ProjectUsageEntry(project: "b", costUSD: 0, totalTokens: 30),
            ProjectUsageEntry(project: "c", costUSD: 0, totalTokens: 10),
        ]
        let p = ProjectBreakdownTable.participacoes(projetos)
        #expect(abs((p["a"]?.parte ?? 0) - 0.6) < 1e-9)
        #expect(abs((p["b"]?.acumulado ?? 0) - 0.9) < 1e-9)
        #expect(abs((p["c"]?.acumulado ?? 0) - 1.0) < 1e-9)
        #expect(ProjectBreakdownTable.participacoes([]).isEmpty)
    }

    // MARK: Summary: variation vs the previous stretch

    @Test
    func previousSpanHasTheSameLengthAndEndsTheDayBefore() {
        let cal = Calendar.current
        let hoje = cal.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let span = DashboardSpan.ultimos(7, now: hoje)
        let anterior = span.anterior()
        #expect(anterior.dias() == 7)
        #expect(anterior.fim == cal.date(byAdding: .day, value: -1, to: span.inicio))
    }

    @Test
    func variationNeedsACompletePreviousStretch() {
        let span = DashboardSpan.ultimos(7, now: Date())
        var data = DashboardData.build(
            from: UsageAnalytics(
                byDayModel: [ModelCostEntry(model: "claude-sonnet-4", date: span.fim, inputTokens: 10,
                                            outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 12)],
                byProject: [], heatmap: UsageAnalytics.emptyHeatmap(), topSessions: [],
                monthToDateCost: 12),
            span: span, atalho: .sevenDays, now: Date())
        #expect(data.variacaoVsAnterior == .semBase)
        data.anterior = PeriodoAnterior(custo: 10, tokens: 1, completo: false)
        #expect(data.variacaoVsAnterior == .semBase)
        data.anterior = PeriodoAnterior(custo: 10, tokens: 1, completo: true)
        #expect(data.variacaoVsAnterior == .comparado(0.2))
        #expect(DashboardSummarySection.variacaoTexto(.comparado(0.2)) == "+20%")
        #expect(DashboardSummarySection.variacaoTexto(.comparado(-0.08)) == "−8%")
        #expect(DashboardSummarySection.variacaoTexto(.semBase) == "—")
    }

    @Test
    func previousStretchIsCompleteOnlyWhenEveryDayWasWatched() {
        let cal = Calendar.current
        let fim = cal.startOfDay(for: Date())
        let inicio = cal.date(byAdding: .day, value: -2, to: fim)!
        let dias = Set((0...2).map { cal.date(byAdding: .day, value: -$0, to: fim)! })
        let cheio = UsageAnalytics(byDayModel: [], byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
                                   topSessions: [], monthToDateCost: 0, coveredDays: dias)
        let falho = UsageAnalytics(byDayModel: [], byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
                                   topSessions: [], monthToDateCost: 0, coveredDays: [fim])
        #expect(PeriodoAnterior.de(cheio, intervalo: inicio...fim).completo)
        #expect(!PeriodoAnterior.de(falho, intervalo: inicio...fim).completo)
    }

    // MARK: Export is CSV only

    @MainActor
    @Test
    func exportNamesACSVFile() {
        #expect(DashboardWindowController.nomeDoCSV(recorte: "30d", dia: "2026-11-25") == "claude-usage-30d-2026-11-25.csv")
    }

    /// No workbook writer, panel renderer or package assembler is left in the source tree.
    @Test
    func noSpreadsheetOrHTMLExportRemainsInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("XLSX"), "\(url.lastPathComponent) still mentions XLSX")
            #expect(!text.contains("xlsx"), "\(url.lastPathComponent) still mentions xlsx")
            #expect(!text.contains("PainelHTMLWriter"), "\(url.lastPathComponent) still renders the HTML panel")
        }
        #expect(!FileManager.default.fileExists(atPath: sources.appendingPathComponent("ClaudeBarCore/Export").path))
    }
}
