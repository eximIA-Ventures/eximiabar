import Foundation
import Testing
@testable import ClaudeBarCore

/// Gates for `painel.html` (EXB-6.6).
///
/// **What these tests can and cannot see.** They never run a browser, so they cannot say the panel
/// *looks* right — a human opens the sample for that (``amostraParaOlhoHumano``). What they can prove
/// is everything that fails silently: an SVG that is not well-formed, bytes that differ between runs,
/// a network reference that would make the file blank in two years, a day drawn before the data
/// begins, and a directory name that closes the `<script>` block.
struct PainelHTMLTests {
    // MARK: - Helpers

    static func svgs(in html: String) -> [String] {
        let expressao = try? NSRegularExpression(pattern: "<svg\\b.*?</svg>", options: [.dotMatchesLineSeparators])
        let alcance = NSRange(html.startIndex..<html.endIndex, in: html)
        return expressao?.matches(in: html, range: alcance).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        } ?? []
    }

    /// The contents of the single `<script id="dados">` block, still as text.
    static func blocoDeDados(in html: String) throws -> String {
        let abertura = "<script id=\"dados\" type=\"application/json\">"
        let inicio = try #require(html.range(of: abertura))
        let fim = try #require(html.range(of: "</script>", range: inicio.upperBound..<html.endIndex))
        return String(html[inicio.upperBound..<fim.lowerBound])
    }

    static func json(in html: String) throws -> [String: Any] {
        let bloco = try blocoDeDados(in: html)
        let objeto = try JSONSerialization.jsonObject(with: Data(bloco.utf8))
        return try #require(objeto as? [String: Any])
    }

    // MARK: - AC: the charts are in the bytes, and they are XML

    /// Six charts, each one a document `XMLDocument` accepts, and the primary one carrying its four
    /// series.
    ///
    /// The series count is the assertion that would catch the subtlest regression: a stacked chart
    /// that silently lost the cache series still draws, still validates, and still looks plausible.
    @Test
    func seisGraficosEmSVGValido() throws {
        let html = PainelHTMLWriter.render(PainelSampleData.make())
        let blocos = Self.svgs(in: html)
        #expect(blocos.count == 6, "esperava 6 <svg>, encontrei \(blocos.count)")

        // A parse failure throws out of the test, which is the report we want: the message names the
        // line and column of the malformed markup.
        for bloco in blocos {
            _ = try XMLDocument(xmlString: bloco, options: [])
        }

        let primario = try #require(blocos.first { $0.contains("data-grafico=\"tokens-dia\"") })
        let documento = try XMLDocument(xmlString: primario, options: [])
        let series = try documento.nodes(forXPath: "//g[@class='serie']")
        #expect(series.count == 4, "o gráfico primário perdeu séries: \(series.count) de 4")
    }

    // MARK: - AC: nothing is fetched

    /// Zero network references — the requirement that keeps the file working offline and in two years.
    ///
    /// The emptiness guard is not decoration: a renderer that returned `""` would pass the grep and
    /// prove nothing, so the same test demands the six charts and the data block be there.
    @Test
    func nenhumaReferenciaDeRede() throws {
        let html = PainelHTMLWriter.render(PainelSampleData.make())
        let padrao = "https?://|<script src|<link |@import|fetch\\(|XMLHttpRequest|integrity="
        let expressao = try NSRegularExpression(pattern: padrao, options: [])
        let ocorrencias = expressao.numberOfMatches(
            in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)
        )
        #expect(ocorrencias == 0, "o painel referencia a rede em \(ocorrencias) ponto(s)")

        #expect(Self.svgs(in: html).count == 6, "guarda contra vacuidade: o painel está vazio")
        #expect(!(try Self.blocoDeDados(in: html)).isEmpty)
    }

    // MARK: - AC: same input, same bytes

    /// Two renders of the same fixture are byte-identical.
    ///
    /// **Declared as weak on its own** — a constant string would pass it. It has teeth only next to the
    /// content assertions above, and it exists to catch the specific mistakes that make output drift:
    /// a timestamp in the page, a dictionary iterated in hash order, a locale-dependent formatter.
    @Test
    func bytesIdenticosEmDuasGeracoes() {
        let primeira = PainelHTMLWriter.bytes(PainelSampleData.make())
        let segunda = PainelHTMLWriter.bytes(PainelSampleData.make())
        #expect(ExportTestSupport.sha256(primeira) == ExportTestSupport.sha256(segunda))
        #expect(primeira.count > 20_000, "guarda contra vacuidade: saída suspeitamente pequena")
    }

    // MARK: - AC: the JSON parses, and it starts where the data starts

    @Test
    func blocoDeDadosParseiaEComecaNaCobertura() throws {
        let dados = PainelSampleData.make()
        let html = PainelHTMLWriter.render(dados)
        let raiz = try Self.json(in: html)

        let cobertura = try #require(raiz["cobertura"] as? [String: Any])
        let primeiroDia = try #require(cobertura["primeiro_dia"] as? String)
        let diario = try #require(raiz["diario"] as? [[String: Any]])
        let datas = diario.compactMap { $0["dia"] as? String }

        #expect(datas.count == diario.count)
        #expect(datas.min() == primeiroDia, "o JSON traz dia anterior à cobertura")
        #expect(datas.max() == cobertura["ultimo_dia"] as? String)
    }

    /// The distinction the whole coverage block exists for: **a day with no data is a gap, a day with
    /// no use inside the covered range is a zero.**
    ///
    /// Both halves are asserted, because getting one right and the other wrong is the likely failure:
    /// clipping too little redraws the phantom zeros of July, clipping too much erases a real idle day.
    @Test
    func diaSemDadoViraLacunaEDiaOciosoViraZero() throws {
        let dados = PainelSampleData.make()
        let html = PainelHTMLWriter.render(dados)
        let raiz = try Self.json(in: html)
        let diario = try #require(raiz["diario"] as? [[String: Any]])

        let esperados = PainelSampleData.janelaDias - PainelSampleData.primeiroCoberto
        #expect(diario.count == esperados, "esperava \(esperados) pontos cobertos, vi \(diario.count)")
        #expect(dados.diario.count == PainelSampleData.janelaDias, "a entrada crua perdeu dias")

        let ocioso = PainelDatas.iso(PainelSampleData.dia(PainelSampleData.diaOciosoCoberto))
        let linha = try #require(diario.first { $0["dia"] as? String == ocioso })
        #expect((linha["tokens_total"] as? Int) == 0, "o dia ocioso coberto deixou de ser um zero verdadeiro")

        let anterior = PainelDatas.iso(PainelSampleData.dia(PainelSampleData.primeiroCoberto - 1))
        #expect(!diario.contains { $0["dia"] as? String == anterior }, "um dia anterior à cobertura foi desenhado")
    }

    // MARK: - AC: the counterfactual dollar is gone, the verifiable rate stays

    /// The cache "saving" in dollars left the page **and** the data block; the hit rate stayed.
    ///
    /// **Note how this gate is written, because the obvious version collides with itself.** Grepping
    /// the page for the plain words "economia por cache" would fail against the footnote that
    /// *explains the removal* — the gate would flag the documentation of the defect as the defect.
    /// So the assertions are on the card's own markup and on the JSON key, both of which exist only
    /// if the number came back.
    @Test
    func semDolarDeEconomiaPorCache() throws {
        let html = PainelHTMLWriter.render(PainelSampleData.make())

        #expect(!html.contains("<div class=\"rotulo\">Economia estimada por cache</div>"))
        let indicadores = try #require(try Self.json(in: html)["indicadores"] as? [String: Any])
        #expect(indicadores["economia_cache_usd"] == nil, "o número contrafactual voltou ao bloco de dados")

        // A metade que fica — sem isto, apagar a seção de custo inteira passaria neste teste.
        #expect(indicadores["taxa_acerto_cache"] != nil)
        #expect((indicadores["tokens_de_cache"] as? Int) != nil)
        #expect((indicadores["tokens_de_entrada"] as? Int) != nil)
        #expect(html.contains("Taxa de acerto de cache"))
        #expect(html.contains("tokens de entrada vieram do cache"))
    }

    /// A taxa publicada tem de bater com os dois números publicados ao lado dela.
    ///
    /// É o par que o cartão mostra: se a divisão não fecha, o painel está pedindo fé em vez de
    /// mostrar a conta — exatamente o que a remoção do dólar veio corrigir.
    @Test
    func aTaxaDeCacheFechaComONumeradorEODenominador() throws {
        let indicadores = PainelSampleData.make().indicadores
        let denominador = Double(indicadores.tokensDeEntrada)
        #expect(denominador > 0)
        let derivada = Double(indicadores.tokensDeCache) / denominador
        #expect(abs(derivada - indicadores.taxaAcertoCache) < 0.0005)
    }

    // MARK: - AC: the hostile directory name

    /// A project named `</script><img src=x onerror=alert(1)>` must not close the data block.
    ///
    /// The fixture is the workbook's, on purpose: the same string is what the XLSX gate uses, so a
    /// weakening of either escape shows up against the same adversary.
    @Test
    func nomeHostilNaoEscapaDoBlocoDeDados() throws {
        let hostil = ExportSampleWorkbook.hostileProjectName
        let dados = PainelSampleData.make()
        let comHostil = PainelData(
            cobertura: dados.cobertura,
            indicadores: dados.indicadores,
            diario: dados.diario,
            modelos: dados.modelos,
            projetos: [PainelProjeto(nome: hostil, tokens: 208_900, custoUSD: 1.9044)],
            matrizModelos: dados.matrizModelos,
            heatmap: dados.heatmap
        )
        let html = PainelHTMLWriter.render(comHostil)

        let bloco = try Self.blocoDeDados(in: html)
        #expect(!bloco.contains("</script>"), "o nome hostil fecharia o bloco de dados")
        #expect(!bloco.contains("<img"), "marcação crua sobreviveu dentro do JSON")
        #expect(!html.contains("<img"), "marcação crua sobreviveu na página")

        // Still valid JSON, and still the original string once parsed — escaping must not corrupt data.
        let raiz = try Self.json(in: html)
        let projetos = try #require(raiz["projetos"] as? [[String: Any]])
        #expect(projetos.first?["projeto"] as? String == hostil)

        // And the second boundary: the same name reaches the SVG axis as text, escaped there too.
        let svgProjetos = try #require(Self.svgs(in: html).first { $0.contains("data-grafico=\"projetos\"") })
        _ = try XMLDocument(xmlString: svgProjetos, options: [])
        #expect(svgProjetos.contains("&lt;/script&gt;"))
    }

    /// The two fixtures must keep using the same adversary; a rename on either side is a silent hole.
    @Test
    func asDuasFixturesUsamOMesmoNomeHostil() {
        #expect(PainelSampleData.nomeHostil == ExportSampleWorkbook.hostileProjectName)
    }

    /// U+2028 and U+2029 are legal in JSON and fatal to a JavaScript parser — the panel escapes both.
    @Test
    func separadoresDeLinhaSaoEscapados() throws {
        let nome = "linha\u{2028}quebrada\u{2029}fim"
        let dados = PainelSampleData.make()
        let comSeparadores = PainelData(
            cobertura: dados.cobertura,
            indicadores: dados.indicadores,
            diario: dados.diario,
            modelos: dados.modelos,
            projetos: [PainelProjeto(nome: nome, tokens: 1_000, custoUSD: 0.01)],
            matrizModelos: dados.matrizModelos,
            heatmap: dados.heatmap
        )
        let html = PainelHTMLWriter.render(comSeparadores)
        let bloco = try Self.blocoDeDados(in: html)

        #expect(!bloco.unicodeScalars.contains("\u{2028}"))
        #expect(!bloco.unicodeScalars.contains("\u{2029}"))
        let raiz = try Self.json(in: html)
        let projetos = try #require(raiz["projetos"] as? [[String: Any]])
        #expect(projetos.first?["projeto"] as? String == nome)
    }

    // MARK: - AC: the shell stays auditable

    /// The template has exactly two injection points, and this test is what keeps it that way.
    ///
    /// The argument for the panel's safety is that the surface where outside text meets markup is small
    /// enough to read in one sitting. A third interpolation added later would be invisible in review
    /// and would quietly break that argument — so the count is asserted against the source file itself.
    @Test
    func aCascaTemExatamenteDoisPontosDeInjecao() throws {
        let fonte = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ClaudeBarCore/Export/PainelTemplate.swift")
        let texto = try String(contentsOf: fonte, encoding: .utf8)
        let ocorrencias = texto.components(separatedBy: ##"\#("##).count - 1
        // O comentário precisa ser UM literal: `Comment` é `ExpressibleByStringInterpolation`, e uma
        // expressão montada com `+` não é literal nenhum — não converte.
        #expect(
            ocorrencias == 2,
            """
            a casca passou a ter \(ocorrencias) marcadores de interpolação. A contagem cobre o \
            arquivo inteiro, comentários inclusive — se um deles é só um exemplo em prosa, \
            reescreva a prosa, não afrouxe o portão.
            """
        )
    }

    // MARK: - The sample a human opens

    /// Writes the sample panel for someone to open in a browser.
    ///
    /// No assertion here beyond the write succeeding, and that is honest: nothing in this file can
    /// tell whether a chart is legible, whether a label collides, or whether the page reads as an
    /// answer. Only opening it can.
    @Test
    func amostraParaOlhoHumano() throws {
        let destino = URL(fileURLWithPath: "/tmp/eximiabar-export/painel.html")
        try FileManager.default.createDirectory(
            at: destino.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try PainelHTMLWriter.bytes(PainelSampleData.make()).write(to: destino)
        #expect(FileManager.default.fileExists(atPath: destino.path))
    }
}
