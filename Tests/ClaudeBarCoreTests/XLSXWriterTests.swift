import Foundation
import Testing
@testable import ClaudeBarCore

/// Tests for ``XLSXWriter`` (EXB-6.2).
struct XLSXWriterTests {
    // MARK: - Package structure

    /// AC1: the parts an `.xlsx` must carry are all present, at the paths the format fixes.
    @Test
    func packageCarriesTheRequiredParts() {
        let paths = XLSXWriter.entries(for: ExportSampleWorkbook.make()).map(\.path)
        for required in [
            "[Content_Types].xml",
            "_rels/.rels",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels",
            "xl/styles.xml",
            "xl/worksheets/sheet1.xml",
            "xl/tables/table1.xml",
        ] {
            #expect(paths.contains(required), "missing part: \(required)")
        }
    }

    /// Every part declared in `[Content_Types].xml` must actually exist in the archive, and every part
    /// that needs an override must have one. A dangling override is one of the ways Excel refuses the
    /// whole workbook while every individual document is well formed.
    @Test
    func contentTypeOverridesMatchTheArchiveExactly() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let paths = Set(entries.map(\.path))
        let contentTypes = try #require(entries.first { $0.path == "[Content_Types].xml" })
        let xml = String(decoding: contentTypes.payload, as: UTF8.self)

        var declared: Set<String> = []
        var remainder = Substring(xml)
        while let start = remainder.range(of: "PartName=\"/") {
            remainder = remainder[start.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { break }
            declared.insert(String(remainder[..<end]))
            remainder = remainder[end...]
        }

        for part in declared {
            #expect(paths.contains(part), "[Content_Types].xml declares a part that is not in the archive: \(part)")
        }
        // Everything that is not covered by a Default extension needs an override.
        for path in paths where path.hasPrefix("xl/") && !path.contains("_rels") {
            #expect(declared.contains(path), "part has no content-type override: \(path)")
        }
    }

    /// Each sheet's relationship targets must resolve to real parts. A drawing rel pointing at a
    /// drawing that was never written is a silent way to lose every chart on a sheet.
    @Test
    func sheetRelationshipTargetsResolve() {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let paths = Set(entries.map(\.path))
        for entry in entries where entry.path.hasSuffix(".rels") && entry.path.contains("worksheets") {
            let xml = String(decoding: entry.payload, as: UTF8.self)
            for target in Self.attributeValues(of: "Target", in: xml) {
                let resolved = "xl/" + target.replacingOccurrences(of: "../", with: "")
                #expect(paths.contains(resolved), "unresolved relationship target: \(target)")
            }
        }
    }

    // MARK: - Cells

    /// AC2: dates go in as Excel serials with a date format, never as text.
    ///
    /// 2000-01-01 is serial 36526 — a published value, so this fails if the epoch is off by the Lotus
    /// 1-2-3 leap-year quirk (the classic one-day error).
    @Test
    func datesAreWrittenAsSerialNumbers() {
        let millennium = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01T00:00:00Z
        #expect(XLSXDateSerial.serial(for: millennium) == 36_526)

        let xml = try! #require(XLSXWriter.cellXML(.date(millennium), row: 1, column: 0))
        #expect(xml.contains("<v>36526</v>"))
        #expect(!xml.contains("inlineStr"), "a date written as text loses its type in every reader")
        #expect(xml.contains(#"s="\#(XLSXStyle.date.rawValue)""#))
    }

    /// A blank produces no cell element at all — which is what keeps "no data" distinguishable from
    /// "used nothing" (D6). Writing `0` here would make July read as a month of zero usage.
    @Test
    func blankIsAbsenceAndZeroIsAValue() {
        #expect(XLSXWriter.cellXML(.blank, row: 2, column: 1) == nil)

        let zero = try! #require(XLSXWriter.cellXML(.number(0, .integer), row: 2, column: 1))
        #expect(zero.contains("<v>0</v>"))
    }

    /// The two days before the fixture's coverage carry a date and nothing else — the invariant read
    /// straight off the emitted sheet, not off the model.
    @Test
    func daysBeforeCoverageHaveNoValueCells() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let sheet = try #require(entries.first { $0.path == "xl/worksheets/sheet1.xml" })
        let xml = String(decoding: sheet.payload, as: UTF8.self)
        // Rows 2 and 3 of the sheet are the uncovered days: column A only.
        for row in [2, 3] {
            #expect(xml.contains(#"<c r="A\#(row)""#), "row \(row) should still carry its date")
            #expect(!xml.contains(#"<c r="B\#(row)""#), "row \(row) must have no value cell in column B")
            #expect(!xml.contains(#"<c r="G\#(row)""#), "row \(row) must have no value cell in column G")
        }
        // And a covered day does have them, or the assertions above would pass on an empty sheet.
        #expect(xml.contains(#"<c r="B4""#))
        #expect(xml.contains(#"<c r="G4""#))
    }

    /// Numbers must never be written in a form XML cannot carry.
    @Test
    func nonFiniteNumbersAreDroppedRatherThanWritten() {
        #expect(XLSXWriter.numberLiteral(.nan) == nil)
        #expect(XLSXWriter.numberLiteral(.infinity) == nil)
        #expect(XLSXWriter.cellXML(.number(.nan, .integer), row: 0, column: 0) == nil)
        #expect(XLSXWriter.numberLiteral(1.5) == "1.5")
        #expect(XLSXWriter.numberLiteral(42) == "42")
    }

    /// Text from the filesystem is arbitrary. Markup characters are escaped and control characters are
    /// dropped, because either one takes the whole workbook down.
    @Test
    func textIsEscapedAndControlCharactersAreDropped() {
        let escaped = XLSXWriter.escape("a < b & c > d \" e ' f")
        #expect(escaped == "a &lt; b &amp; c &gt; d &quot; e &apos; f")
        #expect(!escaped.contains("<"))

        let cleaned = XLSXWriter.escape("bell\u{0007}here\ttab")
        #expect(cleaned == "bellhere\ttab", "C0 controls other than tab/LF/CR are invalid in XML 1.0")
    }

    /// The hostile project name in the fixture survives into a well-formed document.
    @Test
    func hostileProjectNameDoesNotEscapeItsCell() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let sheet = try #require(entries.first { $0.path == "xl/worksheets/sheet3.xml" })
        let xml = String(decoding: sheet.payload, as: UTF8.self)
        #expect(!xml.contains("<img src=x"), "raw markup leaked out of the cell")
        #expect(xml.contains("&lt;/script&gt;&lt;img src=x"))
        // Still a parseable document: the escaping did not just hide the markup, it neutralised it.
        let document = try XMLDocument(xmlString: xml)
        let texts = try document.nodes(forXPath: "//is/t").compactMap(\.stringValue)
        #expect(texts.contains(ExportSampleWorkbook.hostileProjectName),
                "the name must survive verbatim once decoded")
    }

    // MARK: - Human labels

    /// The owner asked for a spreadsheet "pronta para entender", so no sheet a person reads may carry
    /// a database column name.
    ///
    /// The `Fato` sheet is the declared exception — it exists to be consumed by a BI tool, where a
    /// stable snake_case identifier is worth more than a pretty one. It belongs to a later story and
    /// does not exist here yet; when it arrives it must be excluded from this check by name, not by
    /// weakening the rule.
    @Test
    func noReadableSheetCarriesDatabaseColumnNames() {
        let technicalExceptions = ["Fato"]
        for sheet in ExportSampleWorkbook.make().sheets where !technicalExceptions.contains(sheet.name) {
            guard let header = sheet.rows.first else { continue }
            for cell in header {
                guard case let .text(label, _) = cell else { continue }
                #expect(!label.contains("_"), "\(sheet.name): header \"\(label)\" is a database name")
            }
        }
    }

    /// The labels themselves, asserted literally rather than by heuristic.
    ///
    /// A first attempt checked "the first character is uppercase" and failed on `claude-opus-4`, which
    /// is correct data: in the pivoted matrix the headers **are** model identifiers, not labels anyone
    /// chose. The heuristic was measuring the wrong thing, so it was replaced by the exact expectation.
    @Test
    func readableHeadersAreTheAgreedLabels() {
        #expect(ExportSampleWorkbook.dailyHeader == [
            "Dia", "Tokens (total)", "Tokens de entrada", "Tokens de saída",
            "Cache de leitura", "Cache de escrita", "Custo estimado (USD)",
        ])
        #expect(ExportSampleWorkbook.modelsHeader.first == "Modelo")
        #expect(ExportSampleWorkbook.projectsHeader == ["Projeto", "Tokens (total)", "Custo estimado (USD)"])

        // The matrix sheet's headers after the first are data, and stay verbatim.
        let matrix = ExportSampleWorkbook.modelsByDay()
        #expect(Self.headerLabels(of: matrix).first == "Dia")
        #expect(Self.headerLabels(of: matrix).dropFirst() == ArraySlice(ExportSampleWorkbook.modelRows.map(\.name)))
    }

    /// The text of a sheet's header row.
    static func headerLabels(of sheet: XLSXSheet) -> [String] {
        (sheet.rows.first ?? []).compactMap { cell in
            if case let .text(value, _) = cell { value } else { nil }
        }
    }

    /// Accented pt-BR survives the round trip through UTF-8 and XML escaping — `Tokens de saída`
    /// arriving as `Tokens de sa?da` would be a defect only a human would notice.
    @Test
    func accentedLabelsSurviveIntoTheSheet() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let sheet = try #require(entries.first { $0.path == "xl/worksheets/sheet1.xml" })
        let document = try XMLDocument(data: sheet.payload)
        let texts = try document.nodes(forXPath: "//is/t").compactMap(\.stringValue)
        #expect(texts.contains("Tokens de saída"))
        #expect(texts.contains("Cache de leitura"))
        #expect(texts.contains("Custo estimado (USD)"))
    }

    // MARK: - Formula invariant (I6)

    /// AC4 / I6: no worksheet carries a formula. An `<f>` with no cached `<v>` reads as an empty cell
    /// until the reader recalculates, and Power BI's Excel connector reads the cache, not the formula.
    ///
    /// Honest note: the writer has no code path that can emit `<f>`, so this passes trivially today.
    /// It is a regression canary for whoever adds one later, not a discovery.
    @Test
    func noWorksheetContainsAFormula() {
        for entry in XLSXWriter.entries(for: ExportSampleWorkbook.make())
        where entry.path.hasPrefix("xl/worksheets/") {
            let xml = String(decoding: entry.payload, as: UTF8.self)
            #expect(!xml.contains("<f>"), "\(entry.path) contains a formula")
            #expect(!xml.contains("<f "), "\(entry.path) contains a formula")
        }
    }

    /// The invariant has a cost, and the cost is that derived values must be real. The daily totals in
    /// the fixture are the sum of the four token columns, written as literals — this checks the totals
    /// on the sheet actually equal that sum, which is the thing a formula would otherwise have done.
    @Test
    func derivedTotalsAreWrittenAsComputedLiterals() throws {
        let sheet = ExportSampleWorkbook.daily()
        for (index, entry) in ExportSampleWorkbook.dailyRows.enumerated() {
            let row = sheet.rows[index + 3] // header + two uncovered days
            guard case let .number(total, _) = row[1] else {
                Issue.record("row \(index) has no total")
                continue
            }
            #expect(total == entry.input + entry.output + entry.cacheRead + entry.cacheWrite)
        }
    }

    // MARK: - Styles

    /// AC3: the number formats the workbook promises are in the style table.
    ///
    /// Asserted after XML-decoding, not as a raw substring: an attribute value must escape `"`, so a
    /// valid file spells the currency format `&quot;$&quot;#,##0.0000`. Grepping for the literal
    /// `"$"#,##0.0000` in the bytes fails against every conforming writer, openpyxl included.
    @Test
    func styleTableCarriesTheDeclaredNumberFormats() throws {
        let xml = XLSXWriter.stylesXML()
        let document = try XMLDocument(xmlString: xml)
        let codes = Set(
            try document.nodes(forXPath: "//numFmt/@formatCode").compactMap { $0.stringValue }
        )
        #expect(codes.contains("#,##0"))
        #expect(codes.contains("\"$\"#,##0.00"))
        #expect(codes.contains("\"$\"#,##0.0000"))
        #expect(codes.contains("0.0%"))
        #expect(codes.contains("00\"h\""))
        #expect(codes.contains("yyyy-mm-dd"))
    }

    /// A cell's `s=` attribute is the style's raw value, so the style table's row order and the enum
    /// must not drift apart. Checked by counting: one `cellXfs` entry per case, in order.
    @Test
    func cellStyleIndicesLineUpWithTheEnum() throws {
        let document = try XMLDocument(xmlString: XLSXWriter.stylesXML())
        let entries = try document.nodes(forXPath: "//cellXfs/xf")
        #expect(entries.count == XLSXStyle.allCases.count)
        for style in XLSXStyle.allCases where style.numberFormatCode != nil {
            let element = try #require(entries[style.rawValue] as? XMLElement)
            let id = element.attribute(forName: "numFmtId")?.stringValue
            #expect(id == String(XLSXWriter.numberFormatID(for: style)),
                    "style \(style) points at the wrong number format")
        }
    }

    // MARK: - Freeze, widths, colour scale

    /// AC5: the header row is frozen on the sheets that ask for it.
    @Test
    func headerIsFrozenWhenRequested() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let frozen = try #require(entries.first { $0.path == "xl/worksheets/sheet1.xml" })
        #expect(String(decoding: frozen.payload, as: UTF8.self).contains(#"state="frozen""#))

        // A sheet that did not ask for it must not get it, or the assertion above proves nothing.
        let plain = XLSXWriter.entries(for: XLSXWorkbook(sheets: [
            XLSXSheet(name: "Plain", rows: [[.text("a", .normal)]]),
        ]))
        let xml = String(decoding: plain[5].payload, as: UTF8.self)
        #expect(!xml.contains("frozen"))
    }

    /// `<cols>` is either absent or has content. An empty `<cols></cols>` is schema-invalid, and a
    /// sheet with no rows is the case that would produce one.
    @Test
    func emptyColumnsElementIsNeverEmitted() {
        let empty = XLSXWriter.entries(for: XLSXWorkbook(sheets: [XLSXSheet(name: "Vazia", rows: [])]))
        let xml = String(decoding: empty[5].payload, as: UTF8.self)
        #expect(!xml.contains("<cols>"), "a sheet with no rows must not emit an empty <cols>")

        let populated = XLSXWriter.entries(for: XLSXWorkbook(sheets: [
            XLSXSheet(name: "Cheia", rows: [[.text("Dia", .header)]]),
        ]))
        let populatedXML = String(decoding: populated[5].payload, as: UTF8.self)
        #expect(populatedXML.contains("<cols><col "), "a sheet with rows must declare its widths")
        #expect(!populatedXML.contains("<cols></cols>"))
    }

    /// Every column of every sheet gets an explicit width — none is left on Excel's ~8.43 default,
    /// which is narrower than almost every header this workbook writes.
    @Test
    func everyColumnOfEverySheetGetsAWidth() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        for (index, sheet) in ExportSampleWorkbook.make().sheets.enumerated() {
            let part = try #require(entries.first { $0.path == "xl/worksheets/sheet\(index + 1).xml" })
            let xml = String(decoding: part.payload, as: UTF8.self)
            let declared = Self.attributeValues(of: "min", in: xml).count
            let columnCount = sheet.rows.map(\.count).max() ?? 0
            #expect(declared == columnCount, "\(sheet.name): \(declared) widths for \(columnCount) columns")
        }
    }

    /// **The defect the structural tests could not see.** A header clipped to `cache_l` is a column
    /// nobody can identify, and the XML is perfectly valid while it happens — only a human opening the
    /// file notices. So the width is floored at what the header needs, on every column of every sheet.
    @Test
    func noHeaderIsEverNarrowerThanItsColumn() {
        for sheet in ExportSampleWorkbook.make().sheets {
            let widths = XLSXWriter.resolvedColumnWidths(for: sheet)
            guard let header = sheet.rows.first else { continue }
            for (column, cell) in header.enumerated() {
                guard case let .text(label, _) = cell else { continue }
                let width = try! #require(widths.first { $0.column == column }).width
                #expect(width >= Double(label.count),
                        "\(sheet.name): header \"\(label)\" (\(label.count) chars) in a column of \(width)")
            }
        }
    }

    /// The floor is not just "wide enough", it leaves room for the filter button a table draws over
    /// the header cell — the button is what does the clipping when the width only just fits.
    @Test
    func tableHeadersLeaveRoomForTheFilterButton() throws {
        let rows: [[XLSXCell]] = [
            [.text("Custo estimado (USD)", .header)],
            [.number(1, .currency2)],
        ]
        let withTable = XLSXWriter.resolvedColumnWidths(
            for: XLSXSheet(name: "T", rows: rows, table: XLSXTable(name: "Tbl"))
        )
        let without = XLSXWriter.resolvedColumnWidths(for: XLSXSheet(name: "P", rows: rows))
        #expect(withTable[0].width > without[0].width)
        #expect(without[0].width >= 20 + 2)
    }

    /// An explicit width may widen a column past the floor, but never narrow it below the header —
    /// there is no case where clipping a title is what the caller meant.
    @Test
    func explicitWidthWidensButCannotClipTheHeader() {
        let rows: [[XLSXCell]] = [[.text("Custo estimado (USD)", .header)], [.number(1, .currency2)]]

        let tooNarrow = XLSXWriter.resolvedColumnWidths(for: XLSXSheet(
            name: "N", rows: rows, columns: [XLSXColumnWidth(column: 0, width: 4)]
        ))
        #expect(tooNarrow[0].width >= 20, "an explicit width must not be able to clip the header")

        let generous = XLSXWriter.resolvedColumnWidths(for: XLSXSheet(
            name: "W", rows: rows, columns: [XLSXColumnWidth(column: 0, width: 40)]
        ))
        #expect(generous[0].width == 40, "an explicit width wider than the floor must be honoured")
    }

    /// Long values still widen a column past its header, or a 12-digit token count would be shown as
    /// `########`.
    @Test
    func wideValuesWidenTheColumnBeyondTheHeader() {
        let widths = XLSXWriter.resolvedColumnWidths(for: XLSXSheet(name: "V", rows: [
            [.text("Dia", .header)],
            [.number(123_456_789_012, .integer)],
        ]))
        // 12 digits plus 3 grouping separators plus padding.
        #expect(widths[0].width >= 17)
    }

    /// The rendered length accounts for what the *format* adds, not just the digits — grouping
    /// separators, decimals and the currency sign are what overflow a column.
    @Test
    func renderedNumberLengthCountsTheFormatNotJustTheDigits() {
        #expect(XLSXWriter.renderedNumberLength(402_100, style: .integer) == 7)      // 402.100
        #expect(XLSXWriter.renderedNumberLength(1.9412, style: .currency4) == 7)     // $1,9412
        #expect(XLSXWriter.renderedNumberLength(6.1044, style: .currency2) == 5)     // $6,10
        #expect(XLSXWriter.renderedNumberLength(0.42, style: .percent) == 5)         // 42,0%
        #expect(XLSXWriter.renderedNumberLength(14, style: .hour) == 3)              // 14h
    }

    /// AC7 of the sheets story, exercised here: exactly one colour scale, over the 7×24 block.
    @Test
    func heatmapCarriesExactlyOneColorScale() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let sheets = entries.filter { $0.path.hasPrefix("xl/worksheets/sheet") && $0.path.hasSuffix(".xml") }
        let occurrences = sheets.reduce(0) { total, entry in
            total + String(decoding: entry.payload, as: UTF8.self).components(separatedBy: #"type="colorScale""#).count - 1
        }
        #expect(occurrences == 1)

        let heatmap = try #require(entries.first { $0.path == "xl/worksheets/sheet5.xml" })
        #expect(String(decoding: heatmap.payload, as: UTF8.self).contains(#"sqref="B2:Y8""#))
    }

    // MARK: - Tables

    /// The table's range covers the header plus every body row, and its column names come from the
    /// header. That range is what the Power BI navigator lists — off by one row and the last day of
    /// data disappears from the model without any error.
    @Test
    func tableSpansHeaderAndBody() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let table = try #require(entries.first { $0.path == "xl/tables/table1.xml" })
        let document = try XMLDocument(data: table.payload)
        let root = try #require(document.rootElement())
        #expect(root.attribute(forName: "name")?.stringValue == "TblDiario")

        let rowCount = ExportSampleWorkbook.daily().rows.count
        #expect(root.attribute(forName: "ref")?.stringValue == "A1:G\(rowCount)")

        let columns = try document.nodes(forXPath: "//tableColumn/@name").compactMap(\.stringValue)
        #expect(columns == ExportSampleWorkbook.dailyHeader)
    }

    /// A one-row sheet gets no table: Excel rejects a table whose body is empty, and a rejected table
    /// takes the whole workbook with it.
    @Test
    func tableIsSkippedWhenThereIsNoBody() {
        let entries = XLSXWriter.entries(for: XLSXWorkbook(sheets: [
            XLSXSheet(name: "Vazio", rows: [[.text("a", .header)]], table: XLSXTable(name: "TblVazio")),
        ]))
        #expect(!entries.contains { $0.path.hasPrefix("xl/tables/") })
    }

    /// Duplicate and blank header labels are repaired, because Excel silently refuses a table whose
    /// column names repeat.
    @Test
    func tableColumnNamesAreMadeUniqueAndNonEmpty() {
        let names = XLSXWriter.tableColumnNames(header: [
            .text("dia", .header), .text("dia", .header), .blank, .text("", .header),
        ])
        #expect(names == ["dia", "dia 2", "Coluna 3", "Coluna 4"])
        #expect(Set(names).count == names.count)
    }

    // MARK: - Name sanitisation (R4)

    /// Excel forbids `[ ] : * ? / \` and names over 31 characters. A name it refuses is not a warning;
    /// the file simply does not open.
    @Test
    func sheetNamesAreSanitised() {
        #expect(XLSXWriter.sanitizeSheetName("Rel: 2026/08 [rascunho] *?") == "Rel 202608 rascunho ")
        #expect(XLSXWriter.sanitizeSheetName(String(repeating: "a", count: 40)).count == 31)
        #expect(XLSXWriter.sanitizeSheetName("") == "Sheet")
        #expect(XLSXWriter.sanitizeSheetName("'quoted'") == "quoted")
    }

    /// Two sheets that sanitise to the same name must still end up distinct — Excel compares tab names
    /// case-insensitively.
    @Test
    func sheetNamesAreMadeUnique() {
        let workbook = XLSXWorkbook(sheets: [
            XLSXSheet(name: "Resumo", rows: [[.text("a", .normal)]]),
            XLSXSheet(name: "resumo", rows: [[.text("b", .normal)]]),
            XLSXSheet(name: "Re[su]mo", rows: [[.text("c", .normal)]]),
        ])
        let plan = XLSXWriter.Plan(workbook: workbook)
        let names = plan.sheets.map(\.name)
        #expect(names == ["Resumo", "resumo2", "Resumo3"])
        #expect(Set(names.map { $0.lowercased() }).count == 3)
    }

    /// Table names allow only letters, digits and underscore, and cannot start with a digit.
    @Test
    func tableNamesAreSanitised() {
        #expect(XLSXWriter.sanitizeTableName("Tbl Diario-2026") == "Tbl_Diario_2026")
        #expect(XLSXWriter.sanitizeTableName("2026") == "_2026")
        #expect(XLSXWriter.sanitizeTableName("") == "Table")
    }

    // MARK: - Determinism

    /// The whole workbook is byte-stable, which is what makes a sha256 usable as a regression test on
    /// the generated artifact.
    @Test
    func workbookBytesAreDeterministic() {
        let first = XLSXWriter.data(for: ExportSampleWorkbook.make())
        let second = XLSXWriter.data(for: ExportSampleWorkbook.make())
        #expect(ExportTestSupport.sha256(first) == ExportTestSupport.sha256(second))
    }

    // MARK: - Independent verifiers

    /// Every emitted part parses as XML. Cheap, and it catches the unbalanced-tag class of mistake
    /// before the expensive verifiers run.
    @Test
    func everyPartIsWellFormedXML() throws {
        for entry in XLSXWriter.entries(for: ExportSampleWorkbook.make()) {
            #expect(throws: Never.self, "\(entry.path) is not well-formed XML") {
                _ = try XMLDocument(data: entry.payload)
            }
        }
    }

    /// Info-ZIP accepts the container, and openpyxl — a parser nobody here wrote — reads back the
    /// cells, the number formats, the column width and the named table.
    @Test
    func openpyxlReadsBackTheWorkbook() throws {
        let url = try Self.writeSample()
        let unzip = try ExportTestSupport.run("/usr/bin/unzip", ["-t", url.path])
        #expect(unzip.status == 0, "unzip -t rejected the workbook: \(unzip.standardOutput)\(unzip.standardError)")

        guard ExportTestSupport.hasOpenpyxl() else {
            Issue.record("openpyxl unavailable — skipping the independent spreadsheet parser")
            return
        }
        let result = try #require(try ExportTestSupport.python("""
        import openpyxl, json
        wb = openpyxl.load_workbook(r"\(url.path)")
        ws = wb["Diario"]
        print(json.dumps({
            "sheets": wb.sheetnames,
            "header": [c.value for c in ws[1]],
            "b2_is_none": ws["B2"].value is None,
            "a2_is_date": ws["A2"].is_date,
            "g4": ws["G4"].value,
            "g4_format": ws["G4"].number_format,
            "b4_format": ws["B4"].number_format,
            "a1_bold": bool(ws["A1"].font.bold),
            "width_a": ws.column_dimensions["A"].width,
            "freeze": ws.freeze_panes,
            "tables": sorted(ws.tables.keys()),
        }))
        """))
        #expect(result.status == 0, "openpyxl failed: \(result.standardError)")

        let payload = try #require(result.standardOutput.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])

        #expect(parsed["sheets"] as? [String] == ["Diario", "Modelos", "Projetos", "Modelos por dia", "Heatmap"])
        #expect(parsed["header"] as? [String] == ExportSampleWorkbook.dailyHeader)
        #expect(parsed["b2_is_none"] as? Bool == true, "an uncovered day must read as null, not as zero")
        #expect(parsed["a2_is_date"] as? Bool == true, "the date column must read back as a date")
        #expect(parsed["g4"] as? Double == ExportSampleWorkbook.dailyRows[0].cost)
        #expect(parsed["g4_format"] as? String == "\"$\"#,##0.0000")
        #expect(parsed["b4_format"] as? String == "#,##0")
        #expect(parsed["a1_bold"] as? Bool == true)
        // Wide enough for a `yyyy-mm-dd`, whatever the exact estimate lands on.
        #expect((parsed["width_a"] as? Double ?? 0) >= 10)
        #expect(parsed["freeze"] as? String == "A2")
        #expect(parsed["tables"] as? [String] == ["TblDiario"])
    }

    /// Apple's own reader — the one behind Quick Look and Finder previews — accepts the file.
    @Test
    func quickLookAcceptsTheWorkbook() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage") else {
            Issue.record("qlmanage unavailable — skipping Apple's parser")
            return
        }
        let url = try Self.writeSample()
        let output = ExportTestSupport.temporaryDirectory()
        let result = try ExportTestSupport.run("/usr/bin/qlmanage", ["-t", "-s", "512", "-o", output.path, url.path])
        #expect(result.standardOutput.contains("produced one thumbnail"),
                "Quick Look refused the workbook: \(result.standardOutput)\(result.standardError)")
    }

    // MARK: - Helpers

    /// Writes the sample workbook to a fixed path outside the repository, so a human can open it in
    /// Excel (the one check no test here performs — a chart with a wrong reference draws empty and
    /// every automated verifier stays green).
    static func writeSample() throws -> URL {
        let url = ExportTestSupport.sampleWorkbookURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try XLSXWriter.data(for: ExportSampleWorkbook.make()).write(to: url)
        return url
    }

    /// All values of `attribute` in `xml`, in document order. A small scanner, because pulling in a
    /// parser for this would be heavier than the thing being read.
    static func attributeValues(of attribute: String, in xml: String) -> [String] {
        var values: [String] = []
        var remainder = Substring(xml)
        while let start = remainder.range(of: "\(attribute)=\"") {
            remainder = remainder[start.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { break }
            values.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
        return values
    }
}
