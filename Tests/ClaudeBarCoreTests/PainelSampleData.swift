import Foundation
@testable import ClaudeBarCore

/// The fixture the panel tests measure and a human opens in a browser.
///
/// It is not the real export — the adapter from `DashboardData` belongs to a later story. What it does
/// carry is every shape that can fail quietly:
///
/// - **eight leading days with no data at all**, so "gap, not zero" has something to clip;
/// - **one zero day inside the covered range**, which must survive as a real zero;
/// - a project named after a `<script>` break-out, because project names are directory names;
/// - names with accents, and one long enough to be truncated on the axis.
///
/// Every value is a fixed constant or comes from a seeded generator, so two renders produce the same
/// bytes — which is what the determinism gate asserts. Since the window start is a **named** date
/// (see ``inicioJanela``) rather than a day derived from a UTC instant, those bytes are also the same
/// under any `TZ`: verified at `fa7f3db8…` under `America/Sao_Paulo`, `Asia/Tokyo` and `UTC`.
enum PainelSampleData {
    /// 2026-08-01, local midnight. Local rather than UTC because the dashboard buckets days with
    /// `Calendar.current`, and the panel formats them the same way.
    ///
    /// **Named as a date, not derived from an instant, and that was a real defect.** This used to be
    /// `startOfDay(for: Date(timeIntervalSince1970: 1_785_542_400))` — the start of day *containing*
    /// a fixed UTC instant, which is a different calendar day depending on where the machine is: 31 July
    /// in São Paulo, 1 August in Tokyo. Measured, it made `painel.html` hash `fdba7a9d…` here and
    /// `fa7f3db8…` under `TZ=Asia/Tokyo` — the one artifact of the package whose bytes moved with the
    /// environment, which would have surfaced as a determinism gate that is green locally and red on a
    /// CI configured in UTC. Naming the date makes the fixture describe the same day everywhere.
    static let inicioJanela: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 8; partes.day = 1
        return Calendar.current.date(from: partes) ?? Date(timeIntervalSince1970: 1_785_542_400)
    }()

    static func dia(_ deslocamento: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: deslocamento, to: inicioJanela) ?? inicioJanela
    }

    /// Days in the requested window.
    static let janelaDias = 30
    /// Index of the first day the source actually covers.
    static let primeiroCoberto = 8
    /// A covered day with genuinely no usage — the zero that must stay a zero.
    static let diaOciosoCoberto = 15

    /// The same hostile string the workbook fixture uses (`ExportSampleWorkbook.hostileProjectName`).
    ///
    /// Repeated as a literal instead of referenced so this fixture can also be compiled on its own,
    /// outside the test target, to produce the sample file. ``PainelHTMLTests`` asserts the two are
    /// still the same string, so a change on either side is caught rather than silently diverging.
    static let nomeHostil = "</script><img src=x onerror=alert(1)> & \"quoted\""

    static let modelos = [
        "claude-opus-4-6",
        "claude-sonnet-4-5",
        "claude-haiku-4-5",
        "claude-opus-4-5-legado-de-nome-bem-comprido",
    ]

    /// A small linear congruential generator: reproducible numbers with no `Foundation` randomness.
    struct Gerador {
        private var estado: UInt64

        init(semente: UInt64) { estado = semente }

        mutating func proximo(ate limite: Int) -> Int {
            estado = estado &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((estado >> 33) % UInt64(max(1, limite)))
        }
    }

    // MARK: - Series

    static func diario() -> [PainelDia] {
        var gerador = Gerador(semente: 20_260_824)
        return (0..<janelaDias).map { deslocamento in
            // Before coverage the dashboard hands over zeros; the panel must not draw them.
            let semDado = deslocamento < primeiroCoberto || deslocamento == diaOciosoCoberto
            let entrada = semDado ? 0 : 60_000 + gerador.proximo(ate: 120_000)
            let saida = semDado ? 0 : 9_000 + gerador.proximo(ate: 20_000)
            let leitura = semDado ? 0 : 200_000 + gerador.proximo(ate: 450_000)
            let escrita = semDado ? 0 : 15_000 + gerador.proximo(ate: 40_000)
            let custo = semDado ? 0 : Double(entrada) * 0.000_012 + Double(saida) * 0.000_060
            return PainelDia(
                dia: dia(deslocamento),
                entrada: entrada,
                saida: saida,
                cacheLeitura: leitura,
                cacheEscrita: escrita,
                custoUSD: custo
            )
        }
    }

    static func matriz() -> PainelMatrizModelos {
        var gerador = Gerador(semente: 777)
        var dias: [Date] = []
        var valores: [[Int]] = []
        for deslocamento in 0..<janelaDias {
            dias.append(dia(deslocamento))
            let semDado = deslocamento < primeiroCoberto || deslocamento == diaOciosoCoberto
            valores.append(modelos.indices.map { indice in
                semDado ? 0 : max(0, (4 - indice) * 40_000 + gerador.proximo(ate: 90_000) - 30_000)
            })
        }
        return PainelMatrizModelos(dias: dias, modelos: modelos, valores: valores)
    }

    static func heatmap() -> [[Int]] {
        var gerador = Gerador(semente: 4_242)
        return (0..<7).map { diaSemana in
            (0..<24).map { hora in
                let ocupado = hora >= 9 && hora <= 21 && diaSemana != 0
                let base = ocupado ? 120_000 : 8_000
                return base + gerador.proximo(ate: ocupado ? 260_000 : 12_000)
            }
        }
    }

    // MARK: - The whole fixture

    static func make() -> PainelData {
        let dias = diario()
        let comDado = dias.filter { $0.total > 0 }
        let totalTokens = dias.reduce(0) { $0 + $1.total }
        let totalCusto = dias.reduce(0) { $0 + $1.custoUSD }
        let entrada = dias.reduce(0) { $0 + $1.entrada }
        let leitura = dias.reduce(0) { $0 + $1.cacheLeitura }

        let cobertura = PainelCobertura(
            janelaRotulo: "30 dias",
            janelaDias: janelaDias,
            primeiroDia: dia(primeiroCoberto),
            ultimoDia: dia(janelaDias - 1),
            diasComDado: comDado.count
        )

        let matrizCompleta = matriz()
        let tokensPorModelo = modelos.indices.map { coluna in
            matrizCompleta.dias.indices.reduce(0) { $0 + matrizCompleta.valor(dia: $1, modelo: coluna) }
        }
        let lider = tokensPorModelo.enumerated().max { $0.element < $1.element }

        // Numerador e denominador da taxa de cache vêm juntos e da mesma soma — é o que permite ao
        // painel publicar a divisão em vez de pedir fé nela.
        let baseDeEntrada = entrada + leitura
        let indicadores = PainelIndicadores(
            tokensTotais: totalTokens,
            tokensHoje: dias.last?.total,
            modeloLiderNome: lider.map { modelos[$0.offset] },
            modeloLiderTokens: lider?.element ?? 0,
            taxaAcertoCache: baseDeEntrada > 0 ? Double(leitura) / Double(baseDeEntrada) : 0,
            tokensDeCache: leitura,
            tokensDeEntrada: baseDeEntrada,
            horaPico: 15,
            custoTotal: totalCusto,
            custoHoje: dias.last?.custoUSD ?? 0,
            projecaoMes: totalCusto * 1.35
        )

        return PainelData(
            cobertura: cobertura,
            indicadores: indicadores,
            diario: dias,
            modelos: modelos.enumerated().map { indice, nome in
                PainelModelo(
                    nome: nome,
                    tokens: tokensPorModelo[indice],
                    custoUSD: Double(tokensPorModelo[indice]) * 0.000_009
                )
            },
            projetos: [
                PainelProjeto(nome: "eximiabar", tokens: 2_140_800, custoUSD: 18.94),
                PainelProjeto(nome: "eximia-academy-v2", tokens: 1_762_400, custoUSD: 15.10),
                PainelProjeto(nome: "JARVIS — orquestração", tokens: 980_300, custoUSD: 8.42),
                PainelProjeto(nome: nomeHostil, tokens: 208_900, custoUSD: 1.90),
                PainelProjeto(nome: "Unknown", tokens: 61_200, custoUSD: 0.54),
            ],
            matrizModelos: matrizCompleta,
            heatmap: heatmap()
        )
    }
}
