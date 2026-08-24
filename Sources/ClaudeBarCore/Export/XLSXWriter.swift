import Foundation

/// Serialises an ``XLSXWorkbook`` into the bytes of an `.xlsx` file.
///
/// **What this is.** An `.xlsx` is a ZIP of a fixed set of XML documents. This writer emits the
/// minimum set that the workbook needs and nothing else — no `sharedStrings.xml` (strings go inline),
/// no `docProps`, no `theme1.xml`. Those three are ~10 KB of XML that Excel does not require and that
/// only add surface to get wrong.
///
/// **The invariant that shapes the whole design (I6): no cell ever contains a formula.** An `<f>`
/// whose `<v>` cache is missing renders as an empty cell until the reader recalculates, and the Excel
/// connector in Power BI reads the cache rather than the formula. So every derived number — totals,
/// percentages, ratios — is computed in Swift and written as a literal. The file is then true in any
/// reader, including the ones with no calculation engine at all.
///
/// **Failure mode to respect.** A schema mistake does not surface as a helpful error; Excel answers
/// "we found a problem with some content" and refuses the file whole. That is why the tests check the
/// emitted parts against three independent parsers instead of trusting the writer's own output.
public enum XLSXWriter {
    // MARK: - Public API

    /// The complete `.xlsx` bytes for `workbook`.
    ///
    /// Deterministic: the same workbook always produces the same bytes, because the parts are emitted
    /// in a fixed order and ``ZIPWriter`` zeroes the timestamps.
    public static func data(for workbook: XLSXWorkbook) -> Data {
        ZIPWriter.archive(entries(for: workbook))
    }

    /// The archive entries, in the order they are written. Exposed for tests that inspect one part
    /// without unzipping.
    static func entries(for workbook: XLSXWorkbook) -> [ZIPEntry] {
        let plan = Plan(workbook: workbook)
        var entries: [ZIPEntry] = [
            ZIPEntry(path: "[Content_Types].xml", text: plan.contentTypesXML()),
            ZIPEntry(path: "_rels/.rels", text: rootRelationshipsXML()),
            ZIPEntry(path: "xl/workbook.xml", text: plan.workbookXML()),
            ZIPEntry(path: "xl/_rels/workbook.xml.rels", text: plan.workbookRelationshipsXML()),
            ZIPEntry(path: "xl/styles.xml", text: stylesXML()),
        ]

        for sheet in plan.sheets {
            entries.append(ZIPEntry(path: sheet.partPath, text: plan.sheetXML(sheet)))
            if !sheet.relationships.isEmpty {
                entries.append(ZIPEntry(path: sheet.relsPartPath, text: sheet.relationshipsXML()))
            }
        }
        for sheet in plan.sheets {
            guard let table = sheet.tablePlan else { continue }
            entries.append(ZIPEntry(path: table.partPath, text: table.xml()))
        }
        for sheet in plan.sheets {
            guard let drawing = sheet.drawingPlan else { continue }
            entries.append(ZIPEntry(path: drawing.partPath, text: drawing.xml()))
            entries.append(ZIPEntry(path: drawing.relsPartPath, text: drawing.relationshipsXML()))
            for chart in drawing.charts {
                entries.append(
                    ZIPEntry(path: chart.partPath, text: XLSXChartXML.chartSpace(chart, resolver: plan))
                )
            }
        }
        return entries
    }

    // MARK: - Plan

    /// Everything derived once before any XML is written: final sheet names, part numbering and the
    /// relationship ids that tie the parts together.
    ///
    /// Numbering is computed up front on purpose. Chart and table part numbers are global across the
    /// workbook while relationship ids are local to a part, and mixing the two while streaming XML is
    /// the classic way to emit a package whose pieces point at each other's neighbours.
    struct Plan {
        let sheets: [SheetPlan]

        init(workbook: XLSXWorkbook) {
            var usedNames: [String] = []
            var nextTableNumber = 1
            var nextDrawingNumber = 1
            var nextChartNumber = 1
            var usedTableNames: [String] = []

            var planned: [SheetPlan] = []
            for (index, sheet) in workbook.sheets.enumerated() {
                let name = XLSXWriter.uniqueSheetName(sheet.name, taken: usedNames)
                usedNames.append(name)

                var relationships: [Relationship] = []

                var drawingPlan: DrawingPlan?
                if !sheet.charts.isEmpty {
                    let relationshipID = "rId\(relationships.count + 1)"
                    var chartPlans: [ChartPlan] = []
                    for (chartIndex, chart) in sheet.charts.enumerated() {
                        chartPlans.append(
                            ChartPlan(
                                number: nextChartNumber,
                                relationshipID: "rId\(chartIndex + 1)",
                                chart: chart,
                                sheetName: name
                            )
                        )
                        nextChartNumber += 1
                    }
                    drawingPlan = DrawingPlan(number: nextDrawingNumber, charts: chartPlans)
                    nextDrawingNumber += 1
                    relationships.append(
                        Relationship(
                            id: relationshipID,
                            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing",
                            target: "../drawings/drawing\(drawingPlan!.number).xml"
                        )
                    )
                }

                var tablePlan: TablePlan?
                // A table needs a header row plus at least one body row; Excel rejects a one-row table.
                if let table = sheet.table, sheet.rows.count >= 2 {
                    let tableName = XLSXWriter.uniqueTableName(table.name, taken: usedTableNames)
                    usedTableNames.append(tableName)
                    let relationshipID = "rId\(relationships.count + 1)"
                    tablePlan = TablePlan(
                        number: nextTableNumber,
                        relationshipID: relationshipID,
                        name: tableName,
                        columnNames: XLSXWriter.tableColumnNames(header: sheet.rows[0]),
                        rowCount: sheet.rows.count
                    )
                    nextTableNumber += 1
                    relationships.append(
                        Relationship(
                            id: relationshipID,
                            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/table",
                            target: "../tables/table\(tablePlan!.number).xml"
                        )
                    )
                }

                planned.append(
                    SheetPlan(
                        number: index + 1,
                        name: name,
                        sheet: sheet,
                        relationships: relationships,
                        drawingPlan: drawingPlan,
                        tablePlan: tablePlan
                    )
                )
            }
            self.sheets = planned
        }
    }

    struct Relationship {
        let id: String
        let type: String
        let target: String
    }

    struct SheetPlan {
        /// 1-based part number: `xl/worksheets/sheet{number}.xml`.
        let number: Int
        /// The sanitised, unique tab name actually written to the file.
        let name: String
        let sheet: XLSXSheet
        let relationships: [Relationship]
        let drawingPlan: DrawingPlan?
        let tablePlan: TablePlan?

        var partPath: String { "xl/worksheets/sheet\(number).xml" }
        var relsPartPath: String { "xl/worksheets/_rels/sheet\(number).xml.rels" }

        func relationshipsXML() -> String {
            let items = relationships
                .map { #"<Relationship Id="\#($0.id)" Type="\#($0.type)" Target="\#($0.target)"/>"# }
                .joined()
            return xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + items + "</Relationships>"
        }
    }

    struct TablePlan {
        let number: Int
        let relationshipID: String
        let name: String
        let columnNames: [String]
        let rowCount: Int

        var partPath: String { "xl/tables/table\(number).xml" }

        func xml() -> String {
            let reference = XLSXRange(
                sheetName: "",
                firstRow: 0, firstColumn: 0,
                lastRow: rowCount - 1, lastColumn: max(0, columnNames.count - 1)
            ).localReference
            let columns = columnNames.enumerated()
                .map { #"<tableColumn id="\#($0.offset + 1)" name="\#(XLSXWriter.escape($0.element))"/>"# }
                .joined()
            return xmlHeader
                + #"<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="\#(number)" name="\#(name)" displayName="\#(name)" ref="\#(reference)" totalsRowShown="0">"#
                + #"<autoFilter ref="\#(reference)"/>"#
                + #"<tableColumns count="\#(columnNames.count)">"# + columns + "</tableColumns>"
                + #"<tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/>"#
                + "</table>"
        }
    }

    struct DrawingPlan {
        let number: Int
        let charts: [ChartPlan]

        var partPath: String { "xl/drawings/drawing\(number).xml" }
        var relsPartPath: String { "xl/drawings/_rels/drawing\(number).xml.rels" }

        func xml() -> String { XLSXChartXML.drawing(charts) }

        func relationshipsXML() -> String {
            let items = charts.map { chart in
                #"<Relationship Id="\#(chart.relationshipID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart\#(chart.number).xml"/>"#
            }.joined()
            return xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + items + "</Relationships>"
        }
    }

    struct ChartPlan {
        /// 1-based global part number: `xl/charts/chart{number}.xml`.
        let number: Int
        /// The id by which the owning drawing refers to this chart.
        let relationshipID: String
        let chart: XLSXChart
        /// The sheet this chart is drawn on, for the anchor.
        let sheetName: String

        var partPath: String { "xl/charts/chart\(number).xml" }
    }
}

// MARK: - Package-level parts

extension XLSXWriter {
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    static func rootRelationshipsXML() -> String {
        xmlHeader
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>"#
            + "</Relationships>"
    }
}

extension XLSXWriter.Plan {
    func contentTypesXML() -> String {
        var overrides = ""
        overrides += #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
        overrides += #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        for sheet in sheets {
            overrides += #"<Override PartName="/\#(sheet.partPath)" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        for sheet in sheets {
            guard let table = sheet.tablePlan else { continue }
            overrides += #"<Override PartName="/\#(table.partPath)" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>"#
        }
        for sheet in sheets {
            guard let drawing = sheet.drawingPlan else { continue }
            overrides += #"<Override PartName="/\#(drawing.partPath)" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>"#
            for chart in drawing.charts {
                overrides += #"<Override PartName="/\#(chart.partPath)" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>"#
            }
        }
        return XLSXWriter.xmlHeader
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + overrides
            + "</Types>"
    }

    func workbookXML() -> String {
        let tabs = sheets.map { sheet in
            #"<sheet name="\#(XLSXWriter.escape(sheet.name))" sheetId="\#(sheet.number)" r:id="rId\#(sheet.number)"/>"#
        }.joined()
        return XLSXWriter.xmlHeader
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            + "<sheets>" + tabs + "</sheets>"
            + "</workbook>"
    }

    func workbookRelationshipsXML() -> String {
        var items = ""
        for sheet in sheets {
            items += #"<Relationship Id="rId\#(sheet.number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(sheet.number).xml"/>"#
        }
        items += #"<Relationship Id="rId\#(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        return XLSXWriter.xmlHeader
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items
            + "</Relationships>"
    }
}

// MARK: - styles.xml

extension XLSXWriter {
    /// The style table. The seven ``XLSXStyle`` cases map to `cellXfs` indices 0…7 **by raw value**,
    /// so a cell's `s=` attribute is just the enum's raw value — no lookup table to drift.
    static func stylesXML() -> String {
        let formatted = XLSXStyle.allCases.compactMap { style -> (Int, String)? in
            guard let code = style.numberFormatCode else { return nil }
            return (numberFormatID(for: style), code)
        }
        let numFmts = formatted
            .map { #"<numFmt numFmtId="\#($0.0)" formatCode="\#(escape($0.1))"/>"# }
            .joined()

        let cellXfs = XLSXStyle.allCases.map { style -> String in
            switch style {
            case .normal:
                return #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
            case .header:
                return #"<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf>"#
            default:
                return #"<xf numFmtId="\#(numberFormatID(for: style))" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
            }
        }.joined()

        return xmlHeader
            + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
            + #"<numFmts count="\#(formatted.count)">"# + numFmts + "</numFmts>"
            + #"<fonts count="2">"#
            + #"<font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font>"#
            + #"<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/><family val="2"/></font>"#
            + "</fonts>"
            + #"<fills count="3">"#
            + #"<fill><patternFill patternType="none"/></fill>"#
            // Excel requires gray125 in slot 1 whether or not anything uses it; omitting it corrupts the file.
            + #"<fill><patternFill patternType="gray125"/></fill>"#
            + #"<fill><patternFill patternType="solid"><fgColor rgb="FF1F2937"/><bgColor indexed="64"/></patternFill></fill>"#
            + "</fills>"
            + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
            + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
            + #"<cellXfs count="\#(XLSXStyle.allCases.count)">"# + cellXfs + "</cellXfs>"
            + #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>"#
            + #"<dxfs count="0"/>"#
            + "</styleSheet>"
    }

    /// Custom number-format ids start at 164; 0…163 are reserved by the format for built-ins.
    static func numberFormatID(for style: XLSXStyle) -> Int {
        164 + style.rawValue - XLSXStyle.integer.rawValue
    }
}

// MARK: - sheet XML

extension XLSXWriter.Plan {
    func sheetXML(_ plan: XLSXWriter.SheetPlan) -> String {
        let sheet = plan.sheet
        let columnCount = sheet.rows.map(\.count).max() ?? 1
        let dimension = XLSXRange(
            sheetName: "",
            firstRow: 0, firstColumn: 0,
            lastRow: max(0, sheet.rows.count - 1), lastColumn: max(0, columnCount - 1)
        ).localReference

        var xml = XLSXWriter.xmlHeader
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        xml += #"<dimension ref="\#(dimension)"/>"#

        if sheet.freezeHeader {
            xml += #"<sheetViews><sheetView workbookViewId="0">"#
            xml += #"<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>"#
            xml += #"<selection pane="bottomLeft" activeCell="A2" sqref="A2"/>"#
            xml += "</sheetView></sheetViews>"
        }
        xml += #"<sheetFormatPr defaultRowHeight="15"/>"#

        // An empty <cols> element is schema-invalid, so it is emitted only when there is a width.
        let widths = XLSXWriter.resolvedColumnWidths(for: sheet)
        if !widths.isEmpty {
            let cols = widths.map { width in
                #"<col min="\#(width.column + 1)" max="\#(width.column + 1)" width="\#(XLSXWriter.numberLiteral(width.width) ?? "10")" customWidth="1"/>"#
            }.joined()
            xml += "<cols>" + cols + "</cols>"
        }

        xml += "<sheetData>"
        for (rowIndex, row) in sheet.rows.enumerated() {
            let cells = row.enumerated().compactMap { columnIndex, cell in
                XLSXWriter.cellXML(cell, row: rowIndex, column: columnIndex)
            }.joined()
            // A row with nothing in it is still emitted, so row numbering stays aligned with the model.
            xml += #"<row r="\#(rowIndex + 1)">"# + cells + "</row>"
        }
        xml += "</sheetData>"

        if let rule = sheet.colorScale {
            let reference = XLSXRange(
                sheetName: "",
                firstRow: rule.firstRow, firstColumn: rule.firstColumn,
                lastRow: rule.lastRow, lastColumn: rule.lastColumn
            ).localReference
            xml += #"<conditionalFormatting sqref="\#(reference)">"#
            xml += #"<cfRule type="colorScale" priority="1"><colorScale>"#
            xml += #"<cfvo type="min"/><cfvo type="max"/>"#
            xml += #"<color rgb="\#(rule.lowColor)"/><color rgb="\#(rule.highColor)"/>"#
            xml += "</colorScale></cfRule></conditionalFormatting>"
        }

        // Element order inside CT_Worksheet is fixed by the schema: sheetData → conditionalFormatting
        // → drawing → tableParts. Out of order, Excel rejects the whole workbook.
        if let drawing = plan.drawingPlan,
           let relationship = plan.relationships.first(where: { $0.target.hasSuffix("drawing\(drawing.number).xml") }) {
            xml += #"<drawing r:id="\#(relationship.id)"/>"#
        }
        if let table = plan.tablePlan {
            xml += #"<tableParts count="1"><tablePart r:id="\#(table.relationshipID)"/></tableParts>"#
        }
        xml += "</worksheet>"
        return xml
    }
}

// MARK: - Column widths

extension XLSXWriter {
    /// The width of every column of `sheet`, in Excel's character units.
    ///
    /// **The header always fits — by construction, not by test.** A column whose title is clipped to
    /// `cache_l` is a spreadsheet that cannot be read, and it is invisible to every structural check:
    /// the XML is valid, the cell holds the whole string, and only a human opening the file sees the
    /// truncation. So the width is not merely *derived* from the content, it is **floored** at what the
    /// header needs. An explicit `XLSXColumnWidth` can widen a column past that floor; it cannot narrow
    /// it below, because there is no case where clipping a title is the caller's intent.
    ///
    /// Deterministic: a pure function of the cells, so the byte-stability of the workbook survives.
    static func resolvedColumnWidths(for sheet: XLSXSheet) -> [XLSXColumnWidth] {
        let columnCount = sheet.rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return [] }

        let explicit = Dictionary(sheet.columns.map { ($0.column, $0.width) }, uniquingKeysWith: { _, last in last })
        // A table draws a filter button over the header cell, which eats roughly three characters of
        // the title. Without the extra room the button is what does the clipping.
        let headerPadding: Double = sheet.table == nil ? 2 : 5

        return (0..<columnCount).map { column in
            var headerFloor = minimumWidth
            var contentWidth = minimumWidth
            for (rowIndex, row) in sheet.rows.enumerated() {
                guard column < row.count else { continue }
                let estimate = estimatedWidth(of: row[column])
                if rowIndex == 0 {
                    headerFloor = max(headerFloor, estimate + headerPadding)
                } else {
                    contentWidth = max(contentWidth, estimate + 2)
                }
            }
            let automatic = max(headerFloor, contentWidth)
            let chosen = max(explicit[column] ?? automatic, headerFloor)
            return XLSXColumnWidth(column: column, width: min(chosen, maximumWidth).rounded())
        }
    }

    /// Excel's own default is ~8.43; nothing narrower is ever useful here.
    static let minimumWidth: Double = 9
    /// Past this a column stops being readable and starts pushing the charts off screen.
    static let maximumWidth: Double = 46

    /// How wide a cell renders, in character units.
    ///
    /// An estimate, and knowingly so: the true width depends on the font metrics of whoever opens the
    /// file. Character count is the approximation Excel's own auto-fit starts from, and erring wide is
    /// harmless while erring narrow is the defect being fixed.
    static func estimatedWidth(of cell: XLSXCell) -> Double {
        switch cell {
        case .blank:
            return 0
        case let .text(value, _):
            return Double(value.count)
        case .date:
            return 10 // yyyy-mm-dd
        case let .number(value, style):
            return Double(renderedNumberLength(value, style: style))
        }
    }

    /// The number of characters a number occupies once its format is applied — grouping separators,
    /// decimals and currency sign included, since those are what actually overflow the column.
    static func renderedNumberLength(_ value: Double, style: XLSXStyle) -> Int {
        guard value.isFinite else { return 0 }
        let scaled = style == .percent ? value * 100 : value
        let integerDigits = max(1, String(Int64(abs(scaled).rounded(.towardZero))).count)
        let groupingSeparators = (integerDigits - 1) / 3
        let sign = scaled < 0 ? 1 : 0

        let decimals: Int
        let prefix: Int
        let suffix: Int
        switch style {
        case .currency2: (decimals, prefix, suffix) = (2, 1, 0)
        case .currency4: (decimals, prefix, suffix) = (4, 1, 0)
        case .percent: (decimals, prefix, suffix) = (1, 0, 1)
        case .hour: return 3
        case .integer, .header: (decimals, prefix, suffix) = (0, 0, 0)
        case .normal, .date: (decimals, prefix, suffix) = (0, 0, 0)
        }
        // The decimal point only exists when there are decimals to separate.
        let decimalPoint = decimals > 0 ? 1 : 0
        return integerDigits + groupingSeparators + sign + decimals + decimalPoint + prefix + suffix
    }
}

// MARK: - Cells

extension XLSXWriter {
    /// The XML for one cell, or `nil` when the cell contributes nothing.
    ///
    /// A `.blank` produces **no element at all**, which is what makes a blank distinguishable from a
    /// zero downstream: charts break the line at a missing point and BI tools read it as null.
    static func cellXML(_ cell: XLSXCell, row: Int, column: Int) -> String? {
        let reference = XLSXAddress.reference(row: row, column: column)
        switch cell {
        case .blank:
            return nil
        case let .text(value, style):
            let style = style.rawValue
            let attribute = style == 0 ? "" : #" s="\#(style)""#
            return #"<c r="\#(reference)"\#(attribute) t="inlineStr"><is><t\#(preserveSpace(value))>\#(escape(value))</t></is></c>"#
        case let .number(value, style):
            guard let literal = numberLiteral(value) else { return nil }
            let style = style.rawValue
            let attribute = style == 0 ? "" : #" s="\#(style)""#
            return #"<c r="\#(reference)"\#(attribute)><v>\#(literal)</v></c>"#
        case let .date(value):
            guard let literal = numberLiteral(XLSXDateSerial.serial(for: value)) else { return nil }
            return #"<c r="\#(reference)" s="\#(XLSXStyle.date.rawValue)"><v>\#(literal)</v></c>"#
        }
    }

    /// A locale-independent decimal literal, or `nil` for a value XML cannot carry.
    ///
    /// NaN and infinity are dropped rather than written: `"nan"` in a `<v>` is not a valid `xsd:double`
    /// and takes the whole workbook down with it.
    static func numberLiteral(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// `xml:space="preserve"` is required whenever the text has leading or trailing whitespace;
    /// without it, the reader is free to strip it.
    private static func preserveSpace(_ value: String) -> String {
        guard let first = value.first, let last = value.last else { return "" }
        return (first.isWhitespace || last.isWhitespace) ? #" xml:space="preserve""# : ""
    }

    /// XML-escapes `value` and drops the control characters XML 1.0 forbids.
    ///
    /// The dropping is not paranoia: sheet content includes project names taken from directory names
    /// on disk, which are arbitrary bytes as far as this writer is concerned.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 forbids C0 controls other than tab/LF/CR, plus DEL-range surrogates.
                if scalar.value < 0x20 || (scalar.value >= 0xD800 && scalar.value <= 0xDFFF) {
                    continue
                }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: - Name sanitisation

extension XLSXWriter {
    /// Characters Excel refuses in a sheet tab name.
    private static let forbiddenSheetCharacters: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]

    /// A tab name Excel will accept: forbidden characters removed, 31 characters at most, never
    /// empty, never starting or ending with an apostrophe.
    static func sanitizeSheetName(_ raw: String) -> String {
        var cleaned = String(raw.filter { !forbiddenSheetCharacters.contains($0) })
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if cleaned.count > 31 {
            cleaned = String(cleaned.prefix(31))
        }
        return cleaned.isEmpty ? "Sheet" : cleaned
    }

    /// `sanitizeSheetName` plus a numeric suffix when the name is already taken.
    ///
    /// Excel compares tab names case-insensitively, so the collision check does too.
    static func uniqueSheetName(_ raw: String, taken: [String]) -> String {
        let base = sanitizeSheetName(raw)
        let lowercasedTaken = Set(taken.map { $0.lowercased() })
        guard lowercasedTaken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while true {
            let marker = "\(suffix)"
            let trimmed = base.count + marker.count > 31
                ? String(base.prefix(31 - marker.count))
                : base
            let candidate = trimmed + marker
            if !lowercasedTaken.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }

    /// A table name Excel will accept: letters, digits and underscore only, never starting with a digit.
    static func sanitizeTableName(_ raw: String) -> String {
        var cleaned = String(raw.map { character in
            (character.isLetter || character.isNumber || character == "_") ? character : "_"
        })
        if let first = cleaned.first, first.isNumber { cleaned = "_" + cleaned }
        if cleaned.isEmpty { cleaned = "Table" }
        if cleaned.count > 255 { cleaned = String(cleaned.prefix(255)) }
        return cleaned
    }

    static func uniqueTableName(_ raw: String, taken: [String]) -> String {
        let base = sanitizeTableName(raw)
        var candidate = base
        var suffix = 2
        while taken.contains(where: { $0.lowercased() == candidate.lowercased() }) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Column names for a table, taken from the header row.
    ///
    /// Excel requires them non-empty and unique; a duplicate silently makes the table unopenable, so
    /// blanks become `Coluna N` and repeats get a numeric suffix.
    static func tableColumnNames(header: [XLSXCell]) -> [String] {
        var names: [String] = []
        for (index, cell) in header.enumerated() {
            var name: String
            switch cell {
            case let .text(value, _): name = value.trimmingCharacters(in: .whitespaces)
            case let .number(value, _): name = numberLiteral(value) ?? "Coluna \(index + 1)"
            case .date, .blank: name = "Coluna \(index + 1)"
            }
            if name.isEmpty { name = "Coluna \(index + 1)" }
            var candidate = name
            var suffix = 2
            while names.contains(where: { $0.lowercased() == candidate.lowercased() }) {
                candidate = "\(name) \(suffix)"
                suffix += 1
            }
            names.append(candidate)
        }
        return names
    }
}

// MARK: - Range resolution (for chart caches)

/// Reads the cells a chart series points at, so the chart part can carry a value cache.
protocol XLSXRangeResolver {
    func cells(in range: XLSXRange) -> [XLSXCell]
}

extension XLSXWriter.Plan: XLSXRangeResolver {
    /// The cells covered by `range`, in row-major order.
    ///
    /// **Why the writer resolves ranges at all.** A chart's `<c:f>` is only a pointer; readers that do
    /// not evaluate it fall back to the cached points inside the chart part. Populating that cache from
    /// the real cells is what keeps a chart from rendering empty in a reader that never opens the
    /// worksheet — and it makes a wrong series reference visible to a test instead of only to the eye.
    func cells(in range: XLSXRange) -> [XLSXCell] {
        guard let plan = sheets.first(where: { $0.name == range.sheetName }) else { return [] }
        let rows = plan.sheet.rows
        var result: [XLSXCell] = []
        for rowIndex in range.firstRow...max(range.firstRow, range.lastRow) {
            guard rowIndex >= 0, rowIndex < rows.count else {
                result.append(.blank)
                continue
            }
            let row = rows[rowIndex]
            for columnIndex in range.firstColumn...max(range.firstColumn, range.lastColumn) {
                if columnIndex >= 0, columnIndex < row.count {
                    result.append(row[columnIndex])
                } else {
                    result.append(.blank)
                }
            }
        }
        return result
    }
}
