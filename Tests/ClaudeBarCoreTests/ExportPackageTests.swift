import Foundation
import Testing
@testable import ClaudeBarCore

/// Tests for the CSV dialect and the package assembly (EXB-6.7).
struct ExportPackageTests {
    // MARK: - CSV dialect

    /// The dialect, asserted where it is decided rather than inferred from a sample file.
    @Test
    func csvUsesTheDeclaredDialect() {
        let table = CSVTable(
            name: "t",
            header: ["Dia", "Tokens (total)", "Custo estimado (USD)"],
            rows: [[.date(ExportSampleWorkbook.firstDay), .integer(402_100), .number(1.9412, decimals: 4)]]
        )
        let bytes = CSVWriter.data(for: table)

        #expect(bytes.prefix(3) == CSVWriter.byteOrderMark, "Excel guesses the encoding without a BOM")
        let text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        #expect(text == "Dia,Tokens (total),Custo estimado (USD)\r\n2026-08-01,402100,1.9412\r\n")
    }

    /// A decimal comma would be read as a field separator; a thousands separator would be read as a
    /// second number. Neither is ever emitted.
    @Test
    func numbersCarryNoLocaleFormatting() {
        #expect(CSVWriter.field(.number(1234.5, decimals: 2)) == "1234.50")
        #expect(CSVWriter.field(.number(-0.75, decimals: 4)) == "-0.7500")
        #expect(CSVWriter.field(.integer(1_000_000)) == "1000000")
        #expect(CSVWriter.field(.number(.nan, decimals: 2)) == "")
    }

    /// A blank field is empty, not `0` — the distinction the whole coverage story rests on.
    @Test
    func blankIsEmptyAndZeroIsZero() {
        #expect(CSVWriter.field(.blank) == "")
        #expect(CSVWriter.field(.integer(0)) == "0")
    }

    /// Quoting follows RFC 4180: only when needed, with embedded quotes doubled.
    @Test
    func fieldsAreQuotedOnlyWhenTheyNeedIt() {
        #expect(CSVWriter.escape("simples") == "simples")
        #expect(CSVWriter.escape("com,virgula") == "\"com,virgula\"")
        #expect(CSVWriter.escape("com\"aspas") == "\"com\"\"aspas\"")
        #expect(CSVWriter.escape("com\nquebra") == "\"com\nquebra\"")
    }

    /// **CSV formula injection, the other half of the panel's escaping problem.**
    ///
    /// Project names are directory names, so a folder called `=cmd|'/c calc'!A1` reaches this writer
    /// verbatim. Excel evaluates any cell whose text starts with `=`, `+`, `-` or `@`, which turns
    /// opening the export into running whatever the folder is called.
    @Test
    func textThatLooksLikeAFormulaIsDefused() {
        #expect(CSVWriter.neutralizeFormula("=cmd|'/c calc'!A1") == "'=cmd|'/c calc'!A1")
        #expect(CSVWriter.neutralizeFormula("+1+1") == "'+1+1")
        #expect(CSVWriter.neutralizeFormula("-2+3") == "'-2+3")
        #expect(CSVWriter.neutralizeFormula("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSVWriter.neutralizeFormula("eximiabar") == "eximiabar")
    }

    /// The defusing must never touch numbers: `-` is in the dangerous set, so applying it to a numeric
    /// field would corrupt every negative value in the export.
    @Test
    func negativeNumbersAreNotDefused() {
        #expect(CSVWriter.field(.number(-1.5, decimals: 2)) == "-1.50")
        #expect(CSVWriter.field(.integer(-42)) == "-42")
        // But the same characters inside a *text* field still are.
        #expect(CSVWriter.field(.text("-42")) == "'-42")
    }

    // MARK: - Package structure

    /// The package carries the pieces the design names, at the paths it names.
    @Test
    func packageCarriesTheDeclaredFiles() {
        let files = ExportPackage.files(for: Self.input(), destination: URL(fileURLWithPath: "/tmp/pkg"))
        let paths = files.map(\.relativePath)
        #expect(paths == [
            "planilha.xlsx",
            "dados/diario.csv",
            "dados/modelos.csv",
            "dados/projetos.csv",
            "conectar-powerbi.pbids",
            "leia-me.txt",
        ])
    }

    /// The panel is another story's file. Until it exists the package does not pretend it does.
    @Test
    func panelAppearsOnlyWhenItIsSupplied() {
        let without = ExportPackage.files(for: Self.input(), destination: URL(fileURLWithPath: "/tmp/pkg"))
        #expect(!without.contains { $0.relativePath == "painel.html" })

        let with = ExportPackage.files(
            for: Self.input(panelHTML: "<!doctype html><html><body>ok</body></html>"),
            destination: URL(fileURLWithPath: "/tmp/pkg")
        )
        #expect(with.first?.relativePath == "painel.html", "the panel is the package's main piece")
    }

    /// **An absent `fato.csv` beats an empty one.** A BI tool ingests a header-only file without
    /// complaint and reports a period with no usage at all — a wrong answer delivered confidently.
    /// So while the app still discards the fine grain, the file is omitted and the notes say why.
    @Test
    func factIsOmittedRatherThanWrittenEmpty() throws {
        let files = ExportPackage.files(for: Self.input(), destination: URL(fileURLWithPath: "/tmp/pkg"))
        #expect(!files.contains { $0.relativePath == "dados/fato.csv" })

        let readme = try #require(files.first { $0.relativePath == "leia-me.txt" })
        let text = String(decoding: readme.contents, as: UTF8.self)
        #expect(text.contains("fato.csv NAO foi gerado nesta versao"))
        #expect(text.contains("vazio seria pior que a ausencia"))
    }

    /// And when the grain does arrive, the file is written with its technical names intact.
    @Test
    func factIsWrittenWithTechnicalNamesWhenSupplied() throws {
        let fact = CSVTable(
            name: "fato",
            header: ["dia", "modelo", "tokens_entrada", "tokens_saida", "cache_leitura", "cache_escrita", "custo_usd"],
            rows: [[.date(ExportSampleWorkbook.firstDay), .text("claude-opus-4"),
                    .integer(1), .integer(2), .integer(3), .integer(4), .number(0.5, decimals: 4)]]
        )
        let files = ExportPackage.files(for: Self.input(fact: fact), destination: URL(fileURLWithPath: "/tmp/pkg"))
        let entry = try #require(files.first { $0.relativePath == "dados/fato.csv" })
        let text = String(decoding: entry.contents.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("dia,modelo,tokens_entrada"))

        let readme = try #require(files.first { $0.relativePath == "leia-me.txt" })
        #expect(String(decoding: readme.contents, as: UTF8.self).contains("fato.csv usa nomes tecnicos"))
    }

    /// The readable CSVs must not carry database column names; `fato.csv` is the declared exception.
    @Test
    func readableCSVsUseHumanColumnNames() {
        for table in [Self.dailyTable(), Self.modelsTable(), Self.projectsTable()] {
            for name in table.header {
                #expect(!name.contains("_"), "\(table.name).csv: column \"\(name)\" is a database name")
            }
        }
    }

    // MARK: - .pbids

    /// AC2: valid JSON, with the documented folder protocol and an absolute path.
    @Test
    func powerBIConnectionFileIsValidJSON() throws {
        let destination = URL(fileURLWithPath: "/tmp/pkg/exportacao-eximiabar-2026-08-24")
        let json = ExportPackage.powerBIConnectionJSON(dataFolder: destination.appendingPathComponent("dados"))

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(parsed["version"] as? String == "0.1")
        let connections = try #require(parsed["connections"] as? [[String: Any]])
        let details = try #require(connections.first?["details"] as? [String: Any])
        #expect(details["protocol"] as? String == "folder")
        let address = try #require(details["address"] as? [String: Any])
        #expect(address["path"] as? String == "/tmp/pkg/exportacao-eximiabar-2026-08-24/dados")
        #expect(connections.first?["mode"] as? String == "Import")
    }

    /// A path with a quote or a backslash — both legal on this platform — must not break the JSON.
    @Test
    func awkwardPathsDoNotBreakTheConnectionFile() throws {
        let json = ExportPackage.powerBIConnectionJSON(
            dataFolder: URL(fileURLWithPath: #"/tmp/pasta "com aspas"/e\barra/dados"#)
        )
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let connections = try #require(parsed["connections"] as? [[String: Any]])
        let details = try #require(connections.first?["details"] as? [String: Any])
        let address = try #require(details["address"] as? [String: Any])
        #expect((address["path"] as? String)?.contains("\"com aspas\"") == true)
    }

    // MARK: - leia-me.txt

    /// The notes carry the caveats that make the numbers honest, and the one that makes them useful.
    @Test
    func readmeDeclaresCoverageAndTheCostCaveat() throws {
        let files = ExportPackage.files(for: Self.input(), destination: URL(fileURLWithPath: "/tmp/pkg"))
        let readme = try #require(files.first { $0.relativePath == "leia-me.txt" })
        let text = String(decoding: readme.contents, as: UTF8.self)

        // The fixture's data starts at offset 2 and ends at offset 7, counting from 2026-08-01 —
        // so 08-03 and 08-08, not 08-01 and 08-07. Written as literals rather than derived from the
        // fixture, because deriving them would make the assertion agree with any arithmetic mistake.
        #expect(text.contains("Primeira data com dado: 2026-08-03"))
        #expect(text.contains("Ultima data com dado:   2026-08-08"))
        #expect(text.contains("Dias com dado: 6 de 30 pedidos"))
        #expect(text.contains("a fonte cobre 6 dos 30 dias pedidos"))
        #expect(text.contains("EM BRANCO, nunca como zero"))

        #expect(text.contains("NAO E FATURA"))
        #expect(text.contains("assinatura"))
        #expect(text.contains("NAO precifica os tokens de cache"))
        #expect(text.contains("SUBCONTAR"))

        #expect(text.contains("Power BI Desktop e so para Windows"))
        #expect(text.contains("planilha.xlsx"))
    }

    /// A fully covered window must not print the partial-coverage warning — otherwise the warning is
    /// decoration rather than information.
    @Test
    func fullCoveragePrintsNoWarning() {
        let complete = ExportPackage.Coverage(
            firstDay: ExportSampleWorkbook.day(0),
            lastDay: ExportSampleWorkbook.day(29),
            daysWithData: 30,
            requestedDays: 30
        )
        let text = ExportPackage.readme(for: Self.input(coverage: complete))
        #expect(!text.contains("ATENCAO"))
        #expect(text.contains("Dias com dado: 30 de 30 pedidos"))
    }

    /// A window with no data at all says so, instead of printing an empty date range.
    @Test
    func emptyCoverageSaysSo() {
        let none = ExportPackage.Coverage(firstDay: nil, lastDay: nil, daysWithData: 0, requestedDays: 7)
        let text = ExportPackage.readme(for: Self.input(coverage: none))
        #expect(text.contains("Nao ha nenhum dia com dado"))
        #expect(!text.contains("Primeira data com dado:"))
    }

    // MARK: - Determinism and writing

    /// The package is a pure function of its inputs, generation instant included — which is why that
    /// instant is injected rather than read from the clock.
    @Test
    func packageBytesAreDeterministic() {
        let destination = URL(fileURLWithPath: "/tmp/pkg")
        let first = ExportPackage.files(for: Self.input(), destination: destination)
        let second = ExportPackage.files(for: Self.input(), destination: destination)
        #expect(first == second)

        let joined = { (files: [ExportPackage.File]) in
            files.reduce(into: Data()) { $0.append($1.contents) }
        }
        #expect(ExportTestSupport.sha256(joined(first)) == ExportTestSupport.sha256(joined(second)))
    }

    /// Only the date in the folder name varies with the clock.
    @Test
    func onlyTheFolderNameFollowsTheDate() {
        #expect(ExportPackage.folderName(for: ExportSampleWorkbook.day(0)) == "exportacao-eximiabar-2026-08-01")
        #expect(ExportPackage.folderName(for: ExportSampleWorkbook.day(23)) == "exportacao-eximiabar-2026-08-24")
    }

    /// The folder lands on disk with the structure it promises, and the workbook inside it is still a
    /// valid archive after the round trip.
    @Test
    func packageIsWrittenToDisk() throws {
        let parent = ExportTestSupport.temporaryDirectory()
        let root = try ExportPackage.write(Self.input(), under: parent)

        #expect(root.lastPathComponent == "exportacao-eximiabar-2026-08-24")
        for relative in ["planilha.xlsx", "dados/diario.csv", "conectar-powerbi.pbids", "leia-me.txt"] {
            #expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                "missing \(relative)"
            )
        }

        let unzip = try ExportTestSupport.run("/usr/bin/unzip", ["-t", root.appendingPathComponent("planilha.xlsx").path])
        #expect(unzip.status == 0)

        // python3 -m json.tool is the AC's own verifier, run as written.
        let interpreter = try #require(ExportTestSupport.pythonInterpreter)
        let tool = try ExportTestSupport.run(
            interpreter, ["-m", "json.tool", root.appendingPathComponent("conectar-powerbi.pbids").path]
        )
        #expect(tool.status == 0, "json.tool rejected the .pbids: \(tool.standardError)")
        #expect(tool.standardOutput.contains("\"protocol\": \"folder\""))
    }

    // MARK: - Package convergence

    /// **The gate that did not exist, and why it did not.** Each front tested its own piece against
    /// its own expectation, and both passed — the comparison *between* pieces belonged to nobody. So
    /// the panel's legend said `Entrada` and `Cache — leitura` while the same package's spreadsheet
    /// said `Tokens de entrada` and `Cache de leitura`, and every test in the repo was green.
    ///
    /// This one reads the assembled package and compares the artifacts against each other.
    @Test
    func panelAndWorkbookAgreeOnEveryLabel() throws {
        let files = ExportPackage.files(
            for: Self.input(panelHTML: PainelHTMLWriter.render(PainelSampleData.make())),
            destination: URL(fileURLWithPath: "/tmp/pkg")
        )
        let panel = try #require(files.first { $0.relativePath == "painel.html" })
        let panelText = String(decoding: panel.contents, as: UTF8.self)
        let csv = try #require(files.first { $0.relativePath == "dados/diario.csv" })
        let csvHeader = String(decoding: csv.contents.dropFirst(3), as: UTF8.self)
            .components(separatedBy: "\r\n")[0]
        let sheet = try Self.dailySheetXML(in: files)

        // Every token label must appear, verbatim, in all three artifacts of the package.
        for label in ExportLabels.Token.todos {
            #expect(panelText.contains(label), "painel.html is missing the label \"\(label)\"")
            #expect(sheet.contains(XLSXWriter.escape(label)), "planilha.xlsx is missing \"\(label)\"")
            #expect(csvHeader.contains(label), "diario.csv is missing \"\(label)\"")
        }
    }

    /// The same, for the numbers: the daily totals the panel plots and the ones the CSV carries have
    /// to be the same figures, or the package contradicts itself where it matters most.
    @Test
    func panelAndCSVAgreeOnTheDailyTotals() throws {
        let files = ExportPackage.files(for: Self.input(), destination: URL(fileURLWithPath: "/tmp/pkg"))
        let csv = try #require(files.first { $0.relativePath == "dados/diario.csv" })
        let lines = String(decoding: csv.contents.dropFirst(3), as: UTF8.self)
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .dropFirst()

        #expect(lines.count == ExportSampleWorkbook.dailyRows.count)
        for (line, expected) in zip(lines, ExportSampleWorkbook.dailyRows) {
            let fields = line.components(separatedBy: ",")
            let total = expected.input + expected.output + expected.cacheRead + expected.cacheWrite
            #expect(fields[1] == String(Int(total)), "total differs on \(fields[0])")
            #expect(fields[6] == String(format: "%.4f", expected.cost), "cost differs on \(fields[0])")
        }
    }

    /// No artifact of the package may spell a shared label as a literal of its own — that is the
    /// condition under which the two gates above stay meaningful instead of drifting back apart.
    @Test
    func noArtifactSpellsASharedLabelItself() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ClaudeBarCore/Export")
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where name.hasSuffix(".swift") && name != "ExportLabels.swift" {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for label in ExportLabels.Token.todos {
                #expect(!Self.stripComments(source).contains("\"\(label)\""),
                        "\(name) spells \"\(label)\" itself instead of reading ExportLabels")
            }
        }
    }

    /// Source with `//` comment lines removed.
    ///
    /// The first version of the gate above scanned raw source and reported `PainelHTMLWriter.swift`
    /// for the comment that *explains* the divergence — the detector accusing its own documentation.
    /// A comment quoting a label is the opposite of a duplicated literal: it is the record of why the
    /// literal is gone.
    static func stripComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The daily sheet's XML, out of the workbook inside the package.
    static func dailySheetXML(in files: [ExportPackage.File]) throws -> String {
        let workbook = try #require(files.first { $0.relativePath == "planilha.xlsx" })
        let url = ExportTestSupport.temporaryDirectory().appendingPathComponent("planilha.xlsx")
        try workbook.contents.write(to: url)
        let extracted = try ExportTestSupport.extract(url)
        return try String(
            contentsOf: extracted.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8
        )
    }

    // MARK: - Integration with the real panel

    /// The panel is carried into the package byte for byte, as the first piece.
    ///
    /// No code changed to make this work: `Input.panelHTML` is a `String`, so the package has no API
    /// coupling to whatever builds the panel. This test is the proof that the joint holds with the
    /// real writer rather than with a stub.
    @Test
    func realPanelIsCarriedIntoThePackageUnchanged() throws {
        let html = PainelHTMLWriter.render(PainelSampleData.make())
        let files = ExportPackage.files(
            for: Self.input(panelHTML: html), destination: URL(fileURLWithPath: "/tmp/pkg")
        )

        let panel = try #require(files.first)
        #expect(panel.relativePath == "painel.html", "the panel is the package's main piece")
        #expect(panel.contents == Data(html.utf8), "the package must not re-encode the panel")
        #expect(files.map(\.relativePath) == [
            "painel.html",
            "planilha.xlsx",
            "dados/diario.csv",
            "dados/modelos.csv",
            "dados/projetos.csv",
            "conectar-powerbi.pbids",
            "leia-me.txt",
        ])

        // The notes describe the panel only when the panel is actually there.
        let readme = try #require(files.first { $0.relativePath == "leia-me.txt" })
        #expect(String(decoding: readme.contents, as: UTF8.self).contains("painel.html    Abre em qualquer navegador"))
    }

    /// Determinism survives the panel. It is the largest piece by far, and the one built by another
    /// front — if anything in the package were going to acquire a timestamp or a hash-ordered
    /// dictionary, it would show up here.
    @Test
    func packageWithPanelIsStillDeterministic() {
        let destination = URL(fileURLWithPath: "/tmp/pkg")
        let first = ExportPackage.files(
            for: Self.input(panelHTML: PainelHTMLWriter.render(PainelSampleData.make())),
            destination: destination
        )
        let second = ExportPackage.files(
            for: Self.input(panelHTML: PainelHTMLWriter.render(PainelSampleData.make())),
            destination: destination
        )
        #expect(first == second)
    }

    /// The sample package, for a human to open. Written beside the sample workbook, outside the repo.
    @Test
    func writesSamplePackageForInspection() throws {
        let parent = URL(fileURLWithPath: "/tmp/eximiabar-export")
        try? FileManager.default.removeItem(
            at: parent.appendingPathComponent(ExportPackage.folderName(for: Self.generatedAt))
        )
        let root = try ExportPackage.write(
            Self.input(panelHTML: PainelHTMLWriter.render(PainelSampleData.make())),
            under: parent
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("painel.html").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("planilha.xlsx").path))
    }

    // MARK: - Fixtures

    /// 2026-08-24T00:00:00Z.
    static let generatedAt = ExportSampleWorkbook.day(23)

    static func input(
        coverage: ExportPackage.Coverage? = nil,
        panelHTML: String? = nil,
        fact: CSVTable? = nil
    ) -> ExportPackage.Input {
        ExportPackage.Input(
            generatedAt: generatedAt,
            appVersion: "2.4.0",
            periodLabel: "Ultimos 30 dias",
            coverage: coverage ?? ExportPackage.Coverage(
                firstDay: ExportSampleWorkbook.day(2),
                lastDay: ExportSampleWorkbook.day(7),
                daysWithData: ExportSampleWorkbook.dailyRows.count,
                requestedDays: 30
            ),
            workbook: XLSXWriter.data(for: ExportSampleWorkbook.make()),
            panelHTML: panelHTML,
            daily: dailyTable(),
            models: modelsTable(),
            projects: projectsTable(),
            fact: fact
        )
    }

    /// The same numbers as the workbook's `Diario` sheet, so the two artifacts of the package cannot
    /// disagree by construction.
    static func dailyTable() -> CSVTable {
        CSVTable(
            name: "diario",
            header: ExportSampleWorkbook.dailyHeader,
            rows: ExportSampleWorkbook.dailyRows.map { entry in
                let total = entry.input + entry.output + entry.cacheRead + entry.cacheWrite
                return [
                    .date(ExportSampleWorkbook.day(entry.offset)),
                    .integer(Int(total)),
                    .integer(Int(entry.input)),
                    .integer(Int(entry.output)),
                    .integer(Int(entry.cacheRead)),
                    .integer(Int(entry.cacheWrite)),
                    .number(entry.cost, decimals: 4),
                ]
            }
        )
    }

    static func modelsTable() -> CSVTable {
        CSVTable(
            name: "modelos",
            header: ExportSampleWorkbook.modelsHeader,
            rows: ExportSampleWorkbook.modelRows
                .sorted { $0.input + $0.output > $1.input + $1.output }
                .map { entry in
                    [
                        .text(entry.name),
                        .integer(Int(entry.input + entry.output)),
                        .integer(Int(entry.input)),
                        .integer(Int(entry.output)),
                        .number(entry.cost, decimals: 4),
                    ]
                }
        )
    }

    static func projectsTable() -> CSVTable {
        CSVTable(
            name: "projetos",
            header: ExportSampleWorkbook.projectsHeader,
            rows: ExportSampleWorkbook.projectRows.map { entry in
                [.text(entry.name), .integer(Int(entry.tokens)), .number(entry.cost, decimals: 4)]
            }
        )
    }
}
