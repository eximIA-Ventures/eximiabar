import Foundation

// MARK: - Styles

/// The seven presentation styles the workbook needs — no more, and each one maps to exactly one
/// `cellXfs` entry in `xl/styles.xml`.
///
/// Kept as a closed enum on purpose: an open "any format string" API would let a caller invent a
/// number format that the number-format table does not carry, and Excel answers that with the
/// opaque "unreadable content" dialog rather than a useful error.
public enum XLSXStyle: Int, Sendable, CaseIterable {
    /// Default font, no number format.
    case normal = 0
    /// Bold white on the dark header fill — the first row of every tabular sheet.
    case header = 1
    /// `#,##0` — token counts and other whole quantities.
    case integer = 2
    /// `"$"#,##0.00` — currency at two decimals.
    case currency2 = 3
    /// `"$"#,##0.0000` — currency at four decimals, for per-day figures that round to zero at two.
    case currency4 = 4
    /// `0.0%` — a ratio already expressed as a fraction (0.42 renders as 42.0%).
    case percent = 5
    /// `00"h"` — hour of day.
    case hour = 6
    /// `yyyy-mm-dd` — always paired with a date serial, never with text.
    case date = 7

    /// The number-format code written into `xl/styles.xml`, or `nil` for the two styles that carry none.
    var numberFormatCode: String? {
        switch self {
        case .normal, .header: nil
        case .integer: "#,##0"
        case .currency2: "\"$\"#,##0.00"
        case .currency4: "\"$\"#,##0.0000"
        case .percent: "0.0%"
        case .hour: "00\"h\""
        case .date: "yyyy-mm-dd"
        }
    }
}

// MARK: - Cells

/// A single cell. `Date` is deliberately a case of its own because it is the only value whose Excel
/// representation (a serial number plus a date format) differs from how it arrives.
public enum XLSXCell: Sendable, Equatable {
    /// Text, written as `t="inlineStr"` so the workbook needs no `sharedStrings.xml` part.
    case text(String, XLSXStyle)
    /// A number in the given presentation style.
    case number(Double, XLSXStyle)
    /// A calendar date, written as an Excel serial with the `yyyy-mm-dd` format.
    case date(Date)
    /// No value at all.
    ///
    /// **Not the same as `.number(0, …)`, and that distinction is the point (D6).** A day before the
    /// data source begins must read as "no data", not as "used nothing" — and a chart with
    /// `dispBlanksAs="gap"` breaks the line at a blank while drawing a zero at the baseline.
    case blank
}

// MARK: - Column widths

/// The width of one column, in Excel's character units.
public struct XLSXColumnWidth: Sendable, Equatable {
    /// Zero-based column index.
    public let column: Int
    /// Width in character units (Excel's default is ~8.43).
    public let width: Double

    public init(column: Int, width: Double) {
        self.column = column
        self.width = width
    }
}

// MARK: - Tables

/// A named Excel Table over the sheet's used range — header row plus body.
///
/// This is not decoration: the Excel Workbook connector in Power BI lists **named tables** reliably
/// in its Navigator, while a bare sheet requires the user to guess the range. The table is the
/// ingestion contract.
public struct XLSXTable: Sendable, Equatable {
    /// The table name as it appears in Excel and in the BI navigator (e.g. `TblDiario`).
    ///
    /// Sanitised on write: Excel rejects spaces and a leading digit in table names.
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Colour scale

/// A two-colour conditional-format scale over a rectangular range — the native stand-in for a
/// heat map, since Excel has no heat-map chart type.
public struct XLSXColorScaleRule: Sendable, Equatable {
    /// Zero-based inclusive bounds of the range the scale covers.
    public let firstRow: Int
    public let firstColumn: Int
    public let lastRow: Int
    public let lastColumn: Int
    /// ARGB of the low end (e.g. `FF111827`).
    public let lowColor: String
    /// ARGB of the high end (e.g. `FFCC7C5E`).
    public let highColor: String

    public init(
        firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int,
        lowColor: String, highColor: String
    ) {
        self.firstRow = firstRow
        self.firstColumn = firstColumn
        self.lastRow = lastRow
        self.lastColumn = lastColumn
        self.lowColor = lowColor
        self.highColor = highColor
    }
}

// MARK: - Ranges

/// A rectangular reference into a sheet, rendered as an absolute A1 range (`Diario!$B$2:$B$8`).
///
/// Chart series can only point at a **contiguous** range — that restriction is why a wide pivoted
/// block has to be materialised as real cells instead of being derived on the fly.
public struct XLSXRange: Sendable, Equatable {
    /// The sheet the range lives in, by its final (sanitised) name.
    public let sheetName: String
    public let firstRow: Int
    public let firstColumn: Int
    public let lastRow: Int
    public let lastColumn: Int

    public init(sheetName: String, firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int) {
        self.sheetName = sheetName
        self.firstRow = firstRow
        self.firstColumn = firstColumn
        self.lastRow = lastRow
        self.lastColumn = lastColumn
    }

    /// A single cell.
    public init(sheetName: String, row: Int, column: Int) {
        self.init(sheetName: sheetName, firstRow: row, firstColumn: column, lastRow: row, lastColumn: column)
    }

    /// The reference as a chart formula: `'Modelos por dia'!$A$2:$A$40`.
    ///
    /// The sheet name is quoted whenever it holds anything other than letters, digits and `_`;
    /// an unquoted name with a space silently breaks the series and the chart draws empty.
    var chartFormula: String {
        let needsQuoting = sheetName.contains { character in
            !(character.isLetter || character.isNumber || character == "_")
        }
        let name = needsQuoting
            ? "'\(sheetName.replacingOccurrences(of: "'", with: "''"))'"
            : sheetName
        let start = "$\(XLSXAddress.columnLetters(firstColumn))$\(firstRow + 1)"
        if firstRow == lastRow && firstColumn == lastColumn {
            return "\(name)!\(start)"
        }
        let end = "$\(XLSXAddress.columnLetters(lastColumn))$\(lastRow + 1)"
        return "\(name)!\(start):\(end)"
    }

    /// The reference without a sheet name, for the `ref` attribute of a table or a conditional format.
    var localReference: String {
        let start = "\(XLSXAddress.columnLetters(firstColumn))\(firstRow + 1)"
        let end = "\(XLSXAddress.columnLetters(lastColumn))\(lastRow + 1)"
        return start == end ? start : "\(start):\(end)"
    }
}

// MARK: - Charts

/// One native chart, anchored on the sheet that owns it.
public struct XLSXChart: Sendable, Equatable {
    /// The four chart shapes this workbook uses.
    public enum Kind: Sendable, Equatable {
        /// One line per series over a shared category axis.
        case line
        /// Vertical columns stacked on a shared category axis — the shape for "parts of a daily total".
        case columnStacked
        /// Horizontal bars, one series — the shape for ranking a categorical dimension.
        case barHorizontal
        /// A single series as slices.
        case pie
    }

    /// The chart type.
    public let kind: Kind
    /// The title drawn above the plot.
    public let title: String
    /// The category axis values (usually the first column of the table body).
    public let categories: XLSXRange
    /// One entry per plotted series.
    public let series: [XLSXSeries]
    /// Number format applied to the value axis, e.g. `"$"#,##0.00`. Ignored for pie.
    public let valueNumberFormat: String?
    /// Where the chart sits on the sheet.
    public let anchor: XLSXChartAnchor

    public init(
        kind: Kind,
        title: String,
        categories: XLSXRange,
        series: [XLSXSeries],
        valueNumberFormat: String? = nil,
        anchor: XLSXChartAnchor
    ) {
        self.kind = kind
        self.title = title
        self.categories = categories
        self.series = series
        self.valueNumberFormat = valueNumberFormat
        self.anchor = anchor
    }
}

/// One plotted series: where its name lives and where its values live.
public struct XLSXSeries: Sendable, Equatable {
    /// The header cell holding the series name, or `nil` for an unnamed series.
    public let nameCell: XLSXRange?
    /// The contiguous range of values.
    public let values: XLSXRange

    public init(nameCell: XLSXRange?, values: XLSXRange) {
        self.nameCell = nameCell
        self.values = values
    }
}

/// A two-cell anchor: the chart occupies the rectangle between two cell corners.
public struct XLSXChartAnchor: Sendable, Equatable {
    public let fromColumn: Int
    public let fromRow: Int
    public let toColumn: Int
    public let toRow: Int

    public init(fromColumn: Int, fromRow: Int, toColumn: Int, toRow: Int) {
        self.fromColumn = fromColumn
        self.fromRow = fromRow
        self.toColumn = toColumn
        self.toRow = toRow
    }

    /// The default placement for the `index`-th chart of a sheet: to the right of `dataColumns`,
    /// stacked downwards so charts never overlap each other.
    public static func stacked(index: Int, dataColumns: Int) -> XLSXChartAnchor {
        let from = dataColumns + 1
        let top = index * 17 + 1
        return XLSXChartAnchor(fromColumn: from, fromRow: top, toColumn: from + 8, toRow: top + 16)
    }
}

// MARK: - Sheet

/// One worksheet: a grid of cells plus the optional table, colour scale and charts drawn over it.
public struct XLSXSheet: Sendable, Equatable {
    /// The requested tab name. Sanitised on write (Excel forbids `[ ] : * ? / \` and names over 31 chars).
    public let name: String
    /// A subtitle written by the caller into the rows — kept out of the model on purpose; the sheet
    /// is nothing but the rows it was given.
    public let rows: [[XLSXCell]]
    /// Explicit widths for the columns that need them; unlisted columns keep the default.
    public let columns: [XLSXColumnWidth]
    /// Freeze the first row so the header stays visible while scrolling.
    public let freezeHeader: Bool
    /// The named table over the used range, if this sheet is meant to be consumed by a BI tool.
    public let table: XLSXTable?
    /// The heat-map colour scale, if any.
    public let colorScale: XLSXColorScaleRule?
    /// Native charts drawn on this sheet.
    public let charts: [XLSXChart]

    public init(
        name: String,
        rows: [[XLSXCell]],
        columns: [XLSXColumnWidth] = [],
        freezeHeader: Bool = false,
        table: XLSXTable? = nil,
        colorScale: XLSXColorScaleRule? = nil,
        charts: [XLSXChart] = []
    ) {
        self.name = name
        self.rows = rows
        self.columns = columns
        self.freezeHeader = freezeHeader
        self.table = table
        self.colorScale = colorScale
        self.charts = charts
    }
}

// MARK: - Workbook

/// The whole workbook: an ordered list of sheets and nothing else.
public struct XLSXWorkbook: Sendable, Equatable {
    public let sheets: [XLSXSheet]

    public init(sheets: [XLSXSheet]) {
        self.sheets = sheets
    }
}

// MARK: - Address helpers

/// A1-notation helpers, shared by sheets, tables, conditional formats and charts.
enum XLSXAddress {
    /// Column letters for a zero-based index: 0 → `A`, 25 → `Z`, 26 → `AA`.
    static func columnLetters(_ column: Int) -> String {
        var remaining = max(0, column)
        var letters = ""
        repeat {
            let digit = remaining % 26
            letters = String(UnicodeScalar(UInt8(65 + digit))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    /// Full reference for a zero-based row and column: (0, 0) → `A1`.
    static func reference(row: Int, column: Int) -> String {
        "\(columnLetters(column))\(row + 1)"
    }
}

// MARK: - Date serials

/// Converts dates to the serial numbers Excel stores.
///
/// Dates go in as **numbers with a date format**, never as text: a text date makes a chart's category
/// axis degrade to plain labels and makes every BI tool re-infer the type from the string.
enum XLSXDateSerial {
    /// Excel's epoch. It is 1899-12-30, not 1899-12-31, because Excel keeps Lotus 1-2-3's phantom
    /// 29 February 1900 and the offset absorbs it.
    private static let epoch = Date(timeIntervalSince1970: -2_209_161_600)

    /// Days (with fraction) between Excel's epoch and `date`.
    static func serial(for date: Date) -> Double {
        date.timeIntervalSince(epoch) / 86_400
    }
}
