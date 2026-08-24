import Foundation

// MARK: - Coverage

/// What the data source actually covers, as opposed to what the window asked for.
///
/// **This is the block that goes at the top of the panel, not in a footnote (D6).** The dashboard
/// zero-fills the whole window, so a 90-day window over a source that begins 55 days ago carries ~35
/// days of `0` that read as "used nothing" instead of "no data". The panel refuses to draw those
/// days at all, and it can only refuse because this type tells it where the data begins.
public struct PainelCobertura: Sendable, Equatable {
    /// Human label of the requested window, e.g. `30 dias`.
    public let janelaRotulo: String
    /// Days the window asked for.
    public let janelaDias: Int
    /// First day that carries data, `nil` when there is none at all.
    public let primeiroDia: Date?
    /// Last day that carries data, `nil` when there is none at all.
    public let ultimoDia: Date?
    /// Distinct days with data — the divisor of every average labelled "por dia com uso".
    public let diasComDado: Int

    public init(
        janelaRotulo: String,
        janelaDias: Int,
        primeiroDia: Date?,
        ultimoDia: Date?,
        diasComDado: Int
    ) {
        self.janelaRotulo = janelaRotulo
        self.janelaDias = janelaDias
        self.primeiroDia = primeiroDia
        self.ultimoDia = ultimoDia
        self.diasComDado = diasComDado
    }

    /// Days of the requested window with no data at all.
    public var diasSemDado: Int { max(0, janelaDias - diasComDado) }

    /// Whether the source reaches as far back as the window asked.
    public var cobreJanelaInteira: Bool { diasComDado >= janelaDias }
}

// MARK: - Series

/// One day of usage. Tokens first, cost second — the panel's ordering rule, applied at the type.
public struct PainelDia: Sendable, Equatable {
    public let dia: Date
    public let entrada: Int
    public let saida: Int
    public let cacheLeitura: Int
    public let cacheEscrita: Int
    public let custoUSD: Double

    public init(
        dia: Date,
        entrada: Int,
        saida: Int,
        cacheLeitura: Int,
        cacheEscrita: Int,
        custoUSD: Double
    ) {
        self.dia = dia
        self.entrada = entrada
        self.saida = saida
        self.cacheLeitura = cacheLeitura
        self.cacheEscrita = cacheEscrita
        self.custoUSD = custoUSD
    }

    /// The sum of the four token kinds.
    ///
    /// Deliberately computed here rather than accepted as an input: the app's own `tokens` field is
    /// `entrada + saída` only, and passing it as a total is how a report ends up disagreeing with
    /// itself between the summary and the chart.
    public var total: Int { entrada + saida + cacheLeitura + cacheEscrita }
}

/// One model's share of the window.
public struct PainelModelo: Sendable, Equatable {
    public let nome: String
    public let tokens: Int
    public let custoUSD: Double

    public init(nome: String, tokens: Int, custoUSD: Double) {
        self.nome = nome
        self.tokens = tokens
        self.custoUSD = custoUSD
    }
}

/// One project's share of the window.
///
/// `nome` is the last path component of the log's `cwd` — that is, **a directory name chosen by
/// whoever created the folder**, which makes it arbitrary text arriving from outside the program.
/// Every path it takes to the page goes through an escape (`PainelEscape`), and that is tested.
public struct PainelProjeto: Sendable, Equatable {
    public let nome: String
    public let tokens: Int
    public let custoUSD: Double

    public init(nome: String, tokens: Int, custoUSD: Double) {
        self.nome = nome
        self.tokens = tokens
        self.custoUSD = custoUSD
    }
}

/// The wide (day × model) block that feeds the stacked chart.
///
/// `valores[d][m]` is the token volume of model `m` on day `d`. A ragged matrix is not representable
/// by accident: the renderer reads it through `valor(dia:modelo:)`, which answers `0` outside bounds
/// rather than trapping on a mismatched fixture.
public struct PainelMatrizModelos: Sendable, Equatable {
    public let dias: [Date]
    public let modelos: [String]
    public let valores: [[Int]]

    public init(dias: [Date], modelos: [String], valores: [[Int]]) {
        self.dias = dias
        self.modelos = modelos
        self.valores = valores
    }

    public func valor(dia: Int, modelo: Int) -> Int {
        guard dia >= 0, dia < valores.count else { return 0 }
        let linha = valores[dia]
        guard modelo >= 0, modelo < linha.count else { return 0 }
        return linha[modelo]
    }

    public static let vazia = PainelMatrizModelos(dias: [], modelos: [], valores: [])
}

// MARK: - KPIs

/// The headline figures. Tokens are the quantity; cost is an estimate of value consumed.
public struct PainelIndicadores: Sendable, Equatable {
    public let tokensTotais: Int
    /// `nil` means "no usage today" — which is **not** the same as zero, and is rendered as words.
    public let tokensHoje: Int?
    public let modeloLiderNome: String?
    public let modeloLiderTokens: Int
    /// Cache hit rate as a fraction (`0.42` renders as 42,0%).
    ///
    /// **The cache figure that survived.** The dollar "saving" the panel used to show next to it was
    /// removed by the owner's decision of 2026-08-24: it priced a counterfactual — a bill for a
    /// scenario that never happened — and its order of magnitude discredited the real numbers beside
    /// it. The rate stays because it is a verifiable fact about traffic that did happen, and it now
    /// travels with the two absolute figures below so a reader can check the division.
    public let taxaAcertoCache: Double
    /// Tokens served from the cache — the numerator behind ``taxaAcertoCache``.
    public let tokensDeCache: Int
    /// Total input-side tokens — the denominator behind ``taxaAcertoCache``.
    ///
    /// Both come from the app rather than being recomputed here, on purpose: a second derivation of
    /// the same ratio is how a panel ends up publishing a percentage that its own two numbers refuse.
    public let tokensDeEntrada: Int
    /// Hour of day with the largest volume, `nil` when there is no usage at all.
    public let horaPico: Int?
    public let custoTotal: Double
    public let custoHoje: Double
    public let projecaoMes: Double

    public init(
        tokensTotais: Int,
        tokensHoje: Int?,
        modeloLiderNome: String?,
        modeloLiderTokens: Int,
        taxaAcertoCache: Double,
        tokensDeCache: Int,
        tokensDeEntrada: Int,
        horaPico: Int?,
        custoTotal: Double,
        custoHoje: Double,
        projecaoMes: Double
    ) {
        self.tokensTotais = tokensTotais
        self.tokensHoje = tokensHoje
        self.modeloLiderNome = modeloLiderNome
        self.modeloLiderTokens = modeloLiderTokens
        self.taxaAcertoCache = taxaAcertoCache
        self.tokensDeCache = tokensDeCache
        self.tokensDeEntrada = tokensDeEntrada
        self.horaPico = horaPico
        self.custoTotal = custoTotal
        self.custoHoje = custoHoje
        self.projecaoMes = projecaoMes
    }
}

// MARK: - The panel's whole input

/// Everything `painel.html` needs, and nothing that belongs to the app's view layer.
///
/// **Why this type exists instead of taking `DashboardData` directly.** `DashboardData` is internal
/// to the `ClaudeBar` app target and carries `SwiftUI`-adjacent concerns; `ClaudeBarCore` cannot see
/// it and should not. The adapter that fills this struct from the dashboard belongs to the app side
/// (`Sources/ClaudeBar/Dashboard/PainelExport.swift`, a later story) — which also means the renderer
/// is testable from a fixture, with no dashboard, no scan and no clock.
public struct PainelData: Sendable, Equatable {
    public let cobertura: PainelCobertura
    public let indicadores: PainelIndicadores
    /// Daily series **as the dashboard produced it**, zero-filled across the whole window.
    ///
    /// The renderer never draws this directly — see ``diarioCoberto``.
    public let diario: [PainelDia]
    public let modelos: [PainelModelo]
    public let projetos: [PainelProjeto]
    public let matrizModelos: PainelMatrizModelos
    /// 7 rows (0 = Sunday) × 24 columns of token volume.
    public let heatmap: [[Int]]

    public init(
        cobertura: PainelCobertura,
        indicadores: PainelIndicadores,
        diario: [PainelDia],
        modelos: [PainelModelo],
        projetos: [PainelProjeto],
        matrizModelos: PainelMatrizModelos,
        heatmap: [[Int]]
    ) {
        self.cobertura = cobertura
        self.indicadores = indicadores
        self.diario = diario
        self.modelos = modelos
        self.projetos = projetos
        self.matrizModelos = matrizModelos
        self.heatmap = heatmap
    }

    // MARK: Derived, and deliberately so

    /// The daily series clipped to the days the source actually covers.
    ///
    /// **This is where "gap, not zero" is enforced (D6)**, and it is enforced here rather than left to
    /// whoever builds the input: a leading run of zeros is indistinguishable from real idleness by
    /// looking at the numbers alone — only ``PainelCobertura/primeiroDia`` knows the difference. Days
    /// **inside** the covered range keep their zeros, because there the zero is true.
    public var diarioCoberto: [PainelDia] {
        guard let inicio = cobertura.primeiroDia else { return [] }
        let fim = cobertura.ultimoDia ?? inicio
        return diario.filter { $0.dia >= inicio && $0.dia <= fim }
    }

    /// The wide matrix clipped by the same rule, so both stacked charts start on the same day.
    public var matrizCoberta: PainelMatrizModelos {
        guard let inicio = cobertura.primeiroDia else { return .vazia }
        let fim = cobertura.ultimoDia ?? inicio
        var dias: [Date] = []
        var valores: [[Int]] = []
        for (indice, dia) in matrizModelos.dias.enumerated() where dia >= inicio && dia <= fim {
            dias.append(dia)
            valores.append(indice < matrizModelos.valores.count ? matrizModelos.valores[indice] : [])
        }
        return PainelMatrizModelos(dias: dias, modelos: matrizModelos.modelos, valores: valores)
    }

    /// Token average over days **with data** — the divisor the coverage block announces.
    public var tokensPorDiaComUso: Double {
        cobertura.diasComDado > 0
            ? Double(indicadores.tokensTotais) / Double(cobertura.diasComDado)
            : 0
    }

    /// Token average over the **requested window**, which is the app's own divisor.
    ///
    /// Both averages are published side by side, each labelled with its divisor. Quietly replacing one
    /// with the other would make the panel disagree with the app's screen without saying why.
    public var tokensPorDiaDaJanela: Double {
        cobertura.janelaDias > 0
            ? Double(indicadores.tokensTotais) / Double(cobertura.janelaDias)
            : 0
    }

    public var custoPorDiaComUso: Double {
        cobertura.diasComDado > 0 ? indicadores.custoTotal / Double(cobertura.diasComDado) : 0
    }

    public var custoPorDiaDaJanela: Double {
        cobertura.janelaDias > 0 ? indicadores.custoTotal / Double(cobertura.janelaDias) : 0
    }

    /// Whether there is anything at all to draw.
    public var vazio: Bool { diarioCoberto.isEmpty && modelos.isEmpty && projetos.isEmpty }
}
