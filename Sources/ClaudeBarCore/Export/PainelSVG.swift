import Foundation

// MARK: - Palette

/// The panel's colours, copied from the app rather than invented.
///
/// Every hex here has a source in the code: the brand terracotta is `PopoverStyle.brand`
/// (`DesignTokens.swift`), and the seven categorical swatches are `DashboardPalette.ramp`
/// (`DashboardView.swift`), converted from its 0…1 components. Same model index → same swatch as on
/// screen, which is the only reason a person can look at both and believe they are the same data.
public enum PainelPaleta {
    public static let fundo = "#111827"
    public static let cartao = "#1A2233"
    public static let borda = "#2A3346"
    public static let grade = "#232C3E"
    public static let texto = "#E8EAF0"
    public static let suave = "#9AA4B8"
    /// Brand terracotta.
    public static let destaque = "#CC7C5E"
    public static let acimaDaMedia = "#D16B4C"
    public static let abaixoDaMedia = "#4C9E66"

    /// `DashboardPalette.ramp` minus the brand entry, which the panel reserves for cost.
    public static let series = [
        "#598CC7", "#73AD80", "#C7944C", "#9E73B8", "#CC7380", "#66A6B2", "#999966",
    ]

    /// Cycles the ramp, so a model beyond the seventh still gets a stable colour.
    public static func serie(_ indice: Int) -> String {
        series[((indice % series.count) + series.count) % series.count]
    }
}

// MARK: - Geometry

/// The drawing area of one chart, in the SVG's own user units.
struct PainelMoldura {
    let largura: Double
    let altura: Double
    let esquerda: Double
    let direita: Double
    let topo: Double
    let base: Double

    var plotLargura: Double { largura - esquerda - direita }
    var plotAltura: Double { altura - topo - base }
    var baseY: Double { topo + plotAltura }

    static let padrao = PainelMoldura(
        largura: 960, altura: 320, esquerda: 84, direita: 24, topo: 20, base: 46
    )
}

// MARK: - Charts

/// Charts drawn as SVG by Swift, so they are in the bytes of the file.
///
/// **Why the markup is emitted here and not by JavaScript from the JSON block.** Three consequences,
/// and each one was worth the extra code:
///
/// - the file *already has* the charts with scripting disabled, which is what "já vem com gráficos"
///   means literally;
/// - SVG is XML, so a test can parse it with `XMLDocument` and count elements — a canvas chart would
///   only exist after a browser ran, which no test here can do;
/// - the output is a pure function of the input, so two runs produce the same bytes.
///
/// **No `xmlns` attribute is written, on purpose.** Inline SVG in an HTML5 document is put in the SVG
/// namespace by the parser itself, and the canonical namespace URI would be the one and only `http://`
/// string in a file whose contract is *zero network references* — a grep for `https?://` is how that
/// contract is checked, and it cannot distinguish a namespace from a download. Standalone parsing is
/// unaffected: an undeclared default namespace is still well-formed XML.
public enum PainelSVG {
    // MARK: Primitives

    /// Two decimals, fixed: coordinates must not drift between runs or platforms.
    static func n(_ valor: Double) -> String {
        guard valor.isFinite else { return "0" }
        var texto = String(format: "%.2f", valor)
        if texto.contains(".") {
            while texto.hasSuffix("0") { texto.removeLast() }
            if texto.hasSuffix(".") { texto.removeLast() }
        }
        return texto == "-0" ? "0" : texto
    }

    static func abre(id: String, rotulo: String, largura: Double, altura: Double) -> String {
        """
        <svg class="grafico" data-grafico="\(PainelEscape.marcacao(id))" viewBox="0 0 \(n(largura)) \(n(altura))" \
        preserveAspectRatio="xMidYMid meet" role="img" aria-label="\(PainelEscape.marcacao(rotulo))">
        """
    }

    /// The message that replaces a chart with nothing to show.
    ///
    /// It is still an `<svg>`, and that matters: the page keeps six charts in six slots whether or not
    /// the window has data, so "the chart vanished" never becomes a silent way of saying "no data".
    static func semDado(id: String, rotulo: String, largura: Double = 960, altura: Double = 160) -> String {
        abre(id: id, rotulo: rotulo, largura: largura, altura: altura)
            + "<text x=\"\(n(largura / 2))\" y=\"\(n(altura / 2))\" text-anchor=\"middle\" "
            + "class=\"vazio\">Sem dado no intervalo coberto</text></svg>"
    }

    /// Horizontal grid lines plus their value labels.
    static func eixoY(maximo: Double, moldura: PainelMoldura, formato: (Double) -> String) -> String {
        var saida = "<g class=\"grade\">"
        let divisoes = 4
        for passo in 0...divisoes {
            let fracao = Double(passo) / Double(divisoes)
            let y = moldura.baseY - moldura.plotAltura * fracao
            saida += "<line x1=\"\(n(moldura.esquerda))\" y1=\"\(n(y))\" "
                + "x2=\"\(n(moldura.esquerda + moldura.plotLargura))\" y2=\"\(n(y))\"/>"
            saida += "<text x=\"\(n(moldura.esquerda - 10))\" y=\"\(n(y + 4))\" text-anchor=\"end\" class=\"marca\">"
                + PainelEscape.marcacao(formato(maximo * fracao)) + "</text>"
        }
        return saida + "</g>"
    }

    /// Category labels along the X axis, thinned so they never overlap.
    static func eixoX(categorias: [String], moldura: PainelMoldura) -> String {
        guard !categorias.isEmpty else { return "" }
        let fatia = moldura.plotLargura / Double(categorias.count)
        let passo = max(1, Int((Double(categorias.count) / 12).rounded(.up)))
        var saida = "<g class=\"marcas-x\">"
        for (indice, rotulo) in categorias.enumerated() where indice % passo == 0 {
            let x = moldura.esquerda + fatia * (Double(indice) + 0.5)
            saida += "<text x=\"\(n(x))\" y=\"\(n(moldura.baseY + 20))\" text-anchor=\"middle\" class=\"marca\">"
                + PainelEscape.marcacao(rotulo) + "</text>"
        }
        return saida + "</g>"
    }

    // MARK: 1 & 5 — stacked columns

    /// One series of a stacked column chart.
    public struct Serie: Sendable {
        public let rotulo: String
        public let cor: String
        public let valores: [Double]

        public init(rotulo: String, cor: String, valores: [Double]) {
            self.rotulo = rotulo
            self.cor = cor
            self.valores = valores
        }
    }

    /// Stacked columns — chart 1 (four token kinds) and chart 5 (one series per model).
    ///
    /// `dicas` carries one ready-made tooltip line per category; it is built by the caller because only
    /// the caller knows whether a column is a day of tokens or a day of models.
    public static func colunasEmpilhadas(
        id: String,
        rotulo: String,
        categorias: [String],
        series: [Serie],
        dicas: [String],
        formatoEixo: @escaping (Double) -> String
    ) -> String {
        let moldura = PainelMoldura.padrao
        guard !categorias.isEmpty, !series.isEmpty else { return semDado(id: id, rotulo: rotulo) }

        var totais = [Double](repeating: 0, count: categorias.count)
        for serie in series {
            for (indice, valor) in serie.valores.enumerated() where indice < totais.count {
                totais[indice] += max(0, valor)
            }
        }
        let maximo = totais.max() ?? 0
        guard maximo > 0 else { return semDado(id: id, rotulo: rotulo) }

        let fatia = moldura.plotLargura / Double(categorias.count)
        let larguraBarra = min(fatia * 0.72, 46)
        var saida = abre(id: id, rotulo: rotulo, largura: moldura.largura, altura: moldura.altura)
        saida += eixoY(maximo: maximo, moldura: moldura, formato: formatoEixo)

        var acumulado = [Double](repeating: 0, count: categorias.count)
        for (indiceSerie, serie) in series.enumerated() {
            saida += "<g class=\"serie\" data-serie=\"\(indiceSerie)\" data-rotulo=\""
                + PainelEscape.marcacao(serie.rotulo) + "\" fill=\"\(serie.cor)\">"
            for indice in categorias.indices {
                let valor = indice < serie.valores.count ? max(0, serie.valores[indice]) : 0
                guard valor > 0 else { continue }
                let altura = moldura.plotAltura * (valor / maximo)
                let y = moldura.baseY - moldura.plotAltura * ((acumulado[indice] + valor) / maximo)
                let x = moldura.esquerda + fatia * (Double(indice) + 0.5) - larguraBarra / 2
                saida += "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(larguraBarra))\" "
                    + "height=\"\(n(max(altura, 0.6)))\"/>"
                acumulado[indice] += valor
            }
            saida += "</g>"
        }

        saida += "<line class=\"base\" x1=\"\(n(moldura.esquerda))\" y1=\"\(n(moldura.baseY))\" "
            + "x2=\"\(n(moldura.esquerda + moldura.plotLargura))\" y2=\"\(n(moldura.baseY))\"/>"
        saida += eixoX(categorias: categorias, moldura: moldura)
        saida += alvos(categorias: categorias, dicas: dicas, moldura: moldura, fatia: fatia)
        return saida + "</svg>"
    }

    // MARK: 2 — line

    /// A single line over the same category axis — chart 2, the estimated cost per day.
    public static func linha(
        id: String,
        rotulo: String,
        categorias: [String],
        valores: [Double],
        dicas: [String],
        cor: String,
        formatoEixo: @escaping (Double) -> String
    ) -> String {
        let moldura = PainelMoldura.padrao
        guard !categorias.isEmpty, valores.contains(where: { $0 > 0 }) else {
            return semDado(id: id, rotulo: rotulo)
        }
        let maximo = valores.max() ?? 0
        guard maximo > 0 else { return semDado(id: id, rotulo: rotulo) }

        let fatia = moldura.plotLargura / Double(categorias.count)
        func ponto(_ indice: Int) -> (x: Double, y: Double) {
            let valor = indice < valores.count ? max(0, valores[indice]) : 0
            return (
                moldura.esquerda + fatia * (Double(indice) + 0.5),
                moldura.baseY - moldura.plotAltura * (valor / maximo)
            )
        }

        var saida = abre(id: id, rotulo: rotulo, largura: moldura.largura, altura: moldura.altura)
        saida += eixoY(maximo: maximo, moldura: moldura, formato: formatoEixo)

        let pontos = categorias.indices.map(ponto)
        let caminho = pontos.enumerated()
            .map { "\($0.offset == 0 ? "M" : "L")\(n($0.element.x)),\(n($0.element.y))" }
            .joined(separator: " ")
        // The filled area is drawn first so the stroke sits on top of it.
        let area = "M\(n(pontos[0].x)),\(n(moldura.baseY)) "
            + pontos.map { "L\(n($0.x)),\(n($0.y))" }.joined(separator: " ")
            + " L\(n(pontos[pontos.count - 1].x)),\(n(moldura.baseY)) Z"
        saida += "<g class=\"serie\" data-serie=\"0\" data-rotulo=\"" + PainelEscape.marcacao(rotulo) + "\">"
        saida += "<path class=\"area\" d=\"\(area)\" fill=\"\(cor)\" fill-opacity=\"0.18\"/>"
        saida += "<path class=\"traco\" d=\"\(caminho)\" fill=\"none\" stroke=\"\(cor)\" stroke-width=\"2\" "
            + "stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
        if pontos.count <= 45 {
            for ponto in pontos {
                saida += "<circle cx=\"\(n(ponto.x))\" cy=\"\(n(ponto.y))\" r=\"2.6\" fill=\"\(cor)\"/>"
            }
        }
        saida += "</g>"

        saida += "<line class=\"base\" x1=\"\(n(moldura.esquerda))\" y1=\"\(n(moldura.baseY))\" "
            + "x2=\"\(n(moldura.esquerda + moldura.plotLargura))\" y2=\"\(n(moldura.baseY))\"/>"
        saida += eixoX(categorias: categorias, moldura: moldura)
        saida += alvos(categorias: categorias, dicas: dicas, moldura: moldura, fatia: fatia)
        return saida + "</svg>"
    }

    // MARK: 3 & 4 — horizontal bars

    /// One bar of a horizontal bar chart.
    public struct Barra: Sendable {
        public let rotulo: String
        public let valor: Double
        public let cor: String
        public let dica: String

        public init(rotulo: String, valor: Double, cor: String, dica: String) {
            self.rotulo = rotulo
            self.valor = valor
            self.cor = cor
            self.dica = dica
        }
    }

    /// Horizontal bars — charts 3 (models) and 4 (projects), both ordered by tokens.
    ///
    /// The label column is where a hostile project name arrives on the page; it is truncated for
    /// layout and then escaped, never the other way round.
    public static func barrasHorizontais(
        id: String,
        rotulo: String,
        barras: [Barra],
        formatoValor: (Double) -> String
    ) -> String {
        guard !barras.isEmpty, barras.contains(where: { $0.valor > 0 }) else {
            return semDado(id: id, rotulo: rotulo)
        }
        let maximo = barras.map(\.valor).max() ?? 0
        guard maximo > 0 else { return semDado(id: id, rotulo: rotulo) }

        let largura = 960.0
        let alturaLinha = 30.0
        let altura = 24 + alturaLinha * Double(barras.count)
        let colunaRotulo = 232.0
        let colunaValor = 116.0
        let trilho = largura - colunaRotulo - colunaValor - 16

        var saida = abre(id: id, rotulo: rotulo, largura: largura, altura: altura)
        for (indice, barra) in barras.enumerated() {
            let y = 12 + alturaLinha * Double(indice)
            let comprimento = max(2, trilho * (max(0, barra.valor) / maximo))
            saida += "<g class=\"barra\" data-dica=\"" + PainelEscape.marcacao(barra.dica) + "\">"
            saida += "<title>" + PainelEscape.marcacao(barra.dica) + "</title>"
            saida += "<text x=\"\(n(colunaRotulo - 12))\" y=\"\(n(y + 15))\" text-anchor=\"end\" class=\"rotulo\">"
                + PainelEscape.marcacao(truncado(barra.rotulo, limite: 30)) + "</text>"
            saida += "<rect class=\"trilho\" x=\"\(n(colunaRotulo))\" y=\"\(n(y + 4))\" "
                + "width=\"\(n(trilho))\" height=\"\(n(alturaLinha - 12))\" rx=\"3\"/>"
            saida += "<rect x=\"\(n(colunaRotulo))\" y=\"\(n(y + 4))\" width=\"\(n(comprimento))\" "
                + "height=\"\(n(alturaLinha - 12))\" rx=\"3\" fill=\"\(barra.cor)\"/>"
            saida += "<text x=\"\(n(colunaRotulo + trilho + 12))\" y=\"\(n(y + 15))\" class=\"valor\">"
                + PainelEscape.marcacao(formatoValor(barra.valor)) + "</text>"
            saida += "</g>"
        }
        return saida + "</svg>"
    }

    // MARK: 6 — heat map

    /// The 7×24 grid — chart 6. Colour runs from the page background to the brand terracotta.
    public static func mapaDeCalor(matriz: [[Int]]) -> String {
        let identificador = "heatmap"
        let titulo = "Volume por dia da semana e hora"
        let maximo = Double(matriz.flatMap { $0 }.max() ?? 0)
        guard maximo > 0 else { return semDado(id: identificador, rotulo: titulo, altura: 140) }

        let celulaLargura = 34.0
        let celulaAltura = 26.0
        let margemEsquerda = 52.0
        let margemTopo = 24.0
        let largura = margemEsquerda + celulaLargura * 24 + 8
        let altura = margemTopo + celulaAltura * 7 + 12

        var saida = abre(id: identificador, rotulo: titulo, largura: largura, altura: altura)
        for hora in 0..<24 where hora % 2 == 0 {
            let x = margemEsquerda + celulaLargura * (Double(hora) + 0.5)
            saida += "<text x=\"\(n(x))\" y=\"\(n(margemTopo - 8))\" text-anchor=\"middle\" class=\"marca\">"
                + String(format: "%02d", hora) + "</text>"
        }
        for linha in 0..<7 {
            let y = margemTopo + celulaAltura * Double(linha)
            let nomeDia = linha < PainelDatas.diasDaSemana.count ? PainelDatas.diasDaSemana[linha] : "?"
            saida += "<text x=\"\(n(margemEsquerda - 10))\" y=\"\(n(y + 17))\" text-anchor=\"end\" class=\"marca\">"
                + PainelEscape.marcacao(nomeDia) + "</text>"
            for hora in 0..<24 {
                let valor = (linha < matriz.count && hora < matriz[linha].count) ? Double(matriz[linha][hora]) : 0
                let intensidade = valor / maximo
                let x = margemEsquerda + celulaLargura * Double(hora)
                let dica = "\(nomeDia) · \(String(format: "%02d", hora))h · "
                    + PainelFormat.inteiro(Int(valor)) + " tokens"
                saida += "<g class=\"celula\" data-dica=\"" + PainelEscape.marcacao(dica) + "\">"
                saida += "<title>" + PainelEscape.marcacao(dica) + "</title>"
                saida += "<rect x=\"\(n(x + 1))\" y=\"\(n(y + 1))\" width=\"\(n(celulaLargura - 2))\" "
                    + "height=\"\(n(celulaAltura - 2))\" rx=\"3\" fill=\"\(mistura(intensidade))\"/>"
                saida += "</g>"
            }
        }
        return saida + "</svg>"
    }

    /// Linear blend from the grid tone to the brand terracotta.
    ///
    /// The ramp starts at ``PainelPaleta/grade`` rather than at the card colour on purpose: a cell of
    /// very low volume painted in exactly the background colour disappears, and an invisible cell reads
    /// as "no data" when it means "little use". Every cell of the grid stays visible.
    static func mistura(_ intensidade: Double) -> String {
        let t = min(max(intensidade, 0), 1)
        let inicio = componentes(PainelPaleta.grade)
        let fim = componentes(PainelPaleta.destaque)
        let canal = (0..<3).map { indice -> Int in
            let valor = Double(inicio[indice]) + (Double(fim[indice]) - Double(inicio[indice])) * t
            return Int(valor.rounded())
        }
        return String(format: "#%02X%02X%02X", canal[0], canal[1], canal[2])
    }

    static func componentes(_ hex: String) -> [Int] {
        let limpo = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard limpo.count == 6, let valor = Int(limpo, radix: 16) else { return [0, 0, 0] }
        return [(valor >> 16) & 0xFF, (valor >> 8) & 0xFF, valor & 0xFF]
    }

    // MARK: Shared

    /// Full-height transparent columns that carry the tooltip for a whole category.
    ///
    /// A `<title>` child gives the browser a native tooltip with scripting off; the `data-dica`
    /// attribute is what the embedded script upgrades it to.
    static func alvos(categorias: [String], dicas: [String], moldura: PainelMoldura, fatia: Double) -> String {
        var saida = "<g class=\"alvos\">"
        for indice in categorias.indices {
            let dica = indice < dicas.count ? dicas[indice] : categorias[indice]
            let x = moldura.esquerda + fatia * Double(indice)
            saida += "<g class=\"alvo\" data-dica=\"" + PainelEscape.marcacao(dica) + "\">"
            saida += "<title>" + PainelEscape.marcacao(dica) + "</title>"
            saida += "<rect x=\"\(n(x))\" y=\"\(n(moldura.topo))\" width=\"\(n(fatia))\" "
                + "height=\"\(n(moldura.plotAltura))\" fill=\"transparent\"/>"
            saida += "</g>"
        }
        return saida + "</g>"
    }

    /// Shortens a label for the axis, marking the cut so a truncated name never reads as the real one.
    static func truncado(_ texto: String, limite: Int) -> String {
        texto.count <= limite ? texto : String(texto.prefix(limite - 1)) + "…"
    }
}
