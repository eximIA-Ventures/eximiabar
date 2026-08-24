import Foundation

/// Renders `painel.html` — one self-contained file, offline, with the charts already drawn.
///
/// **What this file is for.** The owner asked to export "para modelos de análise de dados, de forma
/// que ele já venha com gráficos". Power BI Desktop cannot serve that request on a Mac (§4.1 of the
/// architecture note), so the house draws the charts itself. The result opens with two clicks, needs
/// no application installed, works with scripting disabled, and makes no network request — which is
/// also why it will still open in two years.
///
/// **Order of the page is a decision, not a layout.** Coverage first, because a window the source
/// does not cover is the one thing that makes every number below it a lie; then tokens, because the
/// plan is a subscription and tokens are the quantity actually consumed; then cost, labelled as an
/// estimate of value rather than a bill.
public enum PainelHTMLWriter {
    /// The finished document.
    public static func render(_ dados: PainelData) -> String {
        PainelTemplate.pagina(
            corpo: corpo(dados),
            dados: PainelJSON.texto(PainelJSON.payload(dados))
        )
    }

    /// The finished document as UTF-8 bytes, for writing to disk.
    public static func bytes(_ dados: PainelData) -> Data {
        Data(render(dados).utf8)
    }

    // MARK: - Body

    static func corpo(_ dados: PainelData) -> String {
        [
            cabecalho(dados),
            blocoCobertura(dados),
            blocoVolume(dados),
            blocoCusto(dados),
            blocoGraficos(dados),
            rodape(),
        ].joined(separator: "\n")
    }

    static func cabecalho(_ dados: PainelData) -> String {
        """
        <header>
        <h1>Uso do Claude Code</h1>
        <p class="janela">Janela pedida: \(PainelEscape.marcacao(dados.cobertura.janelaRotulo)) · \
        exportado pelo exímIABar · tokens são a grandeza principal desta página</p>
        </header>
        """
    }

    // MARK: Coverage — the block that has to come first

    static func blocoCobertura(_ dados: PainelData) -> String {
        let cobertura = dados.cobertura
        let primeiro = cobertura.primeiroDia.map(PainelDatas.longa) ?? "—"
        let ultimo = cobertura.ultimoDia.map(PainelDatas.longa) ?? "—"
        let aviso: String
        if cobertura.primeiroDia == nil {
            aviso = "<p class=\"aviso\">A fonte não cobre nenhum dia desta janela. "
                + "Nenhum gráfico abaixo desenha dado que não existe.</p>"
        } else if cobertura.cobreJanelaInteira {
            aviso = "<p class=\"aviso completa\">A fonte cobre a janela inteira.</p>"
        } else {
            aviso = "<p class=\"aviso\">A fonte cobre \(PainelFormat.inteiro(cobertura.diasComDado)) "
                + "dos \(PainelFormat.inteiro(cobertura.janelaDias)) dias pedidos. "
                + "Os gráficos começam na primeira data com dado — dia sem dado é lacuna, não zero.</p>"
        }
        return """
        <section class="cobertura">
        <h2>Cobertura real dos dados</h2>
        <dl>
        <div><dt>Primeira data com dado</dt><dd>\(primeiro)</dd></div>
        <div><dt>Última data com dado</dt><dd>\(ultimo)</dd></div>
        <div><dt>Dias com dado</dt><dd>\(PainelFormat.inteiro(cobertura.diasComDado))</dd></div>
        <div><dt>Dias da janela sem dado</dt><dd>\(PainelFormat.inteiro(cobertura.diasSemDado))</dd></div>
        </dl>
        \(aviso)
        </section>
        """
    }

    // MARK: KPI cards

    static func cartao(rotulo: String, numero: String, nota: String? = nil, classe: String = "") -> String {
        let sufixo = nota.map { "<div class=\"nota\">\(PainelEscape.marcacao($0))</div>" } ?? ""
        let classes = classe.isEmpty ? "cartao" : "cartao \(classe)"
        return """
        <div class="\(classes)"><div class="rotulo">\(PainelEscape.marcacao(rotulo))</div>\
        <div class="numero">\(PainelEscape.marcacao(numero))</div>\(sufixo)</div>
        """
    }

    static func blocoVolume(_ dados: PainelData) -> String {
        let indicadores = dados.indicadores
        let hoje = indicadores.tokensHoje.map { PainelFormat.inteiro($0) + " tokens" } ?? "sem uso hoje"
        let lider = indicadores.modeloLiderNome ?? "—"
        let pico = indicadores.horaPico.map { String(format: "%02dh", $0) } ?? "—"
        let cartoes = [
            cartao(rotulo: "Tokens totais do período", numero: PainelFormat.inteiro(indicadores.tokensTotais)),
            cartao(
                rotulo: "Média por dia com uso",
                numero: PainelFormat.decimal(dados.tokensPorDiaComUso, casas: 0),
                nota: "divide por \(PainelFormat.inteiro(dados.cobertura.diasComDado)) dias com dado"
            ),
            cartao(
                rotulo: "Média por dia da janela",
                numero: PainelFormat.decimal(dados.tokensPorDiaDaJanela, casas: 0),
                nota: "divide por \(PainelFormat.inteiro(dados.cobertura.janelaDias)) dias pedidos"
            ),
            cartao(rotulo: "Tokens hoje", numero: hoje),
            cartao(
                rotulo: "Modelo líder por volume",
                numero: PainelSVG.truncado(lider, limite: 26),
                nota: PainelFormat.inteiro(indicadores.modeloLiderTokens) + " tokens"
            ),
            cartao(
                rotulo: "Taxa de acerto de cache",
                numero: PainelFormat.percentual(indicadores.taxaAcertoCache),
                // O volume absoluto ao lado da taxa é o que permite conferir a divisão sem confiar
                // nela. O dólar de "economia por cache" que ficava na seção de custo foi removido:
                // era o preço de um cenário que não aconteceu.
                nota: "\(PainelFormat.inteiro(indicadores.tokensDeCache)) dos "
                    + "\(PainelFormat.inteiro(indicadores.tokensDeEntrada)) tokens de entrada vieram do cache"
            ),
            cartao(rotulo: "Hora de pico", numero: pico, nota: "maior volume no período"),
        ]
        return """
        <h2 class="secao">Volume — a grandeza principal</h2>
        <div class="cartoes">
        \(cartoes.joined(separator: "\n"))
        </div>
        """
    }

    static func blocoCusto(_ dados: PainelData) -> String {
        let indicadores = dados.indicadores
        let cartoes = [
            cartao(rotulo: "Custo estimado do período", numero: PainelFormat.moeda(indicadores.custoTotal), classe: "custo"),
            cartao(rotulo: "Custo estimado hoje", numero: PainelFormat.moeda(indicadores.custoHoje), classe: "custo"),
            cartao(
                rotulo: "Média por dia com uso",
                numero: PainelFormat.moeda(dados.custoPorDiaComUso),
                nota: "divide por \(PainelFormat.inteiro(dados.cobertura.diasComDado)) dias com dado",
                classe: "custo"
            ),
            cartao(
                rotulo: "Média por dia da janela",
                numero: PainelFormat.moeda(dados.custoPorDiaDaJanela),
                nota: "divide por \(PainelFormat.inteiro(dados.cobertura.janelaDias)) dias pedidos",
                classe: "custo"
            ),
            cartao(rotulo: "Projeção do mês", numero: PainelFormat.moeda(indicadores.projecaoMes), classe: "custo"),
        ]
        // **Sem cartão de "economia estimada por cache" (decisão do dono, 2026-08-24).** A fórmula
        // estava certa (leitura de cache a 0,1× o preço de entrada), e ainda assim o número saiu: ele
        // precifica um contrafactual — quanto teria custado um cenário que nunca rodou — e a ordem de
        // grandeza dele desacreditava os números verdadeiros ao lado. A taxa de acerto de cache
        // permanece no bloco de volume, com o numerador e o denominador escritos ao lado.
        return """
        <h2 class="secao">Custo estimado — secundário</h2>
        <p class="ressalva-custo">Estimativa de valor consumido. O plano é por assinatura — isto não é fatura, \
        e o custo não precifica tokens de cache.</p>
        <div class="cartoes">
        \(cartoes.joined(separator: "\n"))
        </div>
        """
    }

    // MARK: Charts

    static func bloco(titulo: String, sub: String, legenda: String = "", svg: String) -> String {
        """
        <section class="grafico-bloco">
        <h3>\(PainelEscape.marcacao(titulo))</h3>
        <p class="sub">\(PainelEscape.marcacao(sub))</p>
        \(legenda)\(svg)
        </section>
        """
    }

    static func legenda(grafico: String, itens: [(rotulo: String, cor: String)]) -> String {
        guard !itens.isEmpty else { return "" }
        let botoes = itens.enumerated().map { indice, item in
            "<button type=\"button\" data-grafico=\"\(PainelEscape.marcacao(grafico))\" data-serie=\"\(indice)\">"
                + "<span class=\"amostra\" style=\"--cor:\(item.cor)\"></span>"
                + PainelEscape.marcacao(item.rotulo) + "</button>"
        }
        return "<div class=\"legenda\">" + botoes.joined() + "</div>\n"
    }

    static func blocoGraficos(_ dados: PainelData) -> String {
        let dias = dados.diarioCoberto
        let categorias = dias.map { PainelDatas.diaMes($0.dia) }

        // 1 — tokens per day, four kinds stacked. The primary chart of the page.
        // Names come from `ExportLabels`, not from literals here: the workbook of the same package
        // labels these very series, and when both sides spelled them independently they drifted —
        // this legend read "Entrada" and "Cache — leitura" while the spreadsheet read
        // "Tokens de entrada" and "Cache de leitura".
        let kinds: [(String, String, (PainelDia) -> Int)] = [
            (ExportLabels.Token.entrada, PainelPaleta.serie(0), { $0.entrada }),
            (ExportLabels.Token.saida, PainelPaleta.serie(1), { $0.saida }),
            (ExportLabels.Token.cacheLeitura, PainelPaleta.serie(2), { $0.cacheLeitura }),
            (ExportLabels.Token.cacheEscrita, PainelPaleta.serie(3), { $0.cacheEscrita }),
        ]
        let series = kinds.map { nome, cor, campo in
            PainelSVG.Serie(rotulo: nome, cor: cor, valores: dias.map { Double(campo($0)) })
        }
        let dicasDia = dias.map { dia -> String in
            PainelDatas.longa(dia.dia) + " · " + PainelFormat.inteiro(dia.total) + " tokens"
                + " · entrada " + PainelFormat.inteiro(dia.entrada)
                + " · saída " + PainelFormat.inteiro(dia.saida)
                + " · cache leitura " + PainelFormat.inteiro(dia.cacheLeitura)
                + " · cache escrita " + PainelFormat.inteiro(dia.cacheEscrita)
        }
        let grafico1 = PainelSVG.colunasEmpilhadas(
            id: "tokens-dia",
            rotulo: "Tokens por dia, por tipo",
            categorias: categorias,
            series: series,
            dicas: dicasDia,
            formatoEixo: { PainelFormat.compacto($0) }
        )

        // 2 — estimated cost per day.
        let dicasCusto = dias.map { PainelDatas.longa($0.dia) + " · " + PainelFormat.moeda($0.custoUSD, casas: 4) }
        let grafico2 = PainelSVG.linha(
            id: "custo-dia",
            rotulo: "Custo estimado por dia",
            categorias: categorias,
            valores: dias.map(\.custoUSD),
            dicas: dicasCusto,
            cor: PainelPaleta.destaque,
            formatoEixo: { PainelFormat.moeda($0, casas: 2) }
        )

        // 3 — volume by model, ordered by tokens (the page's primary axis).
        let modelos = dados.modelos.sorted {
            $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.nome < $1.nome
        }
        let grafico3 = PainelSVG.barrasHorizontais(
            id: "modelos",
            rotulo: "Volume por modelo",
            barras: modelos.enumerated().map { indice, modelo in
                PainelSVG.Barra(
                    rotulo: modelo.nome,
                    valor: Double(modelo.tokens),
                    cor: PainelPaleta.serie(indice),
                    dica: modelo.nome + " · " + PainelFormat.inteiro(modelo.tokens) + " tokens · "
                        + PainelFormat.moeda(modelo.custoUSD) + " estimados"
                )
            },
            formatoValor: { PainelFormat.compacto($0) }
        )

        // 4 — volume by project. `nome` is a user-created directory name: hostile input by definition.
        let projetos = dados.projetos.sorted {
            $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.nome < $1.nome
        }
        let grafico4 = PainelSVG.barrasHorizontais(
            id: "projetos",
            rotulo: "Volume por projeto",
            barras: projetos.map { projeto in
                PainelSVG.Barra(
                    rotulo: projeto.nome,
                    valor: Double(projeto.tokens),
                    cor: PainelPaleta.destaque,
                    dica: projeto.nome + " · " + PainelFormat.inteiro(projeto.tokens) + " tokens · "
                        + PainelFormat.moeda(projeto.custoUSD) + " estimados"
                )
            },
            formatoValor: { PainelFormat.compacto($0) }
        )

        // 5 — models per day, stacked. Same colour for the same model index as chart 3.
        let matriz = dados.matrizCoberta
        let categoriasMatriz = matriz.dias.map(PainelDatas.diaMes)
        let seriesMatriz = matriz.modelos.enumerated().map { indice, nome in
            PainelSVG.Serie(
                rotulo: nome,
                cor: PainelPaleta.serie(indice),
                valores: matriz.dias.indices.map { Double(matriz.valor(dia: $0, modelo: indice)) }
            )
        }
        let dicasMatriz = matriz.dias.indices.map { linha -> String in
            let detalhe = matriz.modelos.indices
                .map { (matriz.modelos[$0], matriz.valor(dia: linha, modelo: $0)) }
                .filter { $0.1 > 0 }
                .map { "\($0.0) \(PainelFormat.inteiro($0.1))" }
                .joined(separator: " · ")
            let dia = PainelDatas.longa(matriz.dias[linha])
            return detalhe.isEmpty ? dia + " · sem uso" : dia + " · " + detalhe
        }
        let grafico5 = PainelSVG.colunasEmpilhadas(
            id: "modelos-dia",
            rotulo: "Volume por modelo e dia",
            categorias: categoriasMatriz,
            series: seriesMatriz,
            dicas: dicasMatriz,
            formatoEixo: { PainelFormat.compacto($0) }
        )

        // 6 — the 7×24 grid.
        let grafico6 = PainelSVG.mapaDeCalor(matriz: dados.heatmap)

        return """
        <h2 class="secao">Gráficos</h2>
        \(bloco(
            titulo: "Tokens por dia",
            sub: "Entrada, saída e cache empilhados. O eixo começa na primeira data com dado.",
            legenda: legenda(grafico: "tokens-dia", itens: kinds.map { ($0.0, $0.1) }),
            svg: grafico1
        ))
        \(bloco(
            titulo: "Custo estimado por dia",
            sub: "Estimativa de valor consumido, não fatura. Não precifica tokens de cache.",
            svg: grafico2
        ))
        \(bloco(
            titulo: "Volume por modelo",
            sub: "Ordenado por tokens. O custo de cada modelo está na dica ao passar o cursor.",
            svg: grafico3
        ))
        \(bloco(
            titulo: "Volume por projeto",
            sub: "Projeto é o último componente do caminho de trabalho; pastas de mesmo nome colapsam.",
            svg: grafico4
        ))
        \(bloco(
            titulo: "Volume por modelo e dia",
            sub: "Uma série por modelo, com a mesma cor do gráfico de volume por modelo.",
            legenda: legenda(grafico: "modelos-dia", itens: matriz.modelos.enumerated().map {
                ($0.element, PainelPaleta.serie($0.offset))
            }),
            svg: grafico5
        ))
        \(bloco(
            titulo: "Volume por dia da semana e hora",
            sub: "Escala do fundo da página até o terracota da marca; o valor de cada célula está na dica.",
            svg: grafico6
        ))
        """
    }

    // MARK: Footnotes

    /// The caveats travel inside the file.
    ///
    /// A number that leaves without its caveat becomes a wrong fact in somebody else's slide — which
    /// is why these are here and not only in `leia-me.txt`, a file nobody opens.
    static func rodape() -> String {
        let itens = [
            "O plano é por assinatura. O valor em dólares é uma <strong>estimativa de valor consumido</strong>, "
                + "não a fatura da Anthropic.",
            "O custo é <strong>entrada × preço de entrada + saída × preço de saída</strong>. "
                + "Tokens de cache entram como volume e nunca são precificados — somar o custo sub-conta a fatura real.",
            "A taxa de acerto de cache é a única medida de cache desta página, e vem com o numerador e o "
                + "denominador ao lado. <strong>Não há número de “economia por cache”</strong>: ele precificaria "
                + "um cenário que não aconteceu, e um contrafactual em dólar ao lado de custos reais faz os "
                + "reais parecerem errados.",
            "Projeto é o último componente do diretório de trabalho registrado no log; "
                + "vira “Unknown” quando o log não traz o caminho, e dois diretórios de mesmo nome colapsam na mesma linha.",
            "Dias anteriores à primeira data com dado <strong>não são desenhados</strong>: "
                + "dia sem dado é lacuna, não zero. Dia sem uso dentro do intervalo coberto aparece como zero, porque aí o zero é verdade.",
            "Os dados desta página estão embutidos no próprio arquivo, no bloco <code>&lt;script id=\"dados\"&gt;</code>, "
                + "em JSON — dá para reaproveitar em qualquer ferramenta sem abrir a planilha.",
            "O arquivo não faz nenhuma requisição de rede: abre offline, hoje e daqui a dois anos.",
        ]
        return """
        <footer>
        <h2>O que estes números não dizem</h2>
        <ul>
        \(itens.map { "<li>\($0)</li>" }.joined(separator: "\n"))
        </ul>
        </footer>
        """
    }
}
