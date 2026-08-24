import ClaudeBarCore
import Foundation

/// Turns what is on the dashboard's screen into the export engine's inputs.
///
/// **Why this file exists at all.** `ClaudeBarCore` holds the whole export engine — the workbook
/// writer, the panel renderer, the tidy CSVs, the package assembler — and it deliberately cannot see
/// `DashboardData`, which is internal to the app target. So the engine takes its own input models
/// (`PainelData`, `XLSXWorkbook`, `CSVTable`, `ExportPackage.Input`) and *somebody* has to fill them.
/// That somebody is here. Until it existed the engine was complete, tested and **unreachable**: the
/// toolbar still called the old `csvExport()` and nothing in the app target so much as named
/// `ExportPackage`. A motor with no shaft to the wheel.
///
/// **Everything is a pure function of the `DashboardData` handed in.** No clock, no scan, no
/// `Bundle`, no defaults: the generation instant and the app version arrive as parameters. That is
/// what lets a test assert byte-for-byte reproducibility, and it is also what makes the rule below
/// checkable.
///
/// **The rule: export what is on screen, not what the window asked for.** The dashboard's range is a
/// `DashboardSpan` the owner may have dragged out of the middle of his own history; the shortcut may
/// be lit or not. Every figure below comes from the `DashboardData` the screen is currently rendering
/// — `dailyCosts`, `byModel`, `byProject`, `heatmap` — so a 7-day view exports seven days. Nothing
/// here re-derives a window from a period constant.
///
/// **Coverage is read, never recomputed.** `primeiroDiaComDado`, `diasSemDado`,
/// `tokensPorDiaDaJanela` and the rest come from `DashboardCobertura`, the same extension the screen
/// itself publishes from. Two independent derivations of one number is how a panel and the screen
/// that exported it end up disagreeing with nobody able to say which is lying — and unlike a
/// divergent label, a divergent number does not catch the eye.
enum PainelExport {
    // MARK: - The window's own label

    /// How the exported artifacts name the slice on screen.
    ///
    /// Written in Portuguese rather than through `L(…)` on purpose: the panel and `leia-me.txt` are
    /// Portuguese documents end to end (their headings live as literals inside `ClaudeBarCore`), so a
    /// label that followed the app's UI language would produce a file speaking two languages at once.
    /// It also keeps the bytes deterministic regardless of the host's locale.
    static func rotuloDaJanela(_ dados: DashboardData) -> String {
        let nome: String
        switch dados.atalho {
        case .sevenDays: nome = "Últimos 7 dias"
        case .thirtyDays: nome = "Últimos 30 dias"
        case .tudo: nome = "Todo o histórico"
        // A dragged range names its dates, because "últimos 30 dias" over a stretch that is not the
        // last 30 days is a file that lies about itself long after anyone remembers dragging it.
        case nil: nome = "Intervalo escolhido"
        }
        return "\(nome) · \(diaCurto(dados.span.inicio)) a \(diaCurto(dados.span.fim)) · \(dados.spanDays) dias"
    }

    /// `dd/MM/yyyy` from calendar components.
    ///
    /// No `DateFormatter`: one would be a non-`Sendable` static under strict concurrency, and its
    /// output would follow the host locale into a file that is Portuguese by construction.
    static func diaCurto(_ data: Date, calendar: Calendar = .current) -> String {
        let partes = calendar.dateComponents([.day, .month, .year], from: data)
        return String(format: "%02d/%02d/%04d", partes.day ?? 0, partes.month ?? 0, partes.year ?? 0)
    }

    // MARK: - Coverage

    /// The coverage block, read from ``DashboardCobertura`` rather than derived a second time.
    ///
    /// The two fields that are not read from there — `janelaDias` and `diasComDado` — are the raw
    /// stored properties the extension itself divides by, so the panel's own
    /// `PainelCobertura.diasSemDado` and `PainelData.tokensPorDiaComUso` land on exactly the numbers
    /// the screen shows. That agreement is asserted, not assumed (`PainelExportTests`).
    static func cobertura(de dados: DashboardData) -> PainelCobertura {
        PainelCobertura(
            janelaRotulo: rotuloDaJanela(dados),
            janelaDias: dados.spanDays,
            primeiroDia: dados.primeiroDiaComDado,
            ultimoDia: dados.ultimoDiaComDado,
            diasComDado: dados.diasComDado)
    }

    // MARK: - Panel

    /// Everything `painel.html` needs.
    static func painel(de dados: DashboardData) -> PainelData {
        PainelData(
            cobertura: cobertura(de: dados),
            indicadores: indicadores(de: dados),
            diario: dados.dailyCosts.map {
                PainelDia(
                    dia: $0.date,
                    entrada: $0.inputTokens,
                    saida: $0.outputTokens,
                    cacheLeitura: $0.cacheReadTokens,
                    cacheEscrita: $0.cacheWriteTokens,
                    custoUSD: $0.costUSD)
            },
            modelos: dados.byModel.map {
                PainelModelo(nome: $0.model, tokens: $0.inputTokens + $0.outputTokens, custoUSD: $0.costUSD)
            },
            projetos: dados.byProject.map {
                PainelProjeto(nome: $0.project, tokens: $0.totalTokens, custoUSD: $0.costUSD)
            },
            matrizModelos: matriz(de: dados),
            heatmap: heatmap(de: dados))
    }

    static func indicadores(de dados: DashboardData) -> PainelIndicadores {
        PainelIndicadores(
            tokensTotais: dados.totalTokens,
            // `nil` means "no usage today", which the panel renders as words. Zero would assert that
            // today is exactly average, and that is a different claim.
            tokensHoje: dados.todayTokens > 0 ? dados.todayTokens : nil,
            modeloLiderNome: dados.topModelByTokens?.name,
            modeloLiderTokens: dados.topModelByTokens?.tokens ?? 0,
            taxaAcertoCache: dados.cacheHitRate,
            tokensDeCache: dados.tokensDeCache,
            tokensDeEntrada: dados.tokensDeEntrada,
            // `peakHour` answers `0` for an all-zero heatmap — a defined default, not a measurement.
            // Publishing it as "hora de pico: 00h" would be an instrument reporting a reading it never took.
            horaPico: dados.totalHeatmapTokens > 0 ? dados.peakHour : nil,
            custoTotal: dados.totalCost,
            custoHoje: dados.todayCost,
            projecaoMes: dados.monthProjection)
    }

    /// The most model columns the wide block will carry before folding the tail into `Outros`.
    ///
    /// Models are normalised upstream (`Pricing.normalize`), so in practice there are three to six and
    /// this never fires. It exists for the window that spans a long history across several model
    /// generations: a stacked chart with thirty series is unreadable, and a spreadsheet column per
    /// model would push the chart anchor off the visible grid.
    static let maximoDeColunasDeModelo = 12
    /// The label the folded tail carries. Kept beside the cap so the two cannot drift apart.
    static let rotuloDeOutrosModelos = "Outros"

    /// The wide `(day × model)` block, over the **whole** day axis.
    ///
    /// Uncovered days are not dropped here: `PainelData.matrizCoberta` clips them by the same coverage
    /// rule the daily series uses, so both stacked charts begin on the same day. Clipping twice, in two
    /// places, is how the two charts would drift apart.
    ///
    /// **One matrix, two artifacts.** The panel and the workbook both plot this block, so it is built
    /// once and shared — including the `Outros` fold. Capping in the workbook alone would give the two
    /// files of one folder different model breakdowns for the same days.
    static func matriz(de dados: DashboardData) -> PainelMatrizModelos {
        let dias = dados.dailyCosts.map(\.date)
        // Already ordered by token volume descending, which is what makes "the first N" the right N.
        let ordenados = dados.sortedModelNames
        guard !ordenados.isEmpty, !dias.isEmpty else { return .vazia }

        let cabem = ordenados.count <= maximoDeColunasDeModelo
        let nomeados = cabem ? ordenados : Array(ordenados.prefix(maximoDeColunasDeModelo))
        let modelos = cabem ? nomeados : nomeados + [rotuloDeOutrosModelos]
        let colunaDeOutros = modelos.count - 1

        var colunaPorModelo: [String: Int] = [:]
        for (indice, nome) in nomeados.enumerated() { colunaPorModelo[nome] = indice }
        var linhaPorDia: [Date: Int] = [:]
        for (indice, dia) in dias.enumerated() { linhaPorDia[dia] = indice }

        var valores = [[Int]](repeating: [Int](repeating: 0, count: modelos.count), count: dias.count)
        for entrada in dados.byDayByModel {
            guard let linha = linhaPorDia[entrada.date] else { continue }
            // A model that lost its own column still counts — it moves into `Outros` rather than
            // vanishing, so the stack keeps summing to the day's real total.
            let coluna = colunaPorModelo[entrada.modelName] ?? (cabem ? nil : colunaDeOutros)
            guard let coluna else { continue }
            valores[linha][coluna] += entrada.tokens
        }
        return PainelMatrizModelos(dias: dias, modelos: modelos, valores: valores)
    }

    /// The 7 × 24 grid as plain integers, indexed by weekday then hour.
    ///
    /// Built by indexing rather than by trusting the incoming order: `HeatmapBucket` carries its own
    /// `weekday` and `hour`, and a grid that assumed positional order would silently transpose itself
    /// if the scanner ever emitted the buckets differently.
    static func heatmap(de dados: DashboardData) -> [[Int]] {
        var grade = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for linha in dados.heatmap {
            for balde in linha where balde.weekday >= 0 && balde.weekday < 7 && balde.hour >= 0 && balde.hour < 24 {
                grade[balde.weekday][balde.hour] += balde.tokens
            }
        }
        return grade
    }

    // MARK: - Tidy CSVs

    /// `dados/diario.csv` — one row per day of the axis, blanks before coverage begins.
    static func tabelaDiaria(de dados: DashboardData) -> CSVTable {
        CSVTable(
            name: "diario",
            header: ExportLabels.diario,
            rows: dados.dailyCosts.map { dia in
                guard dia.coberto else {
                    // A day the archive never watched is empty, never zero. A zero here survives into
                    // the BI model as a measured "consumed nothing"; a blank survives as null.
                    return [.date(dia.date), .blank, .blank, .blank, .blank, .blank, .blank]
                }
                let total = dia.inputTokens + dia.outputTokens + dia.cacheReadTokens + dia.cacheWriteTokens
                return [
                    .date(dia.date),
                    .integer(total),
                    .integer(dia.inputTokens),
                    .integer(dia.outputTokens),
                    .integer(dia.cacheReadTokens),
                    .integer(dia.cacheWriteTokens),
                    .number(dia.costUSD, decimals: 4),
                ]
            })
    }

    /// `dados/modelos.csv`.
    static func tabelaDeModelos(de dados: DashboardData) -> CSVTable {
        CSVTable(
            name: "modelos",
            header: ExportLabels.modelos,
            rows: dados.byModel.map { modelo in
                [
                    .text(modelo.model),
                    .integer(modelo.inputTokens + modelo.outputTokens),
                    .integer(modelo.inputTokens),
                    .integer(modelo.outputTokens),
                    .number(modelo.costUSD, decimals: 4),
                ]
            })
    }

    /// `dados/projetos.csv`.
    static func tabelaDeProjetos(de dados: DashboardData) -> CSVTable {
        CSVTable(
            name: "projetos",
            header: ExportLabels.projetos,
            rows: dados.byProject.map { projeto in
                [.text(projeto.project), .integer(projeto.totalTokens), .number(projeto.costUSD, decimals: 4)]
            })
    }

    // MARK: - The package

    /// Everything ``ExportPackage`` needs to write the folder.
    ///
    /// `fact` is `nil`, and that is a declared absence rather than an oversight: the `(day × model)`
    /// grain with cost and the cache split is thrown away inside `DashboardData.build`, so there is no
    /// honest `fato.csv` to write. `leia-me.txt` says so in words. An empty one would be worse — a BI
    /// tool ingests a header-only CSV without complaint and reports a period of no usage at all.
    static func entradaDoPacote(
        de dados: DashboardData,
        geradoEm: Date,
        versaoDoApp: String) -> ExportPackage.Input
    {
        let painelData = painel(de: dados)
        return ExportPackage.Input(
            generatedAt: geradoEm,
            appVersion: versaoDoApp,
            periodLabel: rotuloDaJanela(dados),
            coverage: ExportPackage.Coverage(
                firstDay: dados.primeiroDiaComDado,
                lastDay: dados.ultimoDiaComDado,
                daysWithData: dados.diasComDado,
                requestedDays: dados.spanDays),
            workbook: XLSXWriter.data(for: planilha(de: dados)),
            panelHTML: PainelHTMLWriter.render(painelData),
            daily: tabelaDiaria(de: dados),
            models: tabelaDeModelos(de: dados),
            projects: tabelaDeProjetos(de: dados),
            fact: nil)
    }
}

// MARK: - Writing to disk

extension PainelExport {
    /// Writes the chosen format at `destino` and returns what to reveal in the Finder.
    ///
    /// Kept here, as a pure-ish function of its arguments, rather than inside the window controller:
    /// this is the part a test can actually run. The controller's job shrinks to choosing a URL and
    /// reporting the outcome — and an export that only exists inside a save-panel callback is an
    /// export nobody can check.
    ///
    /// All three paths are bytes plus one `FileManager` call, no UI and no main-thread work, so the
    /// caller runs them off-main (anti-freeze invariant).
    static func escrever(
        _ dados: DashboardData,
        formato: ExportFormato,
        em destino: URL,
        geradoEm: Date,
        versaoDoApp: String) throws -> URL
    {
        switch formato {
        case .csv:
            try Data(dados.csvExport().utf8).write(to: destino, options: .atomic)
        case .planilha:
            try XLSXWriter.data(for: planilha(de: dados)).write(to: destino, options: .atomic)
        case .pacote:
            let entrada = entradaDoPacote(de: dados, geradoEm: geradoEm, versaoDoApp: versaoDoApp)
            // The engine's own `write(_:under:)` names the folder after the generation date. Here the
            // owner already named it in the save panel, so the files are laid out under the URL he
            // chose — the same file list, at the place he pointed at.
            try FileManager.default.createDirectory(
                at: destino.appendingPathComponent("dados", isDirectory: true),
                withIntermediateDirectories: true)
            for arquivo in ExportPackage.files(for: entrada, destination: destino) {
                try arquivo.contents.write(
                    to: destino.appendingPathComponent(arquivo.relativePath), options: .atomic)
            }
        }
        return destino
    }
}
