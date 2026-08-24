import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-6.8 — the adapter that connects the export engine to the dashboard, and the save panel that
/// offers its three formats.
///
/// **What was broken before this story, and what these tests are actually guarding.** The engine in
/// `ClaudeBarCore/Export/` was complete and covered by 86 tests, and *nothing in the app called it*.
/// Every one of those tests measured a fixture. So the tests below measure the other half: that real
/// `DashboardData` — the slice on the owner's screen — turns into the engine's inputs without losing
/// the range, the coverage, or the difference between a zero and a blank.
struct PainelExportTests {
    // MARK: - Fixture

    /// A fixed instant, so every day boundary and every average is reproducible.
    static let agora: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 8; partes.day = 24; partes.hour = 15
        return Calendar.current.date(from: partes)!
    }()

    static func dia(_ deslocamento: Int) -> Date {
        let calendario = Calendar.current
        return calendario.date(
            byAdding: .day, value: deslocamento, to: calendario.startOfDay(for: agora))!
    }

    /// A project name that is also a `</script>` break-out, because project names are directory names
    /// on the owner's disk and nothing stops him from creating that folder.
    static let nomeHostil = "</script><img src=x onerror=alert(1)>"

    /// The archive covers the last **eight** days. Day −3 is inside coverage and idle — its zero is a
    /// measured zero, and it must not be confused with the days before coverage began.
    static func analytics() -> UsageAnalytics {
        var linhas: [ModelCostEntry] = []
        for deslocamento in [-7, -6, -5, -4, -2, -1, 0] {
            linhas.append(ModelCostEntry(
                model: "claude-opus-4-6", date: dia(deslocamento),
                inputTokens: 12_000 + abs(deslocamento) * 100,
                outputTokens: 3_000,
                cacheReadTokens: 40_000,
                cacheWriteTokens: 5_000,
                cost: 1.25))
            linhas.append(ModelCostEntry(
                model: "claude-sonnet-4-5", date: dia(deslocamento),
                inputTokens: 6_000,
                outputTokens: 1_500,
                cacheReadTokens: 18_000,
                cacheWriteTokens: 2_000,
                cost: 0.30))
        }

        var heatmap = UsageAnalytics.emptyHeatmap()
        heatmap[3][14] = HeatmapBucket(weekday: 3, hour: 14, tokens: 90_000)
        heatmap[5][9] = HeatmapBucket(weekday: 5, hour: 9, tokens: 40_000)

        return UsageAnalytics(
            byDayModel: linhas,
            byProject: [
                ProjectUsageEntry(project: "eximiabar", costUSD: 7.4, totalTokens: 480_000),
                ProjectUsageEntry(project: nomeHostil, costUSD: 3.1, totalTokens: 210_000),
                ProjectUsageEntry(project: "Unknown", costUSD: 0.4, totalTokens: 30_000),
            ],
            heatmap: heatmap,
            topSessions: [
                SessionUsageEntry(
                    sessionId: "sess-1", date: dia(-1), project: "eximiabar",
                    dominantModel: "claude-opus-4-6", totalTokens: 120_000, costUSD: 2.2),
                SessionUsageEntry(
                    sessionId: "sess-2", date: dia(-4), project: nomeHostil,
                    dominantModel: "claude-sonnet-4-5", totalTokens: 60_000, costUSD: 0.9),
            ],
            monthToDateCost: 40.0,
            monthToDateTokens: 3_000_000,
            coveredDays: Set((-7...0).map { dia($0) }))
    }

    /// The dashboard as it would be on screen for `dias` days ending today.
    static func painel(dias: Int) -> DashboardData {
        DashboardData.build(
            from: analytics(),
            span: .ultimos(dias, now: agora),
            atalho: dias == 7 ? .sevenDays : .thirtyDays,
            now: agora)
    }

    static func pastaTemporaria() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-painel-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The rule: export what is on screen

    /// **The gate of this story.** Two different slices go through the same adapter and come out
    /// different, each one describing itself correctly.
    ///
    /// This is the assertion that dies if the adapter ever stops reading the `DashboardData` it was
    /// handed — a hardcoded window, a re-derived period, a stale cache. It was proven by mutation:
    /// making `cobertura(de:)` announce a fixed 30-day window turned the 7-day half red
    /// (`janelaDias` 30 ≠ 7) while every other test in this file stayed green, which is what tells us
    /// this test is the one measuring the range.
    @Test
    func oRecorteExportadoEOQueEstaNaTela() {
        let curto = Self.painel(dias: 7)
        let longo = Self.painel(dias: 30)

        let coberturaCurta = PainelExport.cobertura(de: curto)
        let coberturaLonga = PainelExport.cobertura(de: longo)

        #expect(coberturaCurta.janelaDias == 7)
        #expect(coberturaLonga.janelaDias == 30)
        #expect(coberturaCurta.janelaDias != coberturaLonga.janelaDias)

        // The daily axis is the screen's axis, day for day.
        #expect(PainelExport.painel(de: curto).diario.count == 7)
        #expect(PainelExport.painel(de: longo).diario.count == 30)
        #expect(PainelExport.painel(de: curto).diario.first?.dia == curto.span.inicio)
        #expect(PainelExport.painel(de: curto).diario.last?.dia == curto.span.fim)

        // And the totals are the screen's totals, not a re-aggregation that could drift.
        #expect(PainelExport.indicadores(de: curto).tokensTotais == curto.totalTokens)
        #expect(PainelExport.indicadores(de: longo).tokensTotais == longo.totalTokens)

        // The seven-day slice is fully covered; the thirty-day one is not, and says so.
        #expect(coberturaCurta.cobreJanelaInteira)
        #expect(!coberturaLonga.cobreJanelaInteira)
        #expect(coberturaLonga.diasComDado == 8)
        #expect(coberturaLonga.diasSemDado == 22)
    }

    /// The label the artifacts carry names the slice, and a dragged range names its dates rather than
    /// borrowing a shortcut's name.
    @Test
    func oRotuloDaJanelaNomeiaOQueFoiExportado() {
        let atalho = Self.painel(dias: 7)
        #expect(PainelExport.rotuloDaJanela(atalho).contains("Últimos 7 dias"))
        #expect(PainelExport.rotuloDaJanela(atalho).contains("7 dias"))

        let arrastado = DashboardData.build(
            from: Self.analytics(),
            span: DashboardSpan(inicio: Self.dia(-5), fim: Self.dia(-2)),
            atalho: nil,
            now: Self.agora)
        let rotulo = PainelExport.rotuloDaJanela(arrastado)
        #expect(rotulo.contains("Intervalo escolhido"))
        #expect(!rotulo.contains("Últimos 30 dias"))
        #expect(rotulo.contains(PainelExport.diaCurto(Self.dia(-5))))
        #expect(rotulo.contains(PainelExport.diaCurto(Self.dia(-2))))
    }

    // MARK: - Convergence with the screen's own derivations

    /// The panel publishes the same figures the screen does, because it divides with the same
    /// divisors — not because two derivations happen to agree today.
    ///
    /// `DashboardCobertura` is where the screen's coverage block and averages come from. If the
    /// adapter re-derived any of them, the app and the file it exported could publish different
    /// numbers for the same quantity, and no test on either side would see it: a divergent label
    /// catches the eye, a divergent number does not.
    @Test
    func oPainelConcordaComAsDerivacoesDaTela() {
        let dados = Self.painel(dias: 30)
        let painel = PainelExport.painel(de: dados)

        #expect(painel.cobertura.primeiroDia == dados.primeiroDiaComDado)
        #expect(painel.cobertura.ultimoDia == dados.ultimoDiaComDado)
        #expect(painel.cobertura.diasComDado == dados.diasComDado)
        #expect(painel.cobertura.janelaDias == dados.spanDays)
        #expect(painel.cobertura.diasSemDado == dados.diasSemDado)
        #expect(painel.cobertura.cobreJanelaInteira == dados.cobreJanelaInteira)

        // The four averages, each against the screen's own version of itself.
        #expect(abs(painel.tokensPorDiaComUso - dados.tokensPorDiaComUso) < 0.000_001)
        #expect(abs(painel.tokensPorDiaDaJanela - dados.tokensPorDiaDaJanela) < 0.000_001)
        #expect(abs(painel.custoPorDiaComUso - dados.custoPorDiaComUso) < 0.000_001)
        #expect(abs(painel.custoPorDiaDaJanela - dados.custoPorDiaDaJanela) < 0.000_001)

        // The two averages really are different on this fixture — a convergence test over two numbers
        // that happen to be equal proves nothing about the divisors.
        #expect(painel.tokensPorDiaComUso > painel.tokensPorDiaDaJanela)
    }

    // MARK: - Blank is not zero

    /// A day before coverage is empty; an idle day inside coverage keeps its zero.
    ///
    /// The two are indistinguishable by looking at the numbers — both carry no tokens and no cost —
    /// so only the coverage flag can tell them apart. Collapsing them is the defect that made a
    /// 90-day window draw thirty-five bars of confident zero over a stretch nobody watched.
    @Test
    func diaSemCoberturaSaiEmBrancoEDiaOciosoCobertoSaiZero() throws {
        let dados = Self.painel(dias: 30)
        let tabela = PainelExport.tabelaDiaria(de: dados)

        // Asserted with `#require` before anything indexes into the rows: a plain `#expect` on the
        // count would report the real defect and then crash the *whole run* on the next subscript,
        // hiding every test after it. Measured, not supposed — a mutation that shortened this table
        // did exactly that.
        try #require(tabela.rows.count == 30)

        // Day 0 of the axis is 29 days ago — long before the archive begins.
        let primeira = tabela.rows[0]
        #expect(primeira.dropFirst().allSatisfy { $0 == .blank })

        // Day −3 is inside coverage and had no usage: a measured zero, written as zero.
        let indiceOcioso = try #require(dados.dailyCosts.firstIndex { $0.date == Self.dia(-3) })
        #expect(dados.dailyCosts[indiceOcioso].coberto)
        #expect(tabela.rows[indiceOcioso][1] == .integer(0))

        // And the panel refuses to draw anything before coverage at all.
        let painel = PainelExport.painel(de: dados)
        #expect(painel.diarioCoberto.count == 8)
        #expect(painel.diarioCoberto.first?.dia == dados.primeiroDiaComDado)
    }

    // MARK: - The workbook

    @Test
    func aPlanilhaTrazAsAbasEOsSeisGraficos() {
        let planilha = PainelExport.planilha(de: Self.painel(dias: 30))

        #expect(planilha.sheets.map(\.name) == [
            "Resumo", "Diario", "Modelos", "Modelos por dia", "Projetos", "Sessoes", "Heatmap", "Leia-me",
        ])
        // Six charts, the six the architecture note ordered.
        #expect(planilha.sheets.reduce(0) { $0 + $1.charts.count } == 6)
        // Tokens first in every pair: the primary chart of the daily sheet plots volume, not money.
        #expect(planilha.sheets[1].charts.first?.title == "Tokens por dia")
        #expect(planilha.sheets[1].charts.first?.series.count == 4)
        // The heat map is a colour scale, because Excel has no heat-map chart type.
        #expect(planilha.sheets[6].colorScale != nil)
        // Named tables are the ingestion contract for the BI navigator, not decoration.
        #expect(planilha.sheets[1].table?.name == "TblDiario")

        // `Fato` is absent, and the workbook says so in words rather than shipping an empty sheet a
        // BI tool would ingest as a period of no usage.
        #expect(!planilha.sheets.contains { $0.name == "Fato" })
        let leiaMe = Self.texto(daAba: planilha.sheets[7])
        #expect(leiaMe.contains("Não há aba Fato"))
        #expect(leiaMe.contains("SUBCONTA"))
    }

    /// The workbook's `Resumo` publishes both averages, each labelled with its own divisor.
    @Test
    func oResumoPublicaAsDuasMediasComOsDoisDivisores() {
        let planilha = PainelExport.planilha(de: Self.painel(dias: 30))
        let resumo = Self.texto(daAba: planilha.sheets[0])

        #expect(resumo.contains("Média de tokens por dia com uso"))
        #expect(resumo.contains("Média de tokens por dia da janela"))
        #expect(resumo.contains("Custo médio por dia com uso"))
        #expect(resumo.contains("Custo médio por dia da janela"))
        #expect(resumo.contains("A fonte cobre 8 dos 30 dias pedidos."))
        #expect(resumo.contains("isto não é fatura"))
    }

    /// The bytes really are a workbook: the ZIP signature is there and the writer emitted a package.
    @Test
    func aPlanilhaGeraBytesDeUmPacoteReal() {
        let bytes = XLSXWriter.data(for: PainelExport.planilha(de: Self.painel(dias: 30)))
        #expect(bytes.count > 4_000)
        #expect(Array(bytes.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - The panel

    /// The exported panel makes **no** network request — asserted on the real adapter's output, not on
    /// a fixture.
    ///
    /// This is the owner's hard requirement turned into a command: a file that fetches anything is a
    /// file that stops working offline, and in two years stops working at all.
    @Test
    func oPainelExportadoNaoFazNenhumaRequisicaoDeRede() throws {
        let html = PainelHTMLWriter.render(PainelExport.painel(de: Self.painel(dias: 30)))
        let padrao = try NSRegularExpression(
            pattern: "https?://|<script src|<link |@import|fetch\\(|XMLHttpRequest|integrity=")
        let ocorrencias = padrao.numberOfMatches(
            in: html, range: NSRange(html.startIndex..., in: html))
        #expect(ocorrencias == 0)
    }

    /// A project named after a `</script>` break-out survives as data and never as markup — measured
    /// on what the **adapter** produces, not on a fixture.
    ///
    /// The name comes from a directory on the owner's disk, so this is not hypothetical: it is a file
    /// he opens by double-clicking. Three assertions, because the architecture note records that any
    /// one of them alone passes a half-removed defence — the literal `</script>` disappears from the
    /// data block by a mere change of shape when the neighbouring escape rule survives.
    ///
    /// Note what is deliberately **not** asserted: that the string `onerror=alert(1)` is absent from
    /// the page. It is present, and correctly so — as inert text inside a `<title>`, with its angle
    /// brackets escaped. Demanding its absence would be demanding that the export delete the owner's
    /// data instead of quoting it.
    @Test
    func nomeDeProjetoHostilNaoEscapaParaAMarcacao() throws {
        let html = PainelHTMLWriter.render(PainelExport.painel(de: Self.painel(dias: 30)))

        // (a) no raw markup anywhere on the page.
        #expect(!html.contains("<img"))
        // (b) the payload cannot close the data block.
        let bloco = try Self.blocoDeDados(html)
        #expect(!bloco.contains("</script>"))
        // (c) round trip: the datum is quoted, not corrupted and not dropped.
        let raiz = try #require(
            try JSONSerialization.jsonObject(with: Data(bloco.utf8)) as? [String: Any])
        let projetos = try #require(raiz["projetos"] as? [[String: Any]])
        #expect(projetos.contains { $0["projeto"] as? String == Self.nomeHostil })
    }

    /// Two renders of the same slice produce the same bytes.
    @Test
    func oPainelEDeterministico() {
        let dados = Self.painel(dias: 30)
        #expect(PainelHTMLWriter.render(PainelExport.painel(de: dados))
            == PainelHTMLWriter.render(PainelExport.painel(de: dados)))
    }

    // MARK: - The package

    @Test
    func oPacoteTrazAsPecasQuePromete() throws {
        let raiz = Self.pastaTemporaria().appendingPathComponent("exportacao", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: raiz.deletingLastPathComponent()) }

        _ = try PainelExport.escrever(
            Self.painel(dias: 30), formato: .pacote, em: raiz,
            geradoEm: Self.agora, versaoDoApp: "2.5.0")

        let gerenciador = FileManager.default
        for relativo in [
            "painel.html", "planilha.xlsx", "dados/diario.csv", "dados/modelos.csv",
            "dados/projetos.csv", "conectar-powerbi.pbids", "leia-me.txt",
        ] {
            #expect(
                gerenciador.fileExists(atPath: raiz.appendingPathComponent(relativo).path),
                "faltou \(relativo) no pacote")
        }

        // The package carries the slice on screen, day for day: header plus thirty days. Asserted on
        // the file that was written, not on the model that produced it — the package is the artifact
        // the owner opens, and it is the last place a wrong range could still be introduced.
        let diario = try String(
            contentsOf: raiz.appendingPathComponent("dados/diario.csv"), encoding: .utf8)
        #expect(diario.split(separator: "\r\n").count == 31)

        // Declared absence, not an empty file: the fine grain does not exist in the app, and a
        // header-only `fato.csv` is ingested without complaint and read as a period of no usage.
        #expect(!gerenciador.fileExists(atPath: raiz.appendingPathComponent("dados/fato.csv").path))
        let leiaMe = try String(contentsOf: raiz.appendingPathComponent("leia-me.txt"), encoding: .utf8)
        #expect(leiaMe.contains("fato.csv NAO foi gerado"))
        #expect(leiaMe.contains("SUBCONTAR"))
        #expect(leiaMe.contains("Dias com dado: 8 de 30"))

        // The connection file is valid JSON pointing at the folder beside it.
        let pbids = try Data(contentsOf: raiz.appendingPathComponent("conectar-powerbi.pbids"))
        let json = try JSONSerialization.jsonObject(with: pbids) as? [String: Any]
        #expect(json?["version"] as? String == "0.1")
        #expect(pbids.count > 0)
    }

    /// The daily CSV of the package carries the same days the panel drew, with the same totals.
    ///
    /// The gate that stops the two pieces of one folder from telling different stories: they are built
    /// by different code paths from the same `DashboardData`, and nothing but this comparison would
    /// notice if one of them started reading a different slice.
    @Test
    func oPainelEOCSVDoPacoteConcordamDiaADia() throws {
        let dados = Self.painel(dias: 30)
        let painel = PainelExport.painel(de: dados)
        let tabela = PainelExport.tabelaDiaria(de: dados)

        // Same reason as above: the count is the precondition of every comparison below it.
        try #require(painel.diario.count == tabela.rows.count)
        for (indice, dia) in painel.diario.enumerated() {
            let linha = tabela.rows[indice]
            #expect(linha[0] == .date(dia.dia))
            guard dados.dailyCosts[indice].coberto else { continue }
            #expect(linha[1] == .integer(dia.total))
            #expect(linha[2] == .integer(dia.entrada))
            #expect(linha[5] == .integer(dia.cacheEscrita))
        }
    }

    // MARK: - The three formats

    @Test
    func osTresFormatosGravamOQuePrometem() throws {
        let pasta = Self.pastaTemporaria()
        defer { try? FileManager.default.removeItem(at: pasta) }
        let dados = Self.painel(dias: 30)

        let csv = pasta.appendingPathComponent("uso.csv")
        _ = try PainelExport.escrever(
            dados, formato: .csv, em: csv, geradoEm: Self.agora, versaoDoApp: "2.5.0")
        let textoCSV = try String(contentsOf: csv, encoding: .utf8)
        #expect(textoCSV.hasPrefix("date,cost_usd,"))
        // Header plus one line per day of the slice on screen — the CSV path keeps the range too.
        #expect(textoCSV.split(separator: "\n").count == 31)

        let xlsx = pasta.appendingPathComponent("uso.xlsx")
        _ = try PainelExport.escrever(
            dados, formato: .planilha, em: xlsx, geradoEm: Self.agora, versaoDoApp: "2.5.0")
        #expect(Array(try Data(contentsOf: xlsx).prefix(2)) == [0x50, 0x4B])

        let pacote = pasta.appendingPathComponent("pacote", isDirectory: true)
        _ = try PainelExport.escrever(
            dados, formato: .pacote, em: pacote, geradoEm: Self.agora, versaoDoApp: "2.5.0")
        #expect(FileManager.default.fileExists(atPath: pacote.appendingPathComponent("painel.html").path))
    }

    /// A write that cannot land raises instead of vanishing.
    ///
    /// The old export swallowed its error inside a `try?` with the panel already dismissed. For a
    /// ninety-line CSV that was survivable; for a folder of five artifacts it becomes "cadê meu
    /// arquivo?" with nothing to answer it.
    @Test
    func falhaDeGravacaoNaoESilenciosa() {
        let inexistente = URL(fileURLWithPath: "/nao/existe/esta/pasta/uso.csv")
        #expect(throws: (any Error).self) {
            try PainelExport.escrever(
                Self.painel(dias: 7), formato: .csv, em: inexistente,
                geradoEm: Self.agora, versaoDoApp: "2.5.0")
        }
    }

    // MARK: - The suggested file name

    @Test
    func oNomeSugeridoSegueOFormatoEPreservaOQueODonoDigitou() {
        let padraoCSV = ExportNome.padrao(formato: .csv, recorte: "30d", dia: "2026-08-24")
        #expect(padraoCSV == "claude-usage-30d-2026-08-24.csv")
        #expect(ExportNome.padrao(formato: .planilha, recorte: "30d", dia: "2026-08-24")
            == "claude-usage-30d-2026-08-24.xlsx")
        #expect(ExportNome.padrao(formato: .pacote, recorte: "30d", dia: "2026-08-24")
            == "exportacao-eximiabar-2026-08-24")

        // The app's own proposal is replaced wholesale — the package's stem is not the single files'.
        #expect(ExportNome.aoTrocar(
            de: .csv, para: .pacote, nomeAtual: padraoCSV, recorte: "30d", dia: "2026-08-24")
            == "exportacao-eximiabar-2026-08-24")

        // What the owner typed is his: only the extension moves.
        #expect(ExportNome.aoTrocar(
            de: .csv, para: .planilha, nomeAtual: "agosto.csv", recorte: "30d", dia: "2026-08-24")
            == "agosto.xlsx")
        #expect(ExportNome.aoTrocar(
            de: .planilha, para: .pacote, nomeAtual: "agosto.xlsx", recorte: "30d", dia: "2026-08-24")
            == "agosto")
    }

    /// Every format announces itself: a label and a line saying what will actually be written.
    @Test
    func cadaFormatoSeExplica() {
        for formato in ExportFormato.allCases {
            #expect(!formato.rotulo.isEmpty)
            #expect(!formato.explicacao.isEmpty)
            // A missing key falls back to the raw key, which would read as `dashboard.export.…`.
            #expect(!formato.rotulo.hasPrefix("dashboard."))
            #expect(!formato.explicacao.hasPrefix("dashboard."))
        }
        #expect(ExportFormato.csv.extensao == "csv")
        #expect(ExportFormato.planilha.extensao == "xlsx")
        // The package is a folder and carries no extension — constraining the field would make the
        // panel append one to a directory name.
        #expect(ExportFormato.pacote.extensao == nil)
        #expect(ExportFormato.pacote.tiposPermitidos.isEmpty)
        #expect(!ExportFormato.planilha.tiposPermitidos.isEmpty)
    }

    // MARK: - Helpers

    /// The JSON the page carries, as text: everything between the data block's tags.
    static func blocoDeDados(_ html: String) throws -> String {
        let abertura = "<script id=\"dados\" type=\"application/json\">"
        let inicio = try #require(html.range(of: abertura))
        let fim = try #require(html.range(of: "</script>", range: inicio.upperBound..<html.endIndex))
        return String(html[inicio.upperBound..<fim.lowerBound])
    }

    /// Every text cell of a sheet, joined — enough to assert that a sentence reached the file.
    static func texto(daAba aba: XLSXSheet) -> String {
        aba.rows
            .flatMap { $0 }
            .compactMap { celula in
                if case let .text(valor, _) = celula { return valor }
                return nil
            }
            .joined(separator: "\n")
    }
}
