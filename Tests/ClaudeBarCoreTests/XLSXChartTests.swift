import Foundation
import Testing
@testable import ClaudeBarCore

/// Tests for the native chart parts (EXB-6.3).
///
/// **What these tests cannot do.** A chart whose series points at the wrong range opens **empty and
/// reports nothing** — the package is valid, the schema is satisfied, every parser accepts it. So the
/// checks here target the two things that are actually observable in the bytes: the axis wiring, and
/// the value cache read back from the real cells. The last elo, a human opening the file in Excel and
/// seeing six drawn charts, is the story's own acceptance criterion and no test replaces it.
struct XLSXChartTests {
    // MARK: - Parts

    /// AC1: the sample workbook carries exactly six chart parts.
    @Test
    func workbookCarriesSixCharts() {
        let paths = XLSXWriter.entries(for: ExportSampleWorkbook.make()).map(\.path)
        let charts = paths.filter { $0.hasPrefix("xl/charts/chart") }
        #expect(charts.count == 6, "found \(charts.count) charts: \(charts)")
        // Numbering is global and gapless; a gap means one chart part was planned and never written.
        #expect(Set(charts) == Set((1...6).map { "xl/charts/chart\($0).xml" }))
    }

    /// AC2: every sheet that has charts has a drawing and its relationships, and no sheet without
    /// charts has either.
    @Test
    func drawingsExistExactlyForSheetsWithCharts() {
        let paths = Set(XLSXWriter.entries(for: ExportSampleWorkbook.make()).map(\.path))
        // Diario (sheet1), Modelos (sheet2), Projetos (sheet3), Modelos por dia (sheet4) have charts.
        for number in 1...4 {
            #expect(paths.contains("xl/drawings/drawing\(number).xml"))
            #expect(paths.contains("xl/drawings/_rels/drawing\(number).xml.rels"))
        }
        // Heatmap is the fifth sheet and has none.
        #expect(!paths.contains("xl/drawings/drawing5.xml"))
    }

    /// Each drawing relationship resolves to a chart part that exists, and each chart is claimed by
    /// exactly one drawing. A chart part nobody points at is invisible in Excel and invisible to a
    /// count-based test too.
    @Test
    func everyChartIsClaimedByExactlyOneDrawing() {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let chartPaths = Set(entries.map(\.path).filter { $0.hasPrefix("xl/charts/") })
        var claimed: [String] = []
        for entry in entries where entry.path.hasPrefix("xl/drawings/_rels/") {
            let xml = String(decoding: entry.payload, as: UTF8.self)
            for target in XLSXWriterTests.attributeValues(of: "Target", in: xml) {
                claimed.append("xl/" + target.replacingOccurrences(of: "../", with: ""))
            }
        }
        #expect(Set(claimed) == chartPaths)
        #expect(claimed.count == chartPaths.count, "a chart is referenced more than once")
    }

    /// The sheet points at its drawing by a relationship id that its own rels file defines.
    @Test
    func sheetPointsAtItsDrawing() throws {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let sheet = try #require(entries.first { $0.path == "xl/worksheets/sheet1.xml" })
        let sheetXML = String(decoding: sheet.payload, as: UTF8.self)
        let drawingID = try #require(
            XLSXWriterTests.attributeValues(of: "r:id", in: sheetXML).first
        )
        let rels = try #require(entries.first { $0.path == "xl/worksheets/_rels/sheet1.xml.rels" })
        let relsXML = String(decoding: rels.payload, as: UTF8.self)
        #expect(relsXML.contains(#"Id="\#(drawingID)""#))
        #expect(relsXML.contains("drawings/drawing1.xml"))

        // The drawing must come before tableParts; the schema fixes that order and Excel enforces it.
        let drawingPosition = try #require(sheetXML.range(of: "<drawing "))
        let tablePosition = try #require(sheetXML.range(of: "<tableParts "))
        #expect(drawingPosition.lowerBound < tablePosition.lowerBound)
    }

    // MARK: - Axis wiring

    /// The two `<c:axId>` values must be the same pair in the plot element, the category axis and the
    /// value axis, with `crossAx` pointing the other way in each. Mismatched, the chart does not render
    /// — and nothing anywhere reports an error.
    @Test
    func axisIdentifiersAreConsistentAcrossAllThreePlaces() throws {
        for number in 1...6 {
            let xml = try Self.chartXML(number: number)
            guard !xml.contains("<c:pieChart>") else { continue } // a pie has no axes at all
            let document = try XMLDocument(xmlString: xml)

            // Only the plot element's own axis ids: `<c:catAx>` and `<c:valAx>` are siblings inside
            // `<c:plotArea>` and each carries a `<c:axId>` too, so a wildcard would count them twice.
            let plotElement = try #require(
                try document.nodes(forXPath: "//c:plotArea/*")
                    .compactMap { $0 as? XMLElement }
                    .first { ($0.name ?? "").hasSuffix("Chart") }
            )
            let plotIDs = try plotElement.nodes(forXPath: "./c:axId/@val").compactMap(\.stringValue)
            let categoryID = try #require(
                try document.nodes(forXPath: "//c:catAx/c:axId/@val").first?.stringValue
            )
            let valueID = try #require(
                try document.nodes(forXPath: "//c:valAx/c:axId/@val").first?.stringValue
            )
            #expect(plotIDs == [categoryID, valueID], "chart\(number): plot axis ids do not match the axes")

            let categoryCross = try document.nodes(forXPath: "//c:catAx/c:crossAx/@val").first?.stringValue
            let valueCross = try document.nodes(forXPath: "//c:valAx/c:crossAx/@val").first?.stringValue
            #expect(categoryCross == valueID, "chart\(number): catAx crosses the wrong axis")
            #expect(valueCross == categoryID, "chart\(number): valAx crosses the wrong axis")

            // Omitting `delete` makes Excel hide the axis, which reads as a broken chart.
            let deletes = try document.nodes(forXPath: "//c:delete/@val").compactMap(\.stringValue)
            #expect(deletes == ["0", "0"], "chart\(number): both axes must be explicitly kept")
        }
    }

    /// A pie has no axes; emitting them would make the part schema-invalid.
    @Test
    func pieChartHasNoAxes() throws {
        let xml = try Self.chartXML(number: 4)
        #expect(xml.contains("<c:pieChart>"))
        #expect(!xml.contains("<c:axId"))
        #expect(!xml.contains("<c:catAx>"))
    }

    /// A stacked column without `overlap=100` draws its series side by side — a chart that looks fine
    /// and answers the wrong question.
    @Test
    func stackedColumnDeclaresStackingAndFullOverlap() throws {
        let xml = try Self.chartXML(number: 1)
        #expect(xml.contains(#"<c:barDir val="col"/>"#))
        #expect(xml.contains(#"<c:grouping val="stacked"/>"#))
        #expect(xml.contains(#"<c:overlap val="100"/>"#))
    }

    /// A horizontal bar puts categories on the left and values along the bottom.
    @Test
    func horizontalBarSwapsTheAxisPositions() throws {
        let xml = try Self.chartXML(number: 3)
        #expect(xml.contains(#"<c:barDir val="bar"/>"#))
        let document = try XMLDocument(xmlString: xml)
        let categoryPosition = try document.nodes(forXPath: "//c:catAx/c:axPos/@val").first?.stringValue
        let valuePosition = try document.nodes(forXPath: "//c:valAx/c:axPos/@val").first?.stringValue
        #expect(categoryPosition == "l")
        #expect(valuePosition == "b")
    }

    /// Missing points must stay missing: `dispBlanksAs="gap"` is what turns a day with no data into a
    /// break in the line instead of a fall to zero.
    @Test
    func everyChartDisplaysBlanksAsGaps() throws {
        for number in 1...6 {
            #expect(try Self.chartXML(number: number).contains(#"<c:dispBlanksAs val="gap"/>"#))
        }
    }

    // MARK: - Series references and caches

    /// The four token series of the stacked daily chart point at the four token columns, over the body
    /// rows only. An off-by-one that swallowed the header would still produce a valid file.
    @Test
    func dailyStackedChartReferencesTheFourTokenColumns() throws {
        let document = try XMLDocument(xmlString: try Self.chartXML(number: 1))
        let references = try document.nodes(forXPath: "//c:ser/c:val/c:numRef/c:f").compactMap(\.stringValue)
        let lastRow = ExportSampleWorkbook.daily().rows.count
        #expect(references == [
            "Diario!$C$2:$C$\(lastRow)",
            "Diario!$D$2:$D$\(lastRow)",
            "Diario!$E$2:$E$\(lastRow)",
            "Diario!$F$2:$F$\(lastRow)",
        ])

        // The legend reads what the header reads. Series names point at the header cells, so a
        // technical column title would surface verbatim in the chart legend — which is where the
        // owner sees it.
        let names = try document.nodes(forXPath: "//c:ser/c:tx/c:strRef/c:strCache/c:pt/c:v").compactMap(\.stringValue)
        #expect(names == [
            "Tokens de entrada", "Tokens de saída", "Cache de leitura", "Cache de escrita",
        ])
        #expect(names.allSatisfy { !$0.contains("_") }, "a legend must not show database column names")
    }

    /// The cached points must be the values that are actually on the sheet, at the right offsets.
    ///
    /// This is the check that would fail on an off-by-one in range resolution — the class of mistake
    /// that otherwise shows up only as a chart whose bars are shifted by one day.
    @Test
    func valueCacheMatchesTheCellsOnTheSheet() throws {
        let document = try XMLDocument(xmlString: try Self.chartXML(number: 1))
        let firstSeries = try #require(try document.nodes(forXPath: "//c:ser").first as? XMLElement)
        let points = try firstSeries.nodes(forXPath: "./c:val/c:numRef/c:numCache/c:pt")

        // Two blank days at the top of the body, then one point per covered day.
        #expect(points.count == ExportSampleWorkbook.dailyRows.count)
        for (offset, expected) in ExportSampleWorkbook.dailyRows.enumerated() {
            let element = try #require(points[offset] as? XMLElement)
            #expect(element.attribute(forName: "idx")?.stringValue == String(offset + 2),
                    "point \(offset) sits at the wrong index — the blank days were not skipped correctly")
            let value = try #require(try element.nodes(forXPath: "./c:v").first?.stringValue)
            #expect(Double(value) == expected.input)
        }

        // ptCount counts the whole range, including the blanks, or the gaps land in the wrong place.
        let count = try #require(
            try firstSeries.nodes(forXPath: "./c:val/c:numRef/c:numCache/c:ptCount/@val").first?.stringValue
        )
        #expect(count == String(ExportSampleWorkbook.dailyRows.count + 2))
    }

    /// A date category column goes out as a numeric reference with a date format — referenced as text
    /// it would plot the raw serials (`46237`) as labels.
    @Test
    func dateCategoriesAreNumericWithADateFormat() throws {
        let document = try XMLDocument(xmlString: try Self.chartXML(number: 1))
        #expect(try !document.nodes(forXPath: "//c:ser/c:cat/c:numRef").isEmpty)
        #expect(try document.nodes(forXPath: "//c:ser/c:cat/c:strRef").isEmpty)
        let format = try #require(
            try document.nodes(forXPath: "//c:ser/c:cat/c:numRef/c:numCache/c:formatCode").first?.stringValue
        )
        #expect(format.contains("yyyy"))
    }

    /// A text category column goes out as a string reference, with the labels cached.
    @Test
    func textCategoriesAreStringReferences() throws {
        let document = try XMLDocument(xmlString: try Self.chartXML(number: 3))
        let labels = try document.nodes(forXPath: "//c:ser/c:cat/c:strRef/c:strCache/c:pt/c:v").compactMap(\.stringValue)
        #expect(labels == ExportSampleWorkbook.modelRows
            .sorted { $0.input + $0.output > $1.input + $1.output }
            .map(\.name))
    }

    /// A sheet name with a space must be quoted in a chart reference. Unquoted, the series resolves to
    /// nothing and the chart draws empty with no complaint from anyone.
    @Test
    func sheetNamesWithSpacesAreQuotedInReferences() throws {
        let range = XLSXRange(sheetName: "Modelos por dia", firstRow: 1, firstColumn: 0, lastRow: 6, lastColumn: 0)
        #expect(range.chartFormula == "'Modelos por dia'!$A$2:$A$7")

        let plain = XLSXRange(sheetName: "Diario", row: 0, column: 1)
        #expect(plain.chartFormula == "Diario!$B$1")

        let document = try XMLDocument(xmlString: try Self.chartXML(number: 6))
        let references = try document.nodes(forXPath: "//c:ser/c:val/c:numRef/c:f").compactMap(\.stringValue)
        #expect(references.allSatisfy { $0.hasPrefix("'Modelos por dia'!") }, "got \(references)")
    }

    /// Column letters roll over correctly past Z — the matrix sheet of a 90-day window can reach there.
    @Test
    func columnLettersRollOverPastZ() {
        #expect(XLSXAddress.columnLetters(0) == "A")
        #expect(XLSXAddress.columnLetters(25) == "Z")
        #expect(XLSXAddress.columnLetters(26) == "AA")
        #expect(XLSXAddress.columnLetters(51) == "AZ")
        #expect(XLSXAddress.columnLetters(701) == "ZZ")
    }

    // MARK: - Anchors

    /// Charts stack downwards to the right of the data, so two charts on one sheet never overlap.
    @Test
    func stackedAnchorsDoNotOverlap() throws {
        let first = XLSXChartAnchor.stacked(index: 0, dataColumns: 7)
        let second = XLSXChartAnchor.stacked(index: 1, dataColumns: 7)
        #expect(first.fromColumn == 8)
        #expect(second.fromRow >= first.toRow)

        let document = try XMLDocument(data: Data(Self.drawingXML(number: 1).utf8))
        let anchors = try document.nodes(forXPath: "//xdr:twoCellAnchor")
        #expect(anchors.count == 2)
        let shapeIDs = try document.nodes(forXPath: "//xdr:cNvPr/@id").compactMap(\.stringValue)
        #expect(Set(shapeIDs).count == shapeIDs.count, "shape ids must be unique within a drawing")
    }

    // MARK: - Independent verifier

    /// openpyxl reads the chart parts back: type, title and series reference. A parser nobody here
    /// wrote, checking the schema this writer claims to satisfy.
    @Test
    func openpyxlReadsBackTheCharts() throws {
        guard ExportTestSupport.hasOpenpyxl() else {
            Issue.record("openpyxl unavailable — skipping the independent chart parser")
            return
        }
        let url = try XLSXWriterTests.writeSample()
        let result = try #require(try ExportTestSupport.python("""
        import openpyxl, json
        wb = openpyxl.load_workbook(r"\(url.path)")
        out = []
        for name in wb.sheetnames:
            for ch in wb[name]._charts:
                out.append({
                    "sheet": name,
                    "type": type(ch).__name__,
                    "title": ch.title.tx.rich.p[0].r[0].t if ch.title else None,
                    "series": [str(s.val.numRef.f) for s in ch.series],
                })
        print(json.dumps(out))
        """))
        #expect(result.status == 0, "openpyxl failed on the charts: \(result.standardError)")

        let payload = try #require(result.standardOutput.data(using: .utf8))
        let charts = try #require(try JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
        #expect(charts.count == 6, "openpyxl found \(charts.count) charts, expected 6")

        #expect(charts.map { $0["type"] as? String } == [
            "BarChart", "LineChart", "BarChart", "PieChart", "BarChart", "BarChart",
        ])
        #expect(charts.map { $0["title"] as? String } == [
            "Tokens por dia",
            "Custo estimado por dia (USD)",
            "Volume por modelo",
            "Participacao no volume",
            "Volume por projeto",
            "Volume por modelo e dia",
        ])
        #expect(charts[0]["series"] as? [String] != nil)
        #expect((charts[0]["series"] as? [String])?.count == 4)
        #expect((charts[5]["series"] as? [String])?.allSatisfy { $0.contains("Modelos por dia") } == true)
    }

    // MARK: - Helpers

    static func chartXML(number: Int) throws -> String {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let entry = try #require(entries.first { $0.path == "xl/charts/chart\(number).xml" })
        return String(decoding: entry.payload, as: UTF8.self)
    }

    static func drawingXML(number: Int) -> String {
        let entries = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        guard let entry = entries.first(where: { $0.path == "xl/drawings/drawing\(number).xml" }) else { return "" }
        return String(decoding: entry.payload, as: UTF8.self)
    }
}
