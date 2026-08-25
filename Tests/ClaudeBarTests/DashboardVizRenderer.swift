import AppKit
import ClaudeBarCore
import SwiftUI
import Testing
@testable import ClaudeBar

/// Renders the EXB-5.10 representations to PNG so a human can look at them (the one gate no
/// assertion in this repo reaches).
///
/// **Why this exists as a renderer and not as a checklist.** Every claim the four charts make about
/// *values* is pinned by `DashboardRepresentacoesTests`. None of those tests can see whether the
/// curve's knee is legible at 13pt per column, whether ninety dots overplot into mud, or — the one
/// that decides whether G4 is worth shipping at all — whether a hole in the grid actually looks
/// different from a cell at the floor of the ramp. That question is answered by an eye or it is not
/// answered.
///
/// **Why it renders the real views.** Rebuilding the charts inside the harness would produce a
/// picture of a copy: it would look right while the screen looked wrong, which is worse than no
/// picture. So these render the same `struct`s the dashboard composes, at the width the window
/// actually gives them.
///
/// **Opt-in on purpose.** A test that writes files into `/tmp` on every run is a side effect nobody
/// asked for, and one that silently no-ops is worse (a green that means nothing). Gated by a trait,
/// so a normal run reports it as *skipped* rather than as passed:
///
/// ```
/// EXB_VIZ=1 ./Scripts/run-tests.sh --filter DashboardVizRenderer
/// ```
@MainActor
struct DashboardVizRenderer {
    // MARK: - Geometry the Senhor actually gets

    /// Content width inside the window's 760pt floor, minus the scroll view's 20pt padding a side.
    static let larguraUtil: CGFloat = 720
    /// Content width inside one KPI card of the adaptive grid (168pt minimum, 12pt padding a side).
    static let larguraDoCartao: CGFloat = 144

    static let destino = URL(fileURLWithPath: "/tmp/viz-conferencia", isDirectory: true)

    /// `nonisolated` because the `.enabled(if:)` trait evaluates it from a `Sendable` closure, off the
    /// main actor — reading an environment variable needs no isolation anyway.
    nonisolated static var habilitado: Bool {
        ProcessInfo.processInfo.environment["EXB_VIZ"] == "1"
    }

    /// Render at 2× and write a PNG. Returns the pixel size actually produced.
    @discardableResult
    static func escrever(_ view: some View, largura: CGFloat, nome: String) throws -> NSSize {
        let renderer = ImageRenderer(
            content: view
                .frame(width: largura)
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark))
        renderer.scale = 2

        guard let imagem = renderer.nsImage,
              let tiff = imagem.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw VizErro.semImagem(nome)
        }
        try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        try png.write(to: destino.appendingPathComponent("\(nome).png"))
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    enum VizErro: Error { case semImagem(String) }

    // MARK: - Realistic fixtures

    static var calendario: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1
        return cal
    }

    static let hoje = calendario.date(from: DateComponents(year: 2026, month: 8, day: 24))!

    static func dia(_ recuo: Int) -> Date {
        calendario.date(byAdding: .day, value: -recuo, to: hoje)!
    }

    /// A deterministic pseudo-random stream — the shapes have to be the same picture every run, or
    /// two people looking at "the" screenshot are looking at different ones.
    struct Ruido {
        var estado: UInt64
        mutating func proximo() -> Double {
            estado = estado &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((estado >> 11) & 0xF_FFFF) / Double(0x10_0000)
        }
    }

    /// 101 projects on a heavy tail — the distribution the Senhor actually has, not a toy.
    static func projetosReais() -> [ProjectUsageEntry] {
        var ruido = Ruido(estado: 20_260_824)
        return (0 ..< 101).map { indice in
            // Zipf-ish: rank 1 carries orders of magnitude more than rank 100.
            let base = 900_000_000.0 / pow(Double(indice + 1), 1.35)
            let jitter = 0.65 + ruido.proximo() * 0.7
            return ProjectUsageEntry(
                project: "projeto-\(String(format: "%03d", indice))",
                costUSD: 0,
                totalTokens: Int(base * jitter))
        }
    }

    /// A day axis whose volume swings an order of magnitude and whose model mix drifts — the two
    /// things G2 exists to tell apart.
    static func porDiaPorModelo(dias: Int) -> [DailyModelEntry] {
        var ruido = Ruido(estado: 777)
        var linhas: [DailyModelEntry] = []
        for recuo in stride(from: dias - 1, through: 0, by: -1) {
            let data = dia(recuo)
            // Volume: quiet most days, an order-of-magnitude spike every ~11 days.
            let pico = recuo % 11 == 3 ? 9.0 : 1.0
            let volume = (0.4 + ruido.proximo()) * 400_000_000 * pico
            // Mix: drifts from opus-heavy to sonnet-heavy across the window.
            let progresso = Double(dias - 1 - recuo) / Double(max(1, dias - 1))
            let fracaoOpus = 0.70 - 0.50 * progresso
            let fracaoHaiku = 0.08 + 0.10 * ruido.proximo()
            let fracaoSonnet = max(0.05, 1 - fracaoOpus - fracaoHaiku)
            linhas.append(DailyModelEntry(date: data, modelName: "claude-opus-4", tokens: Int(volume * fracaoOpus)))
            linhas.append(DailyModelEntry(date: data, modelName: "claude-sonnet-4", tokens: Int(volume * fracaoSonnet)))
            linhas.append(DailyModelEntry(date: data, modelName: "claude-haiku-4", tokens: Int(volume * fracaoHaiku)))
        }
        return linhas
    }

    /// A right-skewed day axis: mostly ordinary days, a few enormous ones.
    static func eixoDeDias(_ quantidade: Int) -> [DashboardDailyEntry] {
        var ruido = Ruido(estado: 4_242)
        return stride(from: quantidade - 1, through: 0, by: -1).map { recuo in
            let ordinario = 8_000_000.0 + ruido.proximo() * 14_000_000
            let enorme = recuo % 13 == 5 ? 7.5 : 1.0
            let tokens = Int(ordinario * enorme)
            return DashboardDailyEntry(
                date: dia(recuo), costUSD: 0, tokens: tokens,
                inputTokens: tokens, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, coberto: true)
        }
    }

    /// Twelve months with a **hole punched in the middle**, and watched zero days sitting right
    /// beside it. This is the fixture that decides whether G4 ships: if the gap and the zeros are
    /// indistinguishable here, the chart fails the only purpose that justifies it.
    static func anoComBuracoNoMeio() -> [DashboardDailyEntry] {
        var ruido = Ruido(estado: 31_415)
        var saida: [DashboardDailyEntry] = []
        for recuo in stride(from: 364, through: 0, by: -1) {
            // A 24-day blackout roughly five months back: the source watched nothing at all.
            if (150 ... 173).contains(recuo) { continue }
            // Watched zeros: the whole week either side of the blackout, plus every Sunday.
            let dataDoDia = dia(recuo)
            let ehDomingo = calendario.component(.weekday, from: dataDoDia) == 1
            let coladoNoBuraco = (143 ... 149).contains(recuo) || (174 ... 180).contains(recuo)
            let tokens: Int
            if ehDomingo || coladoNoBuraco {
                tokens = 0
            } else {
                let base = 3_000_000.0 + ruido.proximo() * 40_000_000
                let pico = recuo % 17 == 2 ? 12.0 : 1.0
                tokens = Int(base * pico)
            }
            saida.append(DashboardDailyEntry(
                date: dataDoDia, costUSD: 0, tokens: tokens,
                inputTokens: tokens, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, coberto: true))
        }
        return saida
    }

    /// A `DashboardData` carrying the fixtures above, for the whole-screen renders.
    static func dados(dias: Int) -> DashboardData {
        let porDiaModelo = porDiaPorModelo(dias: dias)
        let entradas: [ModelCostEntry] = porDiaModelo.map {
            ModelCostEntry(
                model: $0.modelName, date: $0.date,
                inputTokens: Int(Double($0.tokens) * 0.18),
                outputTokens: Int(Double($0.tokens) * 0.07),
                cacheReadTokens: Int(Double($0.tokens) * 0.70),
                cacheWriteTokens: Int(Double($0.tokens) * 0.05),
                cost: Double($0.tokens) / 1_000_000 * 0.9)
        }
        let analytics = UsageAnalytics(
            byDayModel: entradas,
            byProject: projetosReais(),
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: 120,
            coveredDays: Set((0 ..< dias).map(dia)))
        // Built through the range door rather than a shortcut: the toolbar only offers 7 / 30 / all,
        // and the 90-day case the Senhor asked to see is a dragged range, not a button.
        return DashboardData.build(
            from: analytics,
            span: .ultimos(dias, now: hoje, calendar: calendario),
            atalho: dias == 30 ? .thirtyDays : nil,
            now: hoje)
    }

    // MARK: - The renders

    @Test(.enabled(if: DashboardVizRenderer.habilitado,
                   "set EXB_VIZ=1 to write PNGs into /tmp/viz-conferencia"))
    func renderizaAsQuatroRepresentacoes() throws {
        var escritos: [String: NSSize] = [:]

        // G1 — the curve over the real 101-project tail.
        let curva = ParetoCurva(projetos: Self.projetosReais())
        escritos["g1-pareto"] = try Self.escrever(
            ProjectParetoChart(curva: curva), largura: Self.larguraUtil, nome: "g1-pareto")

        // G2 — the same chart in both states of its own toggle, so the alternation is comparable.
        let dados30 = Self.dados(dias: 30)
        escritos["g2-absoluto"] = try Self.escrever(
            ModelsByDayChart(data: dados30, modoInicial: .absoluto),
            largura: Self.larguraUtil, nome: "g2-absoluto")
        escritos["g2-proporcao"] = try Self.escrever(
            ModelsByDayChart(data: dados30, modoInicial: .proporcao),
            largura: Self.larguraUtil, nome: "g2-proporcao")

        // G3 — the strip at the width it really gets inside a card, at both window sizes.
        //
        // Fed from the SAME `DashboardData` the rest of these renders use, not from a distribution
        // invented for this strip. A fixture written to suit one chart is a fixture that can be
        // tuned until the chart looks good, which is the opposite of what a conference render is for.
        for dias in [21, 90] {
            let distribuicao = DistribuicaoDiaria(
                dias: Self.dados(dias: dias).diasCobertos,
                hoje: Self.hoje, calendar: Self.calendario)
            escritos["g3-\(dias)d"] = try Self.escrever(
                DiaEntreParesStrip(distribuicao: distribuicao),
                largura: Self.larguraDoCartao, nome: "g3-hoje-entre-pares-\(dias)d")
        }

        // G4 — the year with a blackout in the middle and watched zeros beside it.
        let grade = CalendarioAnual(
            entradas: Self.anoComBuracoNoMeio(), fim: Self.hoje, calendar: Self.calendario)
        escritos["g4-calendario"] = try Self.escrever(
            AnnualCalendarChart(grade: grade), largura: Self.larguraUtil, nome: "g4-calendario")

        // The volume grid, which is what the layout question is actually about: the today card grew
        // from ~84pt to fit the strip, and `LazyVGrid` sizes a row by its tallest member.
        //
        // Rendering the whole `DashboardView` would have been the obvious way to show this and does
        // NOT work: its content is a `LazyVStack` inside a `ScrollView`, and `ImageRenderer` draws
        // only the toolbar — a 1552×5232 PNG of empty background. A blank picture presented as
        // evidence is worse than no picture, so the section is rendered directly instead.
        for dias in [30, 90] {
            escritos["volume-\(dias)d"] = try Self.escrever(
                VolumeSection(data: Self.dados(dias: dias), hoje: Self.hoje),
                largura: Self.larguraUtil, nome: "layout-secao-volume-\(dias)d")
        }

        for (nome, tamanho) in escritos.sorted(by: { $0.key < $1.key }) {
            print("VIZ \(nome): \(Int(tamanho.width))×\(Int(tamanho.height))px")
            #expect(tamanho.width > 0 && tamanho.height > 0, "\(nome) rendered empty")
        }
        #expect(escritos.count == 8)
    }

    /// The render seam must not change what ships. `ModelsByDayChart(data:)` — the call the screen
    /// makes — has to keep opening in absolute mode.
    @Test
    func theRenderSeamPreservesTheShippingDefault() throws {
        let fonte = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ClaudeBar/Dashboard/DashboardView.swift"),
            encoding: .utf8)

        #expect(fonte.contains("modoInicial: ModoComposicao = .absoluto"))
        // And the screen still calls it without an argument, so the default is the shipped path.
        #expect(fonte.contains("ModelsByDayChart(data: data)"))
        #expect(!fonte.contains("ModelsByDayChart(data: data, modoInicial:"))
    }
}
