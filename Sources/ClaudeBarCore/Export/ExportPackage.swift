import Foundation

/// Assembles the export folder: the workbook, the tidy CSVs, the Power BI connection file, the panel
/// and the plain-text notes.
///
/// **What this type deliberately does not know.** It never touches `DashboardData`, never reads a log
/// and never asks the clock. Everything variable — the numbers, the coverage, the generation instant,
/// the panel's HTML — arrives as input. That is what makes the whole package a pure function of its
/// inputs, and therefore reproducible byte for byte: only the date in the folder name varies, and it
/// varies because the caller passes a different instant.
///
/// **Two pieces are declared missing rather than faked.** `painel.html` belongs to another story, and
/// the fine grain behind `fato.csv` does not exist in the app yet (the app derives its dashboard and
/// throws the `(day × model)` rows away). Both are optional inputs, and when absent the file is **not
/// written** and `leia-me.txt` says so in words. An empty `fato.csv` would be worse than a missing
/// one: a BI tool ingests it without complaint and reports a period of no usage.
public enum ExportPackage {
    // MARK: - Inputs

    /// How much of the requested window the source data actually covers.
    ///
    /// This is the first thing the reader sees, in every artifact, because a workbook that presents a
    /// 90-day window over 55 days of data understates every average by a third and says nothing.
    public struct Coverage: Sendable, Equatable {
        /// First day with data, or `nil` when there is none at all.
        public let firstDay: Date?
        /// Last day with data.
        public let lastDay: Date?
        /// Number of distinct days that carry data.
        public let daysWithData: Int
        /// Length of the window the user asked for.
        public let requestedDays: Int

        public init(firstDay: Date?, lastDay: Date?, daysWithData: Int, requestedDays: Int) {
            self.firstDay = firstDay
            self.lastDay = lastDay
            self.daysWithData = daysWithData
            self.requestedDays = requestedDays
        }

        /// True when the window asks for more days than the source can answer for.
        public var isPartial: Bool { daysWithData < requestedDays }
    }

    /// Everything the package needs, with nothing derived inside.
    public struct Input: Sendable {
        /// The instant written into `leia-me.txt` and used for the folder name. Injected, never read
        /// from the clock here, so a test can assert byte equality.
        public let generatedAt: Date
        /// App version, for the provenance line.
        public let appVersion: String
        /// Human label of the window, e.g. `Últimos 30 dias`.
        public let periodLabel: String
        public let coverage: Coverage
        /// The `.xlsx` bytes, from ``XLSXWriter``.
        public let workbook: Data
        /// The self-contained panel. `nil` until the story that builds it lands.
        public let panelHTML: String?
        /// Tidy tables with human column names.
        public let daily: CSVTable
        public let models: CSVTable
        public let projects: CSVTable
        /// The `(day × model)` grain, with technical column names. `nil` while the app still discards it.
        public let fact: CSVTable?

        public init(
            generatedAt: Date,
            appVersion: String,
            periodLabel: String,
            coverage: Coverage,
            workbook: Data,
            panelHTML: String?,
            daily: CSVTable,
            models: CSVTable,
            projects: CSVTable,
            fact: CSVTable?
        ) {
            self.generatedAt = generatedAt
            self.appVersion = appVersion
            self.periodLabel = periodLabel
            self.coverage = coverage
            self.workbook = workbook
            self.panelHTML = panelHTML
            self.daily = daily
            self.models = models
            self.projects = projects
            self.fact = fact
        }
    }

    /// One file of the package, at a path relative to the folder root.
    public struct File: Sendable, Equatable {
        public let relativePath: String
        public let contents: Data
    }

    // MARK: - Assembly

    /// The folder name: `exportacao-eximiabar-YYYY-MM-DD`.
    public static func folderName(for date: Date) -> String {
        "exportacao-eximiabar-\(CSVWriter.isoDay(date))"
    }

    /// Every file of the package, in a fixed order.
    ///
    /// `destination` is the folder the package will be extracted to; it is needed only to write an
    /// absolute path into the `.pbids`, which is what lets a double click land in Power BI's navigator
    /// without anyone typing a path.
    public static func files(for input: Input, destination: URL) -> [File] {
        var files: [File] = []

        if let html = input.panelHTML {
            files.append(File(relativePath: "painel.html", contents: Data(html.utf8)))
        }
        files.append(File(relativePath: "planilha.xlsx", contents: input.workbook))

        for table in [input.daily, input.models, input.projects] {
            files.append(File(relativePath: "dados/\(table.name).csv", contents: CSVWriter.data(for: table)))
        }
        if let fact = input.fact {
            files.append(File(relativePath: "dados/\(fact.name).csv", contents: CSVWriter.data(for: fact)))
        }

        files.append(File(
            relativePath: "conectar-powerbi.pbids",
            contents: Data(powerBIConnectionJSON(dataFolder: destination.appendingPathComponent("dados")).utf8)
        ))
        files.append(File(relativePath: "leia-me.txt", contents: Data(readme(for: input).utf8)))
        return files
    }

    /// Writes the package under `parent`, returning the folder it created.
    public static func write(_ input: Input, under parent: URL) throws -> URL {
        let root = parent.appendingPathComponent(folderName(for: input.generatedAt), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dados"), withIntermediateDirectories: true
        )
        for file in files(for: input, destination: root) {
            try file.contents.write(to: root.appendingPathComponent(file.relativePath))
        }
        return root
    }

    // MARK: - .pbids

    /// The Power BI connection file: a documented, nine-line JSON that points at the `dados/` folder.
    ///
    /// Kept because it costs almost nothing and the format *is* publicly specified — unlike `.pbit`,
    /// whose interior is not, and which would not open on this machine anyway.
    static func powerBIConnectionJSON(dataFolder: URL) -> String {
        let path = escapeJSONString(dataFolder.path)
        return """
        {
          "version": "0.1",
          "connections": [
            {
              "details": {
                "protocol": "folder",
                "address": {
                  "path": "\(path)"
                }
              },
              "mode": "Import"
            }
          ]
        }
        """
    }

    /// Minimal JSON string escaping — enough for a filesystem path, which can contain quotes and
    /// backslashes on this platform.
    static func escapeJSONString(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - leia-me.txt

    /// The plain-text notes.
    ///
    /// Plain text on purpose: it is the one file in the package that opens with no application at all,
    /// and it carries the caveats that make the numbers honest. A figure that travels without its
    /// caveat becomes a wrong fact on somebody else's slide.
    static func readme(for input: Input) -> String {
        let coverage = input.coverage
        var lines: [String] = []

        lines.append("EXPORTACAO EXIMIABAR")
        lines.append("====================")
        lines.append("")
        lines.append("Gerado em: \(CSVWriter.isoDay(input.generatedAt))")
        lines.append("Versao do app: \(input.appVersion)")
        lines.append("Periodo pedido: \(input.periodLabel)")
        lines.append("")

        lines.append("COBERTURA DOS DADOS")
        lines.append("-------------------")
        if let first = coverage.firstDay, let last = coverage.lastDay {
            lines.append("Primeira data com dado: \(CSVWriter.isoDay(first))")
            lines.append("Ultima data com dado:   \(CSVWriter.isoDay(last))")
        } else {
            lines.append("Nao ha nenhum dia com dado neste periodo.")
        }
        lines.append("Dias com dado: \(coverage.daysWithData) de \(coverage.requestedDays) pedidos")
        if coverage.isPartial {
            lines.append("")
            lines.append("ATENCAO: a fonte cobre \(coverage.daysWithData) dos \(coverage.requestedDays) dias pedidos.")
            lines.append("Toda media rotulada \"por dia com uso\" divide por \(coverage.daysWithData).")
            lines.append("Dias anteriores ao inicio dos dados aparecem EM BRANCO, nunca como zero:")
            lines.append("dia sem dado nao e o mesmo que dia sem uso.")
        }
        lines.append("")

        lines.append("O CUSTO EM USD E ESTIMATIVA, NAO E FATURA")
        lines.append("-----------------------------------------")
        lines.append("O plano e por assinatura. O valor em dolar aqui e uma estimativa do valor")
        lines.append("consumido, calculada localmente a partir dos logs do Claude Code, e serve para")
        lines.append("comparar modelos, projetos e dias entre si. Nao e a conta a pagar e nao vem da")
        lines.append("Anthropic.")
        lines.append("")
        lines.append("Alem disso, o calculo NAO precifica os tokens de cache:")
        lines.append("  custo = entrada x preco_entrada + saida x preco_saida")
        lines.append("Os tokens de cache aparecem como VOLUME, nunca precificados. Quem somar a coluna")
        lines.append("de custo estimado vai SUBCONTAR o consumo real.")
        lines.append("")
        lines.append("Por isso a grandeza principal desta exportacao e o TOKEN, e o custo vem depois:")
        lines.append("as colunas comecam pelos tokens e os graficos primarios sao de volume.")
        lines.append("")

        lines.append("O QUE ABRE ONDE")
        lines.append("---------------")
        if input.panelHTML != nil {
            lines.append("painel.html    Abre em qualquer navegador, sem internet. Ja vem com os")
            lines.append("               graficos desenhados. E a peca principal.")
        }
        lines.append("planilha.xlsx  Abre no Excel, Numbers, Google Sheets ou LibreOffice. Ja vem")
        lines.append("               com os graficos e com as tabelas nomeadas.")
        lines.append("dados/*.csv    Grao fino, para quem quer modelar por conta propria.")
        lines.append("conectar-powerbi.pbids")
        lines.append("               Atalho para o Power BI abrir a pasta dados/ sem digitar caminho.")
        lines.append("               NAO traz visuais prontos: leva ao navegador de dados, e os")
        lines.append("               graficos sao montados por quem usa.")
        lines.append("")
        lines.append("Franqueza sobre o Power BI: o Power BI Desktop e so para Windows. A Microsoft")
        lines.append("nao publica versao para Mac e nao tem plano de publicar, e o servico web nao")
        lines.append("abre arquivo de conexao. Num Mac, o .pbids so e util levado para uma maquina")
        lines.append("Windows. Os graficos prontos estao na planilha e no painel, que abrem aqui.")
        lines.append("")

        lines.append("NOMES DE COLUNA")
        lines.append("---------------")
        lines.append("diario.csv, modelos.csv e projetos.csv usam nomes em portugues, para leitura.")
        if input.fact != nil {
            lines.append("fato.csv usa nomes tecnicos em snake_case de proposito: ele existe para ser")
            lines.append("consumido por ferramenta de BI, onde um identificador estavel vale mais que")
            lines.append("um rotulo bonito.")
        } else {
            lines.append("fato.csv NAO foi gerado nesta versao. O grao fino (dia x modelo, com custo e")
            lines.append("com a separacao de cache) ainda nao e preservado pelo app: o painel deriva os")
            lines.append("agregados e descarta as linhas. Quando existir, ele usara nomes tecnicos em")
            lines.append("snake_case de proposito, por ser destino de BI.")
            lines.append("Um fato.csv vazio seria pior que a ausencia dele: uma ferramenta de BI o")
            lines.append("ingere sem reclamar e reporta um periodo sem uso nenhum.")
        }
        lines.append("")

        lines.append("FORMATO DOS CSV")
        lines.append("---------------")
        lines.append("UTF-8 com BOM, separador virgula, ponto decimal, data em ISO (aaaa-mm-dd).")
        lines.append("Esta e a forma que toda ferramenta de BI le sem configurar nada.")
        lines.append("Ao abrir um .csv com duplo clique num Excel em portugues, as colunas ficam")
        lines.append("todas numa so, porque o Excel separa por ponto-e-virgula nessa configuracao.")
        lines.append("Para ler no Excel, use a planilha.xlsx, que ja vem formatada.")
        lines.append("Textos que comecam por = + - @ recebem um apostrofo na frente, para o Excel")
        lines.append("nao interpretar um nome de pasta como formula.")
        lines.append("")

        lines.append("OUTRAS RESSALVAS")
        lines.append("----------------")
        lines.append("Sessoes: quando exportadas, sao apenas as 10 de maior custo estimado, nao todas.")
        lines.append("Projetos: o nome e o ultimo componente do diretorio de trabalho, e vira")
        lines.append("\"Unknown\" quando o log nao traz esse dado. Duas pastas de mesmo nome em")
        lines.append("caminhos diferentes aparecem na mesma linha.")
        lines.append("Economia por cache: e estimativa, com leitura de cache a 0,1x o preco de entrada")
        lines.append("do modelo dominante da janela.")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}
