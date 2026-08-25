import AppKit
import ClaudeBarCore
import SwiftUI
import Testing
@testable import ClaudeBar

/// Renders the EXB-6.1 representations to PNG so a human can look at them — the gate no assertion in
/// this repo reaches.
///
/// **Reuses `DashboardVizRenderer` rather than restating it.** The `ImageRenderer` seam, the 720pt
/// content width, the `EXB_VIZ` trait and the deterministic noise stream all live there; duplicating
/// any of them would mean two renderers that could disagree about what "the width the Senhor gets"
/// is, and the conference picture would stop being a picture of the screen.
///
/// ```
/// EXB_VIZ=1 ./Scripts/run-tests.sh --filter DashboardVizRendererDimensoes
/// ```
@MainActor
struct DashboardVizRendererDimensoes {
    // MARK: - Fixtures

    /// 208 sessions on the shape this archive really has: a heavy tail of ordinary work plus a
    /// handful of monsters. The count is the measured one — 208, not the ~2 075 file count that was
    /// mistaken for it (≈10 files per session).
    static func sessoesReais() -> [SessionUsageEntry] {
        var ruido = DashboardVizRenderer.Ruido(estado: 6_102_026)
        var saida: [SessionUsageEntry] = []
        for indice in 0 ..< 198 {
            // Log-uniform between ~120k and ~26M: the ordinary day's work, spread over four buckets.
            let expoente = 5.1 + ruido.proximo() * 2.3
            let tokens = Int(pow(10.0, expoente))
            saida.append(SessionUsageEntry(
                sessionId: "sessao-\(String(format: "%03d", indice))",
                date: DashboardVizRenderer.dia(indice % 90),
                project: "projeto-\(String(format: "%03d", indice % 12))",
                dominantModel: "claude-sonnet-4",
                totalTokens: tokens,
                costUSD: Double(tokens) / 1_000_000 * 0.9))
        }
        for indice in 0 ..< 10 {
            let tokens = Int(38_000_000.0 + ruido.proximo() * 90_000_000)
            saida.append(SessionUsageEntry(
                sessionId: "monstro-\(indice)",
                date: DashboardVizRenderer.dia(indice * 7),
                project: "projeto-\(String(format: "%03d", indice))",
                dominantModel: "claude-opus-4",
                totalTokens: tokens,
                costUSD: Double(tokens) / 1_000_000 * 3.2))
        }
        return saida
    }

    /// The histogram over those sessions, built exactly as the fold would build it.
    static func histograma(_ sessoes: [SessionUsageEntry]) -> HistogramaDeSessoes {
        var baldes = [Int](repeating: 0, count: UsageAnalytics.sessionTokenBucketCount)
        for sessao in sessoes {
            baldes[UsageAnalytics.sessionTokenBucketIndex(forTokens: sessao.totalTokens)] += 1
        }
        let ordenadasPorCusto = sessoes.sorted { $0.costUSD > $1.costUSD }
        let porTokens = sessoes.map(\.totalTokens).sorted()
        let meio = porTokens.count / 2
        let mediana = porTokens.count.isMultiple(of: 2)
            ? (porTokens[meio - 1] + porTokens[meio]) / 2
            : porTokens[meio]
        return HistogramaDeSessoes(
            buckets: baldes,
            mediana: mediana,
            total: sessoes.count,
            topo: Array(ordenadasPorCusto.prefix(10)),
            sessoes: ordenadasPorCusto)
    }

    static let projetos = [
        "eximia-academy-v2", "JARVIS", "eximiabar", "sabiah",
        "crm-eximia", "marcador", "mission-control", "harven-ai",
    ]

    /// Per-`(day, project)` rows across July (whole) and August (through the 25th) — **the geometry
    /// the cascade exists to survive**. Rates change per project; the calendar does not.
    static func julhoEAgosto() -> [DayProjectEntry] {
        var ruido = DashboardVizRenderer.Ruido(estado: 88_112)
        var linhas: [DayProjectEntry] = []
        let cal = DashboardVizRenderer.calendario
        // Per-project daily rate in July, and the multiplier it moved by in August.
        let taxas: [Double] = [42, 28, 19, 12, 8.5, 6, 3.5, 2].map { $0 * 1_000_000 }
        let fatores: [Double] = [1.62, 0.55, 1.18, 0.92, 1.9, 0.4, 1.05, 1.0]
        for (mes, dias) in [(7, 1 ... 31), (8, 1 ... 25)] {
            for dia in dias {
                guard let data = cal.date(from: DateComponents(year: 2026, month: mes, day: dia))
                else { continue }
                for (indice, projeto) in projetos.enumerated() {
                    let fator = mes == 8 ? fatores[indice] : 1.0
                    let jitter = 0.72 + ruido.proximo() * 0.56
                    linhas.append(DayProjectEntry(
                        day: data, project: projeto,
                        totalTokens: Int(taxas[indice] * fator * jitter),
                        costUSD: taxas[indice] * fator / 1_000_000))
                }
                // The archive's own aggregate: everything outside the eight ranked bands.
                linhas.append(DayProjectEntry(
                    day: data, project: "",
                    totalTokens: Int(5_400_000 * (0.7 + ruido.proximo() * 0.6)),
                    costUSD: 5.4, isOthers: true))
            }
        }
        return linhas
    }

    static func cobertura() -> [MonthCoverage] {
        let cal = DashboardVizRenderer.calendario
        return [
            MonthCoverage(
                month: cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!,
                daysInMonth: 31, daysInRange: 31, daysCovered: 31),
            MonthCoverage(
                month: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                daysInMonth: 31, daysInRange: 25, daysCovered: 25),
        ]
    }

    /// A 90-day per-`(day, project)` axis whose composition **drifts**: two projects rise, one dies
    /// off, the rest hold. Which is the only thing the flow chart is there to reveal.
    static func noventaDiasPorProjeto() -> [DayProjectEntry] {
        var ruido = DashboardVizRenderer.Ruido(estado: 5_309)
        var linhas: [DayProjectEntry] = []
        for recuo in stride(from: 89, through: 0, by: -1) {
            let data = DashboardVizRenderer.dia(recuo)
            let progresso = Double(89 - recuo) / 89
            for (indice, projeto) in projetos.enumerated() {
                let base: Double
                switch indice {
                case 0: base = 12_000_000 + 34_000_000 * progresso          // sobe muito
                case 1: base = 26_000_000 * (1 - 0.85 * progresso)          // morre
                case 2: base = 6_000_000 + 14_000_000 * progresso           // sobe
                // Held flat, and deliberately never zero: at `14 - indice * 2` the eighth project
                // came out at exactly 0 tokens every day, so it had no band at all and the render was
                // quietly a picture of eight bands while claiming nine.
                default: base = Double(16 - indice * 2) * 1_400_000         // segura
                }
                let jitter = 0.62 + ruido.proximo() * 0.8
                let tokens = Int(Swift.max(0, base * jitter))
                guard tokens > 0 else { continue }
                linhas.append(DayProjectEntry(
                    day: data, project: projeto,
                    totalTokens: tokens, costUSD: Double(tokens) / 1_000_000))
            }
            linhas.append(DayProjectEntry(
                day: data, project: "",
                totalTokens: Int(4_200_000 * (0.6 + ruido.proximo() * 0.9)),
                costUSD: 4.2, isOthers: true))
        }
        return linhas
    }

    // MARK: - The renders

    @Test(.enabled(if: DashboardVizRenderer.habilitado,
                   "set EXB_VIZ=1 to write PNGs into /tmp/viz-conferencia"))
    func renderizaAsTresRepresentacoesNovas() throws {
        var escritos: [String: NSSize] = [:]

        // V1 — 208 sessions, ten of them monsters, at the width the window really gives.
        let sessoes = Self.sessoesReais()
        escritos["v1-sessoes"] = try DashboardVizRenderer.escrever(
            SessionSizeHistogramChart(histograma: Self.histograma(sessoes)),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v1-distribuicao-sessoes")

        // V1 with a band open — the array's half of the contract, which no still picture would show
        // otherwise: a hover names the sessions the bar counts, with project and dominant model.
        // Opened on the band the monsters live in, which is the one a reader would reach for.
        let faixaDosMonstros = UsageAnalytics.sessionTokenBucketIndex(forTokens: 60_000_000)
        escritos["v1-nomes"] = try DashboardVizRenderer.escrever(
            SessionSizeHistogramChart(
                histograma: Self.histograma(sessoes), faixaInicial: faixaDosMonstros),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v1-distribuicao-sessoes-nomes")

        // V1 again over a thin window — the state the Senhor sees on a fresh install, where the
        // chart has to say the count in words instead of drawing a distribution from one bar.
        escritos["v1-magro"] = try DashboardVizRenderer.escrever(
            SessionSizeHistogramChart(histograma: Self.histograma(Array(sessoes.prefix(1)))),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v1-distribuicao-sessoes-magra")

        // V2 — July whole against August through the 25th: the geometry that fabricates a fall, drawn
        // by a chart that refuses to fabricate it.
        let cascata = CascataMensal(
            porDiaProjeto: Self.julhoEAgosto(),
            cobertura: Self.cobertura(),
            rotuloDeOutros: L("dashboard.cascade.others"),
            calendar: DashboardVizRenderer.calendario)
        escritos["v2-cascata"] = try DashboardVizRenderer.escrever(
            MonthlyCascadeChart(cascata: cascata),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v2-cascata-mensal")

        // V2's refusal, rendered too: a guard nobody can read is indistinguishable from "no usage",
        // so the empty state has to be looked at as carefully as the chart.
        let recusada = CascataMensal(
            porDiaProjeto: Self.julhoEAgosto(),
            cobertura: [
                Self.cobertura()[0],
                MonthCoverage(
                    month: DashboardVizRenderer.calendario
                        .date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                    daysInMonth: 31, daysInRange: 25, daysCovered: 2),
            ],
            rotuloDeOutros: L("dashboard.cascade.others"),
            calendar: DashboardVizRenderer.calendario)
        escritos["v2-recusa"] = try DashboardVizRenderer.escrever(
            MonthlyCascadeChart(cascata: recusada),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v2-cascata-recusa")

        // V3 — ninety days of drifting composition, nine bands, at 720pt.
        let fluxo = FluxoDeProjetos(
            porDiaProjeto: Self.noventaDiasPorProjeto(),
            rankeados: Self.projetos,
            projetosAgregados: 93,
            rotuloDoAgregado: L("dashboard.flow.others"))
        escritos["v3-fluxo"] = try DashboardVizRenderer.escrever(
            ProjectFlowChart(fluxo: fluxo),
            largura: DashboardVizRenderer.larguraUtil,
            nome: "v3-fluxo-projetos")

        for (nome, tamanho) in escritos.sorted(by: { $0.key < $1.key }) {
            print("VIZ \(nome): \(Int(tamanho.width))×\(Int(tamanho.height))px")
            #expect(tamanho.width > 0 && tamanho.height > 0, "\(nome) rendered empty")
        }
        #expect(escritos.count == 6)

        // The fixtures have to contain what the renders claim to show, or the pictures are of
        // something else. Checked here rather than trusted, because a fixture that quietly lost its
        // shape produces a perfectly pretty chart of nothing in particular.
        #expect(cascata.vaiDesenhar)
        #expect(recusada.recusa != nil)
        #expect(fluxo.bandas.count == 9)          // eight ranked plus the aggregate
        #expect(fluxo.dias.count == 90)
        #expect(Self.histograma(sessoes).totalDeSessoes == 208)
        // The band the tooltip was opened on has names to show — otherwise that PNG is a picture of
        // an empty box presented as evidence of a feature.
        #expect(Self.histograma(sessoes).nomes(naFaixa: faixaDosMonstros).isEmpty == false)
    }

    /// The render seam must not change what ships: the screen opens the histogram with **no** band
    /// selected, and `faixaInicial` exists only for the conference render.
    ///
    /// Same shape as `DashboardVizRenderer.theRenderSeamPreservesTheShippingDefault`, for the same
    /// reason — a seam added for a picture is a seam that can quietly become the product.
    @Test
    func theHistogramRenderSeamPreservesTheShippingDefault() throws {
        let fonte = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ClaudeBar/Dashboard/DashboardView.swift"),
            encoding: .utf8)

        #expect(fonte.contains("faixaInicial: Int? = nil"))
        #expect(fonte.contains("SessionSizeHistogramChart(histograma: HistogramaDeSessoes(data: data))"))
        #expect(!fonte.contains("SessionSizeHistogramChart(histograma: HistogramaDeSessoes(data: data), faixaInicial:"))
    }
}
