import ClaudeBarCore
import Foundation

/// The workbook side of the adapter: `DashboardData` → ``XLSXWorkbook``.
///
/// Split from `PainelExport.swift` because it is the long half and it answers a different question.
/// The panel half decides *what the numbers are*; this half decides *how a spreadsheet presents
/// them* — which sheet, which order, which chart, which cell is blank rather than zero.
///
/// **Eight sheets, not the nine the architecture note designed.** `Fato` — the `(day × model)` grain
/// that a BI tool would model over — is missing because the app throws that grain away inside
/// `DashboardData.build`, keeping only the aggregates the screen draws. The sheet is therefore
/// **absent and declared absent** in `Leia-me`, not present and empty: a sheet with a header and no
/// rows is read by every tool as a measured period of no usage.
///
/// **Six charts, and they are the six the note ordered:** tokens per day and cost per day on
/// `Diario`, volume and share by model on `Modelos`, volume by model and day on `Modelos por dia`,
/// volume by project on `Projetos`. Tokens first in every pair — the owner pays a subscription, so
/// volume is the quantity and the dollar figure is an estimate standing beside it.
extension PainelExport {
    // MARK: - Sheet names

    /// Tab names, in workbook order. Written without accents or punctuation Excel dislikes so the
    /// writer's sanitiser has nothing to change — a tab silently renamed would break every chart
    /// reference that names it.
    enum Aba {
        static let resumo = "Resumo"
        static let diario = "Diario"
        static let modelos = "Modelos"
        static let modelosPorDia = "Modelos por dia"
        static let projetos = "Projetos"
        static let sessoes = "Sessoes"
        static let heatmap = "Heatmap"
        static let leiaMe = "Leia-me"
    }

    /// Fixed Portuguese weekday names, Sunday first, matching `HeatmapBucket.weekday`.
    ///
    /// Fixed rather than `Calendar.shortWeekdaySymbols`: the workbook is a Portuguese document that
    /// travels, and locale-dependent labels would make the same data produce different bytes on two
    /// machines — which also costs the determinism gate its meaning.
    static let nomesDosDias = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"]

    // MARK: - Workbook

    /// The whole workbook for the slice on screen.
    static func planilha(de dados: DashboardData) -> XLSXWorkbook {
        XLSXWorkbook(sheets: [
            abaResumo(dados),
            abaDiario(dados),
            abaModelos(dados),
            abaModelosPorDia(dados),
            abaProjetos(dados),
            abaSessoes(dados),
            abaHeatmap(dados),
            abaLeiaMe(dados),
        ])
    }

    // MARK: - Resumo

    /// The ten-second card: two columns, three blocks, no chart.
    ///
    /// Coverage comes first because a window the source does not cover makes every number under it a
    /// lie; then volume, then cost. Both averages appear side by side, each labelled with its own
    /// divisor — quietly publishing one of them is exactly the defect that let a ~40% error live on
    /// this screen for months.
    static func abaResumo(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = []

        func titulo(_ texto: String) {
            linhas.append([.text(texto, .header), .text("", .header)])
        }
        func linha(_ rotulo: String, _ valor: XLSXCell) {
            linhas.append([.text(rotulo, .normal), valor])
        }
        func vazia() {
            linhas.append([.blank, .blank])
        }

        titulo("Cobertura dos dados")
        linha("Janela pedida", .text(rotuloDaJanela(dados), .normal))
        linha("Primeira data com dado", dados.primeiroDiaComDado.map { XLSXCell.date($0) } ?? .text("—", .normal))
        linha("Última data com dado", dados.ultimoDiaComDado.map { XLSXCell.date($0) } ?? .text("—", .normal))
        linha("Dias com dado", .number(Double(dados.diasComDado), .integer))
        linha("Dias da janela sem dado", .number(Double(dados.diasSemDado), .integer))
        if !dados.cobreJanelaInteira {
            linha(
                "Aviso",
                .text(
                    "A fonte cobre \(dados.diasComDado) dos \(dados.spanDays) dias pedidos. "
                        + "Toda média rotulada \"por dia com uso\" divide por \(dados.diasComDado). "
                        + "Dia anterior ao início dos dados aparece em branco, nunca como zero.",
                    .normal))
        }
        vazia()

        titulo("Volume (grandeza principal)")
        linha("Tokens totais do período", .number(Double(dados.totalTokens), .integer))
        // Named for what it is. `thirtyDayTokens` counts entrada + saída over the whole span — it is
        // neither "thirty days" nor the four-kind total beside it, and a row labelled either way would
        // be an instrument answering a question nobody asked.
        linha("Tokens de entrada e saída no período", .number(Double(dados.thirtyDayTokens), .integer))
        linha("Tokens nos últimos 7 dias", .number(Double(dados.sevenDayTokens), .integer))
        linha(
            "Tokens hoje",
            dados.todayTokens > 0
                ? .number(Double(dados.todayTokens), .integer)
                : .text("sem uso hoje", .normal))
        linha("Média de tokens por dia com uso", .number(dados.tokensPorDiaComUso, .integer))
        linha("Média de tokens por dia da janela", .number(dados.tokensPorDiaDaJanela, .integer))
        linha("Tokens projetados no mês", .number(Double(dados.projectedTokens), .integer))
        linha("Modelo líder por volume", .text(dados.topModelByTokens?.name ?? "—", .normal))
        linha("Tokens do modelo líder", .number(Double(dados.topModelByTokens?.tokens ?? 0), .integer))
        linha("Taxa de acerto de cache", .number(dados.cacheHitRate, .percent))
        // The rate travels with its own numerator and denominator so the division can be checked
        // instead of believed.
        linha("Tokens vindos do cache", .number(Double(dados.tokensDeCache), .integer))
        linha("Tokens de entrada (denominador da taxa)", .number(Double(dados.tokensDeEntrada), .integer))
        linha(
            "Hora de pico",
            dados.totalHeatmapTokens > 0
                ? .number(Double(dados.peakHour), .hour)
                : .text("—", .normal))
        linha("Hoje vs. média por dia com uso", deltaDeHoje(dados))
        vazia()

        titulo("Custo estimado (secundário)")
        linha(
            "O que este bloco é",
            .text(
                "Estimativa de valor consumido. O plano é por assinatura — isto não é fatura.",
                .normal))
        linha("Custo total do período", .number(dados.totalCost, .currency2))
        linha("Custo hoje", .number(dados.todayCost, .currency2))
        linha("Custo nos últimos 7 dias", .number(dados.sevenDayCost, .currency2))
        linha("Custo médio por dia com uso", .number(dados.custoPorDiaComUso, .currency2))
        linha("Custo médio por dia da janela", .number(dados.custoPorDiaDaJanela, .currency2))
        linha("Projeção de custo do mês", .number(dados.monthProjection, .currency2))
        if let caro = dados.busiestDay {
            linha("Dia da semana mais caro", .text(nomesDosDias[safe: caro.dayOfWeek] ?? "—", .normal))
            linha("Custo desse dia da semana", .number(caro.cost, .currency2))
        }

        return XLSXSheet(
            name: Aba.resumo,
            rows: linhas,
            columns: [XLSXColumnWidth(column: 0, width: 38), XLSXColumnWidth(column: 1, width: 30)],
            freezeHeader: false)
    }

    /// Today against the daily average, with the reason in words when there is nothing to compare.
    ///
    /// Writing `0,0%` where there was no usage would assert that today sits exactly on the average.
    /// It is the same category of falsehood as a zero standing in for a day never observed.
    static func deltaDeHoje(_ dados: DashboardData) -> XLSXCell {
        switch dados.dailyDeltaState {
        case let .comparado(fracao): return .number(fracao, .percent)
        case .semUsoHoje: return .text("sem uso hoje", .normal)
        case .cedoDemais: return .text("cedo demais para comparar", .normal)
        case .semBase: return .text("sem base de comparação", .normal)
        }
    }

    // MARK: - Diario

    /// One row per day of the axis, tokens left, cost right, plus the two primary charts.
    static func abaDiario(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = [ExportLabels.diario.map { .text($0, .header) }]
        for dia in dados.dailyCosts {
            guard dia.coberto else {
                // Blank, not zero (D6). The chart is emitted with `dispBlanksAs="gap"`, so the line
                // simply begins where the data begins instead of drawing a plateau of confident zeros
                // over a stretch nobody watched.
                linhas.append([.date(dia.date), .blank, .blank, .blank, .blank, .blank, .blank])
                continue
            }
            let total = dia.inputTokens + dia.outputTokens + dia.cacheReadTokens + dia.cacheWriteTokens
            linhas.append([
                .date(dia.date),
                .number(Double(total), .integer),
                .number(Double(dia.inputTokens), .integer),
                .number(Double(dia.outputTokens), .integer),
                .number(Double(dia.cacheReadTokens), .integer),
                .number(Double(dia.cacheWriteTokens), .integer),
                .number(dia.costUSD, .currency4),
            ])
        }

        let ultimaLinha = linhas.count - 1
        var graficos: [XLSXChart] = []
        if ultimaLinha >= 1 {
            let categorias = XLSXRange(
                sheetName: Aba.diario, firstRow: 1, firstColumn: 0, lastRow: ultimaLinha, lastColumn: 0)
            func serie(coluna: Int) -> XLSXSeries {
                XLSXSeries(
                    nameCell: XLSXRange(sheetName: Aba.diario, row: 0, column: coluna),
                    values: XLSXRange(
                        sheetName: Aba.diario, firstRow: 1, firstColumn: coluna,
                        lastRow: ultimaLinha, lastColumn: coluna))
            }
            graficos = [
                XLSXChart(
                    kind: .columnStacked,
                    title: "Tokens por dia",
                    categories: categorias,
                    series: [serie(coluna: 2), serie(coluna: 3), serie(coluna: 4), serie(coluna: 5)],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: ExportLabels.diario.count)),
                XLSXChart(
                    kind: .line,
                    title: "Custo estimado por dia (USD)",
                    categories: categorias,
                    series: [serie(coluna: 6)],
                    valueNumberFormat: "\"$\"#,##0.0000",
                    anchor: .stacked(index: 1, dataColumns: ExportLabels.diario.count)),
            ]
        }

        return XLSXSheet(
            name: Aba.diario,
            rows: linhas,
            freezeHeader: true,
            table: XLSXTable(name: "TblDiario"),
            charts: graficos)
    }

    // MARK: - Modelos

    static func abaModelos(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = [ExportLabels.modelos.map { .text($0, .header) }]
        for modelo in dados.byModel {
            linhas.append([
                .text(modelo.model, .normal),
                .number(Double(modelo.inputTokens + modelo.outputTokens), .integer),
                .number(Double(modelo.inputTokens), .integer),
                .number(Double(modelo.outputTokens), .integer),
                .number(modelo.costUSD, .currency2),
            ])
        }

        let ultimaLinha = linhas.count - 1
        var graficos: [XLSXChart] = []
        if ultimaLinha >= 1 {
            let categorias = XLSXRange(
                sheetName: Aba.modelos, firstRow: 1, firstColumn: 0, lastRow: ultimaLinha, lastColumn: 0)
            let volume = XLSXSeries(
                nameCell: XLSXRange(sheetName: Aba.modelos, row: 0, column: 1),
                values: XLSXRange(
                    sheetName: Aba.modelos, firstRow: 1, firstColumn: 1,
                    lastRow: ultimaLinha, lastColumn: 1))
            graficos = [
                XLSXChart(
                    kind: .barHorizontal,
                    title: "Volume por modelo",
                    categories: categorias,
                    series: [volume],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: ExportLabels.modelos.count)),
                XLSXChart(
                    kind: .pie,
                    title: "Participação no volume",
                    categories: categorias,
                    series: [volume],
                    anchor: .stacked(index: 1, dataColumns: ExportLabels.modelos.count)),
            ]
        }

        return XLSXSheet(
            name: Aba.modelos,
            rows: linhas,
            freezeHeader: true,
            table: XLSXTable(name: "TblModelos"),
            charts: graficos)
    }

    // MARK: - Modelos por dia

    /// The wide block, materialised as real cells.
    ///
    /// It has to exist as cells: a chart series can only point at a **contiguous** range, so the long
    /// `(dia, modelo, tokens)` form cannot feed a stacked chart at all. The block is the same one the
    /// panel plots (``PainelExport/matriz(de:)``), clipped to the covered days by the same rule, so the
    /// two files of one folder cannot show different breakdowns of the same days.
    static func abaModelosPorDia(_ dados: DashboardData) -> XLSXSheet {
        let matrizCompleta = matriz(de: dados)
        let bloco = PainelData(
            cobertura: cobertura(de: dados),
            indicadores: indicadores(de: dados),
            diario: [],
            modelos: [],
            projetos: [],
            matrizModelos: matrizCompleta,
            heatmap: []
        ).matrizCoberta

        var linhas: [[XLSXCell]] = [
            [.text(ExportLabels.dia, .header)] + bloco.modelos.map { .text($0, .header) },
        ]
        for (indice, dia) in bloco.dias.enumerated() {
            let valores = indice < bloco.valores.count ? bloco.valores[indice] : []
            linhas.append(
                [.date(dia)]
                    + bloco.modelos.indices.map { coluna in
                        .number(Double(coluna < valores.count ? valores[coluna] : 0), .integer)
                    })
        }

        let ultimaLinha = linhas.count - 1
        var graficos: [XLSXChart] = []
        if ultimaLinha >= 1, !bloco.modelos.isEmpty {
            graficos = [
                XLSXChart(
                    kind: .columnStacked,
                    title: "Volume por modelo e dia",
                    categories: XLSXRange(
                        sheetName: Aba.modelosPorDia, firstRow: 1, firstColumn: 0,
                        lastRow: ultimaLinha, lastColumn: 0),
                    series: bloco.modelos.indices.map { indice in
                        let coluna = indice + 1
                        return XLSXSeries(
                            nameCell: XLSXRange(sheetName: Aba.modelosPorDia, row: 0, column: coluna),
                            values: XLSXRange(
                                sheetName: Aba.modelosPorDia, firstRow: 1, firstColumn: coluna,
                                lastRow: ultimaLinha, lastColumn: coluna))
                    },
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: bloco.modelos.count + 1)),
            ]
        }

        return XLSXSheet(
            name: Aba.modelosPorDia,
            rows: linhas,
            freezeHeader: true,
            charts: graficos)
    }

    // MARK: - Projetos

    static func abaProjetos(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = [ExportLabels.projetos.map { .text($0, .header) }]
        for projeto in dados.byProject {
            linhas.append([
                .text(projeto.project, .normal),
                .number(Double(projeto.totalTokens), .integer),
                .number(projeto.costUSD, .currency2),
            ])
        }

        let ultimaLinha = linhas.count - 1
        var graficos: [XLSXChart] = []
        if ultimaLinha >= 1 {
            graficos = [
                XLSXChart(
                    kind: .barHorizontal,
                    title: "Volume por projeto",
                    categories: XLSXRange(
                        sheetName: Aba.projetos, firstRow: 1, firstColumn: 0,
                        lastRow: ultimaLinha, lastColumn: 0),
                    series: [XLSXSeries(
                        nameCell: XLSXRange(sheetName: Aba.projetos, row: 0, column: 1),
                        values: XLSXRange(
                            sheetName: Aba.projetos, firstRow: 1, firstColumn: 1,
                            lastRow: ultimaLinha, lastColumn: 1)),
                    ],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: ExportLabels.projetos.count)),
            ]
        }

        return XLSXSheet(
            name: Aba.projetos,
            rows: linhas,
            freezeHeader: true,
            table: XLSXTable(name: "TblProjetos"),
            charts: graficos)
    }

    // MARK: - Sessoes

    /// The ten most expensive sessions — and the sheet says so, because it is not all of them.
    ///
    /// The selection happens far upstream, in the scanner, which sorts by cost and cuts at ten; the
    /// rest are gone before the dashboard ever sees them. Re-sorting these ten by tokens would produce
    /// "the ten costliest, ordered by volume", a list easy to read as "the ten largest by volume",
    /// which it is not. So the order stays and the subtitle names it.
    static func abaSessoes(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = [
            [.text("As 10 sessões de maior custo estimado, não todas as sessões.", .normal)],
            [
                .text("Sessão", .header),
                .text(ExportLabels.dia, .header),
                .text(ExportLabels.projeto, .header),
                .text("Modelo dominante", .header),
                .text(ExportLabels.tokensTotal, .header),
                .text(ExportLabels.custoEstimado, .header),
            ],
        ]
        for sessao in dados.topSessions {
            linhas.append([
                .text(sessao.sessionId, .normal),
                .date(sessao.date),
                .text(sessao.project, .normal),
                .text(sessao.dominantModel, .normal),
                .number(Double(sessao.totalTokens), .integer),
                .number(sessao.costUSD, .currency2),
            ])
        }
        return XLSXSheet(
            name: Aba.sessoes,
            rows: linhas,
            columns: [XLSXColumnWidth(column: 0, width: 38)],
            freezeHeader: false)
    }

    // MARK: - Heatmap

    /// 7 × 24 with a colour scale instead of a chart: Excel has no heat-map chart type, and
    /// `cfRule type="colorScale"` is the native equivalent — three elements, no extra part.
    static func abaHeatmap(_ dados: DashboardData) -> XLSXSheet {
        let grade = heatmap(de: dados)
        var linhas: [[XLSXCell]] = [
            [.text(ExportLabels.diaDaSemana, .header)]
                + (0..<24).map { .text(String(format: "%02dh", $0), .header) }
                + [.text(ExportLabels.total, .header)],
        ]
        for (indice, nome) in nomesDosDias.enumerated() {
            let valores = indice < grade.count ? grade[indice] : [Int](repeating: 0, count: 24)
            linhas.append(
                [.text(nome, .normal)]
                    + valores.map { .number(Double($0), .integer) }
                    + [.number(Double(valores.reduce(0, +)), .integer)])
        }
        return XLSXSheet(
            name: Aba.heatmap,
            rows: linhas,
            freezeHeader: true,
            colorScale: XLSXColorScaleRule(
                firstRow: 1, firstColumn: 1, lastRow: 7, lastColumn: 24,
                lowColor: "FF111827", highColor: "FFCC7C5E"))
    }

    // MARK: - Leia-me

    /// The caveats, inside the file.
    ///
    /// Mandatory, not decorative. The workbook travels on its own — attached to a message, dropped in
    /// a folder — and a number that arrives without its caveat becomes a wrong fact on somebody else's
    /// slide. `leia-me.txt` in the package says the same things at more length; this sheet is the copy
    /// that goes wherever the `.xlsx` goes.
    static func abaLeiaMe(_ dados: DashboardData) -> XLSXSheet {
        var linhas: [[XLSXCell]] = []
        func titulo(_ texto: String) { linhas.append([.text(texto, .header)]) }
        func texto(_ valor: String) { linhas.append([.text(valor, .normal)]) }
        func vazia() { linhas.append([.blank]) }

        titulo("Como ler esta planilha")
        texto("Gerada pelo exímIABar a partir dos logs locais do Claude Code.")
        texto("Janela: \(rotuloDaJanela(dados))")
        vazia()

        titulo("Cobertura dos dados")
        if let primeiro = dados.primeiroDiaComDado, let ultimo = dados.ultimoDiaComDado {
            texto("A fonte cobre de \(diaCurto(primeiro)) a \(diaCurto(ultimo)).")
        } else {
            texto("A fonte não cobre nenhum dia desta janela.")
        }
        texto("Dias com dado: \(dados.diasComDado) de \(dados.spanDays) pedidos.")
        if !dados.cobreJanelaInteira {
            texto("Toda média rotulada \"por dia com uso\" divide por \(dados.diasComDado), não por \(dados.spanDays).")
            texto("Dia anterior ao início dos dados aparece em branco, nunca como zero:")
            texto("dia sem dado não é o mesmo que dia sem uso.")
        }
        vazia()

        titulo("O custo em USD é estimativa, não é fatura")
        texto("O plano é por assinatura. O dólar aqui estima o valor consumido e serve para comparar")
        texto("modelos, projetos e dias entre si. Não vem da Anthropic e não é a conta a pagar.")
        texto("O cálculo é custo = entrada x preço_entrada + saída x preço_saída.")
        texto("Os tokens de cache entram como VOLUME e nunca são precificados, então somar a coluna")
        texto("de custo SUBCONTA o consumo real. Por isso o token é a grandeza principal e vem primeiro.")
        vazia()

        titulo("O que esta planilha não traz")
        texto("Não há aba Fato (o grão dia x modelo, com custo e separação de cache).")
        texto("O app deriva os agregados que a tela desenha e descarta essas linhas, então não existe")
        texto("número honesto para escrever aqui. Uma aba vazia seria pior que a ausência: uma")
        texto("ferramenta de BI a ingere sem reclamar e reporta um período sem uso nenhum.")
        vazia()

        titulo("Outras ressalvas")
        texto("Sessões: apenas as 10 de maior custo estimado, não todas.")
        texto("Projetos: o nome é o último componente do diretório de trabalho, e vira \"Unknown\" quando")
        texto("o log não traz esse dado. Duas pastas de mesmo nome em caminhos diferentes colapsam numa linha.")
        texto("Dedup: pedaços de streaming são deduplicados por messageId:requestId.")
        if dados.byModel.count > maximoDeColunasDeModelo {
            texto("Modelos por dia: as \(maximoDeColunasDeModelo) maiores colunas por volume aparecem")
            texto("nomeadas e o restante é somado em \"\(rotuloDeOutrosModelos)\", para o gráfico continuar legível.")
        }

        return XLSXSheet(
            name: Aba.leiaMe,
            rows: linhas,
            columns: [XLSXColumnWidth(column: 0, width: 96)],
            freezeHeader: false)
    }
}

// MARK: - Safe indexing

private extension Array {
    /// Element at `index`, or `nil` when out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
