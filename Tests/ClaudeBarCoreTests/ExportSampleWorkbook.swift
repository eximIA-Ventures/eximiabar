import Foundation
@testable import ClaudeBarCore

/// The sample workbook the export tests measure and a human opens in Excel.
///
/// It is a fixture, not the real export: the mapping from `DashboardData` belongs to a later story.
/// What it does carry is every feature of the engine that can fail silently — the four chart shapes,
/// a named table, a colour scale, a sheet name with spaces, a hostile project name, and days that are
/// **blank rather than zero** because they precede the data's coverage.
///
/// All values are fixed constants and all dates are UTC midnights, so the bytes are reproducible.
enum ExportSampleWorkbook {
    /// 2026-08-01, **local** midnight.
    ///
    /// Local rather than UTC, and the distinction is not pedantry: every date this export handles is a
    /// `Calendar.current.startOfDay` instant, because that is how the dashboard buckets a day. A UTC
    /// midnight is not a day boundary anywhere except Greenwich, so a fixture built from one describes
    /// data the app never produces — and it hid a real defect (see
    /// ``CSVWriter/isoDay(_:timeZone:)``): dates were formatted in UTC, which shifts every row one day
    /// back for any owner east of Greenwich. The same choice, for the same reason, is already recorded
    /// in `PainelSampleData`.
    /// Built from calendar components, not from an epoch offset: the fixture names a **date**, and the
    /// instant it resolves to is whatever local midnight is on the machine running the test.
    static let firstDay: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 8; partes.day = 1
        return Calendar.current.date(from: partes) ?? Date(timeIntervalSince1970: 1_785_542_400)
    }()

    /// Adds calendar days, not 86 400 seconds. Across a DST change the two differ by an hour, which is
    /// enough to move a local midnight onto the neighbouring date.
    static func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: firstDay) ?? firstDay
    }

    static func make() -> XLSXWorkbook {
        XLSXWorkbook(sheets: [daily(), models(), projects(), modelsByDay(), heatmap()])
    }

    // MARK: - Diario

    /// Eight days, of which the first two precede the data's coverage and are therefore blank.
    static let dailyRows: [(offset: Int, input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cost: Double)] = [
        (2, 120_400, 18_900, 402_100, 33_500, 1.9412),
        (3, 98_200, 15_300, 388_700, 21_900, 1.5730),
        (4, 143_800, 22_100, 511_600, 44_200, 2.3104),
        (5, 76_500, 11_800, 240_300, 18_700, 1.2065),
        (6, 165_900, 27_400, 623_800, 51_100, 2.7318),
        (7, 132_100, 20_600, 470_500, 39_400, 2.1247),
    ]

    /// Read from ``ExportLabels``, never spelled here.
    ///
    /// The owner asked for a spreadsheet "já formatada, bonitinha e pronta para entender", and
    /// `custo_usd` is a column name for a database, not for a person. The exception is the `Fato`
    /// sheet, which exists to be consumed by a BI tool and keeps stable snake_case identifiers — that
    /// sheet belongs to a later story and is not built here.
    static let dailyHeader = ExportLabels.diario

    static func daily() -> XLSXSheet {
        var rows: [[XLSXCell]] = [dailyHeader.map { .text($0, .header) }]
        // Two days with no data at all — written blank, never zero (D6).
        for offset in 0..<2 {
            rows.append([.date(day(offset)), .blank, .blank, .blank, .blank, .blank, .blank])
        }
        for entry in dailyRows {
            let total = entry.input + entry.output + entry.cacheRead + entry.cacheWrite
            rows.append([
                .date(day(entry.offset)),
                .number(total, .integer),
                .number(entry.input, .integer),
                .number(entry.output, .integer),
                .number(entry.cacheRead, .integer),
                .number(entry.cacheWrite, .integer),
                .number(entry.cost, .currency4),
            ])
        }

        let lastRow = rows.count - 1
        let categories = XLSXRange(sheetName: "Diario", firstRow: 1, firstColumn: 0, lastRow: lastRow, lastColumn: 0)
        func series(column: Int) -> XLSXSeries {
            XLSXSeries(
                nameCell: XLSXRange(sheetName: "Diario", row: 0, column: column),
                values: XLSXRange(sheetName: "Diario", firstRow: 1, firstColumn: column, lastRow: lastRow, lastColumn: column)
            )
        }

        // No explicit widths: the writer floors every column at what its header needs, which is what
        // the hardcoded 12 and 14 here used to get wrong.
        return XLSXSheet(
            name: "Diario",
            rows: rows,
            freezeHeader: true,
            table: XLSXTable(name: "TblDiario"),
            charts: [
                // Tokens first: the primary chart of the sheet plots volume, not money.
                XLSXChart(
                    kind: .columnStacked,
                    title: "Tokens por dia",
                    categories: categories,
                    series: [series(column: 2), series(column: 3), series(column: 4), series(column: 5)],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: dailyHeader.count)
                ),
                XLSXChart(
                    kind: .line,
                    title: "Custo estimado por dia (USD)",
                    categories: categories,
                    series: [series(column: 6)],
                    valueNumberFormat: "\"$\"#,##0.0000",
                    anchor: .stacked(index: 1, dataColumns: dailyHeader.count)
                ),
            ]
        )
    }

    // MARK: - Modelos

    static let modelsHeader = ExportLabels.modelos

    static let modelRows: [(name: String, input: Double, output: Double, cost: Double)] = [
        ("claude-opus-4", 402_800, 61_200, 6.1044),
        ("claude-sonnet-4", 251_300, 39_700, 1.4318),
        ("claude-haiku-4", 82_900, 15_400, 0.1927),
    ]

    static func models() -> XLSXSheet {
        var rows: [[XLSXCell]] = [
            modelsHeader.map { .text($0, .header) },
        ]
        // Ordered by tokens desc — volume is the primary axis, not cost.
        for entry in modelRows.sorted(by: { $0.input + $0.output > $1.input + $1.output }) {
            rows.append([
                .text(entry.name, .normal),
                .number(entry.input + entry.output, .integer),
                .number(entry.input, .integer),
                .number(entry.output, .integer),
                .number(entry.cost, .currency2),
            ])
        }
        let lastRow = rows.count - 1
        let categories = XLSXRange(sheetName: "Modelos", firstRow: 1, firstColumn: 0, lastRow: lastRow, lastColumn: 0)
        let volume = XLSXSeries(
            nameCell: XLSXRange(sheetName: "Modelos", row: 0, column: 1),
            values: XLSXRange(sheetName: "Modelos", firstRow: 1, firstColumn: 1, lastRow: lastRow, lastColumn: 1)
        )
        return XLSXSheet(
            name: "Modelos",
            rows: rows,
            freezeHeader: true,
            table: XLSXTable(name: "TblModelos"),
            charts: [
                XLSXChart(
                    kind: .barHorizontal,
                    title: "Volume por modelo",
                    categories: categories,
                    series: [volume],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: 5)
                ),
                XLSXChart(
                    kind: .pie,
                    title: "Participacao no volume",
                    categories: categories,
                    series: [volume],
                    anchor: .stacked(index: 1, dataColumns: 5)
                ),
            ]
        )
    }

    // MARK: - Projetos

    /// A project name that would break a naive writer: it comes from a directory name on disk, so
    /// angle brackets and ampersands are entirely possible.
    static let hostileProjectName = "</script><img src=x onerror=alert(1)> & \"quoted\""

    static let projectsHeader = ExportLabels.projetos

    static let projectRows: [(name: String, tokens: Double, cost: Double)] = [
        ("eximiabar", 611_400, 4.2718),
        (hostileProjectName, 208_900, 1.9044),
        ("Unknown", 74_300, 0.5211),
    ]

    static func projects() -> XLSXSheet {
        var rows: [[XLSXCell]] = [
            projectsHeader.map { .text($0, .header) },
        ]
        for entry in projectRows {
            rows.append([
                .text(entry.name, .normal),
                .number(entry.tokens, .integer),
                .number(entry.cost, .currency2),
            ])
        }
        let lastRow = rows.count - 1
        return XLSXSheet(
            name: "Projetos",
            // The one explicit width in the fixture, and it is deliberately narrower than the widest
            // project name: it proves an explicit width still caps the *content* while the header
            // floor keeps "Projeto" readable. Clipping a value is recoverable by clicking the cell;
            // clipping a title is not.
            rows: rows,
            columns: [XLSXColumnWidth(column: 0, width: 28)],
            freezeHeader: true,
            table: XLSXTable(name: "TblProjetos"),
            charts: [
                XLSXChart(
                    kind: .barHorizontal,
                    title: "Volume por projeto",
                    categories: XLSXRange(sheetName: "Projetos", firstRow: 1, firstColumn: 0, lastRow: lastRow, lastColumn: 0),
                    series: [XLSXSeries(
                        nameCell: XLSXRange(sheetName: "Projetos", row: 0, column: 1),
                        values: XLSXRange(sheetName: "Projetos", firstRow: 1, firstColumn: 1, lastRow: lastRow, lastColumn: 1)
                    )],
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: 3)
                ),
            ]
        )
    }

    // MARK: - Modelos por dia

    /// The wide pivoted block. A chart series needs a **contiguous** range, so the matrix has to exist
    /// as real cells — the long `(day, model, tokens)` form cannot feed a stacked chart directly.
    ///
    /// Its name carries a space on purpose: an unquoted sheet name in a chart reference draws an empty
    /// plot and reports nothing.
    static func modelsByDay() -> XLSXSheet {
        let names = modelRows.map(\.name)
        var rows: [[XLSXCell]] = [
            ([XLSXCell.text(ExportLabels.dia, .header)] + names.map { .text($0, .header) }),
        ]
        for (index, entry) in dailyRows.enumerated() {
            let total = entry.input + entry.output
            rows.append([
                .date(day(entry.offset)),
                .number((total * 0.55).rounded(), .integer),
                .number((total * 0.32).rounded(), .integer),
                .number((total * 0.13).rounded(), .integer),
            ])
            _ = index
        }
        let lastRow = rows.count - 1
        let sheetName = "Modelos por dia"
        return XLSXSheet(
            name: sheetName,
            rows: rows,
            freezeHeader: true,
            charts: [
                XLSXChart(
                    kind: .columnStacked,
                    title: "Volume por modelo e dia",
                    categories: XLSXRange(sheetName: sheetName, firstRow: 1, firstColumn: 0, lastRow: lastRow, lastColumn: 0),
                    series: (1...names.count).map { column in
                        XLSXSeries(
                            nameCell: XLSXRange(sheetName: sheetName, row: 0, column: column),
                            values: XLSXRange(sheetName: sheetName, firstRow: 1, firstColumn: column, lastRow: lastRow, lastColumn: column)
                        )
                    },
                    valueNumberFormat: "#,##0",
                    anchor: .stacked(index: 0, dataColumns: names.count + 1)
                ),
            ]
        )
    }

    // MARK: - Heatmap

    /// 7 weekdays × 24 hours, with a colour scale instead of a chart: Excel has no heat-map chart type,
    /// and `cfRule type="colorScale"` is the native equivalent — three elements, no extra part.
    static func heatmap() -> XLSXSheet {
        let weekdays = ["Domingo", "Segunda", "Terca", "Quarta", "Quinta", "Sexta", "Sabado"]
        var rows: [[XLSXCell]] = [
            ([XLSXCell.text(ExportLabels.diaDaSemana, .header)]
                + (0..<24).map { .text(String(format: "%02dh", $0), .header) }
                + [XLSXCell.text(ExportLabels.total, .header)]),
        ]
        for (dayIndex, weekday) in weekdays.enumerated() {
            var row: [XLSXCell] = [.text(weekday, .normal)]
            var total: Double = 0
            for hour in 0..<24 {
                // A fixed, lumpy shape: busiest mid-afternoon on weekdays.
                let value = Double((dayIndex + 1) * (hour % 7 + 1) * 1_300 + hour * 250)
                total += value
                row.append(.number(value, .integer))
            }
            row.append(.number(total, .integer))
            rows.append(row)
        }
        return XLSXSheet(
            name: "Heatmap",
            rows: rows,
            freezeHeader: true,
            colorScale: XLSXColorScaleRule(
                firstRow: 1, firstColumn: 1, lastRow: 7, lastColumn: 24,
                lowColor: "FF111827", highColor: "FFCC7C5E"
            )
        )
    }
}
