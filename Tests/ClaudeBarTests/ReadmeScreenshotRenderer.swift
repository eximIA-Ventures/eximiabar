import AppKit
@testable import ClaudeBarCore
import SwiftUI
import Testing
@testable import ClaudeBar

/// Renders the README screenshots (`docs/images/*.png`) from the real SwiftUI views with
/// **fictitious** sample data — no account, e-mail, token or transcript of the person running it
/// ever reaches a picture. Same technique as `DashboardVizRenderer`, opt-in so a normal run skips:
///
/// ```
/// EXB_README=1 ./Scripts/run-tests.sh --filter ReadmeScreenshotRenderer
/// ```
@MainActor
struct ReadmeScreenshotRenderer {
    nonisolated static var habilitado: Bool {
        ProcessInfo.processInfo.environment["EXB_README"] == "1"
    }

    /// `<repo>/docs/images`, resolved from this file so the run directory does not matter.
    static var destino: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo
            .appendingPathComponent("docs/images", isDirectory: true)
    }

    static let hoje = DashboardVizRenderer.hoje
    static let calendario = DashboardVizRenderer.calendario

    @discardableResult
    static func escrever(_ view: some View, largura: CGFloat, nome: String) throws -> NSSize {
        let renderer = ImageRenderer(
            content: view
                .frame(width: largura)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let imagem = renderer.nsImage,
              let tiff = imagem.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw DashboardVizRenderer.VizErro.semImagem(nome) }
        try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        try png.write(to: destino.appendingPathComponent("\(nome).png"))
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// 30 days of usage over today's models, with a drifting mix and occasional spikes.
    static func dados(dias: Int) -> DashboardData {
        var ruido = DashboardVizRenderer.Ruido(estado: 55)
        let mix: [(String, Double)] = [
            ("claude-opus-5-5", 0.46), ("claude-sonnet-5-5", 0.34),
            ("claude-fable-5-2", 0.12), ("claude-haiku-5-5", 0.08),
        ]
        var entradas: [ModelCostEntry] = []
        for recuo in stride(from: dias - 1, through: 0, by: -1) {
            let data = DashboardVizRenderer.dia(recuo)
            let pico = recuo % 9 == 4 ? 3.2 : 1.0
            let volume = (0.5 + ruido.proximo()) * 9_000_000 * pico
            for (modelo, fracao) in mix {
                let tokens = volume * fracao * (0.8 + 0.4 * ruido.proximo())
                let input = Int(tokens * 0.04), output = Int(tokens * 0.03)
                let cacheRead = Int(tokens * 0.85), cacheWrite = Int(tokens * 0.08)
                let preco = Pricing.fallbackTable[modelo]!
                entradas.append(ModelCostEntry(
                    model: modelo, date: data,
                    inputTokens: input, outputTokens: output,
                    cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                    cost: preco.cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)))
            }
        }
        let projetos = ["web-app", "api-gateway", "mobile", "data-pipeline", "docs-site", "infra"]
            .enumerated().map { indice, nome in
                ProjectUsageEntry(project: nome, costUSD: 0, totalTokens: 90_000_000 / (indice + 1))
            }
        let analytics = UsageAnalytics(
            byDayModel: entradas,
            byProject: projetos,
            heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [],
            monthToDateCost: entradas.reduce(0) { $0 + $1.cost },
            coveredDays: Set((0 ..< dias).map(DashboardVizRenderer.dia)))
        return DashboardData.build(
            from: analytics,
            span: .ultimos(dias, now: hoje, calendar: calendario),
            atalho: dias == 30 ? .thirtyDays : dias == 5 ? .sinceReset : nil,
            now: hoje)
    }

    /// Two accounts, focus on the second one: its reading came from the CLI fallback and part of its
    /// cost was priced by family, so every number carries `~` and the header names the bar's account.
    static func multiAccountWorkspace() -> (WorkspaceSnapshot, DisplaySnapshot) {
        let agora = Date()
        let hora: TimeInterval = 3600
        let live = AccountIdentity(key: AccountKey(provider: .claude, identifier: "alex@example.com"),
                                   email: "alex@example.com", displayName: "Alex Example")
        let work = AccountIdentity(key: AccountKey(provider: .claude, identifier: "team@example.com"),
                                   email: "team@example.com", displayName: "Team Account")
        let estimado = DisplaySnapshot(
            session: RateWindow(utilization: 78, resetsAt: agora.addingTimeInterval(1.5 * hora), windowMinutes: 300),
            weekly: RateWindow(utilization: 34, resetsAt: agora.addingTimeInterval(4 * 24 * hora), windowMinutes: 10080),
            cost: ProviderCost(today: 4.10, last30Days: 96.40, todayTokens: 820_000, last30DaysTokens: 20_000_000,
                               estimatedTokens: 2_400_000),
            plan: .pro,
            identity: .init(name: "Team Account", email: "team@example.com"),
            updatedAt: agora,
            source: .cli)
        let workspace = WorkspaceSnapshot(
            accounts: [
                .init(identity: live, lifecycle: .live, display: popoverSnapshot(), status: .live),
                .init(identity: work, lifecycle: .live, display: estimado, status: .live),
            ],
            menuBarKey: live.key,
            updatedAt: agora).withFocus(work.key)
        return (workspace, estimado)
    }

    /// A fictitious week: four projects, the main session and four sub-agents, 61 p.p. consumed.
    static func semana() -> SemanaAtribuida {
        func fatias(_ pares: [(String, Double)]) -> [WeeklyAttribution.Slice] {
            let total = pares.reduce(0) { $0 + $1.1 }
            return pares.map { .init(name: $0.0, weight: $0.1, tokens: Int($0.1 * 1_000_000), share: $0.1 / total) }
        }
        let inicio = calendario.date(byAdding: .day, value: -4, to: calendario.startOfDay(for: hoje))!
        return SemanaAtribuida(
            atribuicao: WeeklyAttribution(
                since: inicio,
                byProject: fatias([("web-app", 41), ("api-gateway", 22), ("data-pipeline", 9), ("docs-site", 4)]),
                byAgent: fatias([(WeeklyAttribution.mainAgentName, 38), ("code-reviewer", 19), ("test-runner", 11),
                                 ("explorer", 6), (WeeklyAttribution.unnamedSubagentName, 2)]),
                totalWeight: 76),
            pontosConsumidos: 61,
            inicioConhecido: true)
    }

    static func popoverSnapshot(ultra: Bool = false) -> DisplaySnapshot {
        let agora = Date()
        let hora: TimeInterval = 3600
        return DisplaySnapshot(
            session: ultra ? nil
                : RateWindow(utilization: 42, resetsAt: agora.addingTimeInterval(2.4 * hora), windowMinutes: 300),
            weekly: RateWindow(utilization: 61, resetsAt: agora.addingTimeInterval(3 * 24 * hora), windowMinutes: 10080),
            opus: RateWindow(utilization: 37, resetsAt: agora.addingTimeInterval(3 * 24 * hora), windowMinutes: 10080),
            cost: ProviderCost(today: 12.48, last30Days: 318.90, todayTokens: 2_410_000, last30DaysTokens: 61_300_000),
            plan: ultra ? .ultra : .max,
            identity: .init(name: "Alex Example", email: "alex@example.com"),
            updatedAt: agora,
            sparklineSamples: [8, 12, 15, 19, 22, 26, 30, 31, 35, 38, 40, 42])
    }

    @Test(.enabled(if: ReadmeScreenshotRenderer.habilitado,
                   "set EXB_README=1 to write the README screenshots into docs/images"))
    func renderizaOsPrintsDoReadme() throws {
        var escritos: [String: NSSize] = [:]
        escritos["popover"] = try Self.escrever(
            UsageCardView(snapshot: Self.popoverSnapshot(), actions: UsageCardActions()),
            largura: PopoverStyle.panelWidth, nome: "popover")
        escritos["popover-ultra"] = try Self.escrever(
            UsageCardView(snapshot: Self.popoverSnapshot(ultra: true), actions: UsageCardActions()),
            largura: PopoverStyle.panelWidth, nome: "popover-ultra")
        let (workspace, focado) = Self.multiAccountWorkspace()
        escritos["popover-multi-account"] = try Self.escrever(
            UsageCardView(snapshot: focado, actions: UsageCardActions(), workspace: workspace),
            largura: PopoverStyle.panelWidth, nome: "popover-multi-account")
        var semanal = Self.dados(dias: 5)
        semanal.semana = Self.semana()
        semanal.anterior = PeriodoAnterior(custo: semanal.totalCost / 1.18, tokens: 1, completo: true)
        escritos["since-reset"] = try Self.escrever(
            VStack(alignment: .leading, spacing: 20) {
                DashboardSummarySection(data: semanal)
                WeeklyAttributionSection(semana: semanal.semana!)
            },
            largura: 720, nome: "dashboard-since-reset")
        let dados = Self.dados(dias: 30)
        escritos["models"] = try Self.escrever(
            ModelBreakdownSection(data: dados, metrica: .custo, mostraSeletor: false), largura: 720, nome: "dashboard-models")
        escritos["by-day"] = try Self.escrever(
            ModelsByDayChart(data: dados, modoInicial: .absoluto, mostraSeletor: false), largura: 720, nome: "dashboard-models-by-day")
        for (nome, tamanho) in escritos.sorted(by: { $0.key < $1.key }) {
            print("README \(nome): \(Int(tamanho.width))×\(Int(tamanho.height))px")
            #expect(tamanho.width > 0 && tamanho.height > 0, "\(nome) rendered empty")
        }
    }
}
