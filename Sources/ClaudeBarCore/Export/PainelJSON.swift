import Foundation

/// A JSON value, emitted by hand.
///
/// **Why not `JSONSerialization`.** Two reasons, both about this file specifically:
///
/// 1. **Key order.** `JSONSerialization` needs `.sortedKeys` to be stable, and even then the order is
///    alphabetical rather than meaningful — `cache_escrita` would come before `dia`. Here the order is
///    the order of the literal, so the block a person opens reads top to bottom like the panel does.
/// 2. **The escape is the point.** The `<`, `>`, `&` and U+2028/29 rules of ``PainelEscape/json(_:)``
///    are not optional decoration; they are what keeps a hostile directory name from closing the
///    `<script>` block. Routing every string through one serialiser makes that one place to audit,
///    and `JSONSerialization` gives no hook to do it.
///
/// Output is compact (no whitespace between tokens): the file is meant to be read by `JSON.parse`,
/// and the human-facing copy of every number is already on the page.
public indirect enum PainelValorJSON: Sendable {
    case texto(String)
    case inteiro(Int)
    case numero(Double)
    case booleano(Bool)
    case nulo
    case lista([PainelValorJSON])
    case objeto([PainelCampoJSON])

    /// Convenience for the many optional strings in the model.
    public static func texto(_ valor: String?) -> PainelValorJSON {
        valor.map { .texto($0) } ?? .nulo
    }

    /// Convenience for the optionals that mean "no usage", which must not collapse into `0`.
    public static func inteiro(_ valor: Int?) -> PainelValorJSON {
        valor.map { .inteiro($0) } ?? .nulo
    }
}

/// One member of a JSON object, keeping declaration order.
public struct PainelCampoJSON: Sendable {
    public let chave: String
    public let valor: PainelValorJSON

    public init(_ chave: String, _ valor: PainelValorJSON) {
        self.chave = chave
        self.valor = valor
    }
}

public enum PainelJSON {
    /// Serialises `valor` into compact JSON, escaping every string for a `<script>` context.
    public static func texto(_ valor: PainelValorJSON) -> String {
        switch valor {
        case let .texto(conteudo):
            "\"\(PainelEscape.json(conteudo))\""
        case let .inteiro(numero):
            String(numero)
        case let .numero(numero):
            PainelFormat.literalJSON(numero)
        case let .booleano(estado):
            estado ? "true" : "false"
        case .nulo:
            "null"
        case let .lista(itens):
            "[" + itens.map(texto).joined(separator: ",") + "]"
        case let .objeto(campos):
            "{" + campos.map { "\"\(PainelEscape.json($0.chave))\":\(texto($0.valor))" }.joined(separator: ",") + "}"
        }
    }

    // MARK: - The panel's payload

    /// The whole data block, in the order the page presents it: coverage, then volume, then cost.
    ///
    /// Only ``PainelData/diarioCoberto`` and ``PainelData/matrizCoberta`` are published — never the
    /// raw zero-filled series. A consumer of this JSON therefore cannot accidentally plot a run of
    /// zeros for days the source never covered, because those days are not in the document at all.
    public static func payload(_ dados: PainelData) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("cobertura", cobertura(dados.cobertura)),
            PainelCampoJSON("indicadores", indicadores(dados)),
            PainelCampoJSON("diario", .lista(dados.diarioCoberto.map(dia))),
            PainelCampoJSON("modelos", .lista(dados.modelos.map(modelo))),
            PainelCampoJSON("projetos", .lista(dados.projetos.map(projeto))),
            PainelCampoJSON("modelos_por_dia", matriz(dados.matrizCoberta)),
            PainelCampoJSON("heatmap", .lista(dados.heatmap.map { linha in .lista(linha.map { .inteiro($0) }) })),
        ])
    }

    private static func cobertura(_ valor: PainelCobertura) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("janela_rotulo", .texto(valor.janelaRotulo)),
            PainelCampoJSON("janela_dias", .inteiro(valor.janelaDias)),
            PainelCampoJSON("primeiro_dia", .texto(valor.primeiroDia.map(PainelDatas.iso))),
            PainelCampoJSON("ultimo_dia", .texto(valor.ultimoDia.map(PainelDatas.iso))),
            PainelCampoJSON("dias_com_dado", .inteiro(valor.diasComDado)),
            PainelCampoJSON("dias_sem_dado", .inteiro(valor.diasSemDado)),
        ])
    }

    private static func indicadores(_ dados: PainelData) -> PainelValorJSON {
        let valor = dados.indicadores
        return .objeto([
            PainelCampoJSON("tokens_totais", .inteiro(valor.tokensTotais)),
            PainelCampoJSON("tokens_hoje", .inteiro(valor.tokensHoje)),
            PainelCampoJSON("tokens_por_dia_com_uso", .numero(dados.tokensPorDiaComUso)),
            PainelCampoJSON("tokens_por_dia_da_janela", .numero(dados.tokensPorDiaDaJanela)),
            PainelCampoJSON("modelo_lider", .texto(valor.modeloLiderNome)),
            PainelCampoJSON("modelo_lider_tokens", .inteiro(valor.modeloLiderTokens)),
            PainelCampoJSON("taxa_acerto_cache", .numero(valor.taxaAcertoCache)),
            PainelCampoJSON("tokens_de_cache", .inteiro(valor.tokensDeCache)),
            PainelCampoJSON("tokens_de_entrada", .inteiro(valor.tokensDeEntrada)),
            PainelCampoJSON("hora_pico", .inteiro(valor.horaPico)),
            PainelCampoJSON("custo_total_usd", .numero(valor.custoTotal)),
            PainelCampoJSON("custo_hoje_usd", .numero(valor.custoHoje)),
            PainelCampoJSON("custo_por_dia_com_uso_usd", .numero(dados.custoPorDiaComUso)),
            PainelCampoJSON("custo_por_dia_da_janela_usd", .numero(dados.custoPorDiaDaJanela)),
            PainelCampoJSON("projecao_mes_usd", .numero(valor.projecaoMes)),
        ])
        // Sem `economia_cache_usd`: o campo saiu do bloco de dados junto com o cartão, e não só da
        // tela. Mantê-lo aqui exportaria o mesmo número contrafactual para a próxima ferramenta que
        // lesse este arquivo — o painel contaria uma história e o JSON dentro dele, outra.
    }

    private static func dia(_ valor: PainelDia) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("dia", .texto(PainelDatas.iso(valor.dia))),
            PainelCampoJSON("tokens_total", .inteiro(valor.total)),
            PainelCampoJSON("tokens_entrada", .inteiro(valor.entrada)),
            PainelCampoJSON("tokens_saida", .inteiro(valor.saida)),
            PainelCampoJSON("cache_leitura", .inteiro(valor.cacheLeitura)),
            PainelCampoJSON("cache_escrita", .inteiro(valor.cacheEscrita)),
            PainelCampoJSON("custo_usd", .numero(valor.custoUSD)),
        ])
    }

    private static func modelo(_ valor: PainelModelo) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("modelo", .texto(valor.nome)),
            PainelCampoJSON("tokens_total", .inteiro(valor.tokens)),
            PainelCampoJSON("custo_usd", .numero(valor.custoUSD)),
        ])
    }

    private static func projeto(_ valor: PainelProjeto) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("projeto", .texto(valor.nome)),
            PainelCampoJSON("tokens_total", .inteiro(valor.tokens)),
            PainelCampoJSON("custo_usd", .numero(valor.custoUSD)),
        ])
    }

    private static func matriz(_ valor: PainelMatrizModelos) -> PainelValorJSON {
        .objeto([
            PainelCampoJSON("dias", .lista(valor.dias.map { .texto(PainelDatas.iso($0)) })),
            PainelCampoJSON("modelos", .lista(valor.modelos.map { .texto($0) })),
            PainelCampoJSON("valores", .lista(valor.dias.indices.map { linha in
                .lista(valor.modelos.indices.map { coluna in .inteiro(valor.valor(dia: linha, modelo: coluna)) })
            })),
        ])
    }
}
