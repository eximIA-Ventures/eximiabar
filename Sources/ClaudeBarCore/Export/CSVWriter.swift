import Foundation

/// One value in a CSV table. Typed rather than pre-stringified, so the formatting decisions —
/// decimal point, ISO dates, blank versus zero — are taken in one place instead of at every call site.
public enum CSVValue: Sendable, Equatable {
    case text(String)
    /// A number rendered with exactly `decimals` decimal places, always with a `.` separator.
    case number(Double, decimals: Int)
    case integer(Int)
    /// Rendered as `yyyy-MM-dd` in UTC.
    case date(Date)
    /// An empty field — **not** a zero. The distinction survives into the BI model as null.
    case blank
}

/// A table destined for one `.csv` file.
public struct CSVTable: Sendable, Equatable {
    /// File base name, without the extension (e.g. `diario`).
    public let name: String
    /// Column titles, written as the first line.
    public let header: [String]
    public let rows: [[CSVValue]]

    public init(name: String, header: [String], rows: [[CSVValue]]) {
        self.name = name
        self.header = header
        self.rows = rows
    }
}

/// Renders a ``CSVTable`` as bytes.
///
/// **The dialect, and why it is this one.** Comma separator, `.` decimal, ISO dates, UTF-8 with a BOM,
/// CRLF line endings (RFC 4180).
///
/// The comma is a decision with a real trade-off, so it is written down rather than assumed. Three
/// dialects were on the table:
///
/// - **comma + `.` decimal** — every BI tool reads it with no configuration. Double-clicking it in a
///   pt-BR Excel drops the whole row into one column, because Excel splits on the system list
///   separator, which is `;` there.
/// - **semicolon + `,` decimal** — opens perfectly in a pt-BR Excel, but every BI tool then needs to be
///   told the delimiter and the locale.
/// - **semicolon + `.` decimal** — the trap. Excel splits the columns correctly and then reads `1.9412`
///   as *19412*, because in pt-BR the dot is a thousands separator. Right-looking columns, wrong
///   numbers, no error. Rejected outright.
///
/// The first was chosen because these files exist for machine ingestion — the human artifacts of the
/// package are the workbook and the panel, both of which open correctly with a double click. The BOM
/// is kept anyway: it costs three bytes, fixes the encoding for anyone who does open a CSV in Excel,
/// and is understood by every BI tool. It does **not** fix the column splitting; nothing but changing
/// the separator would, and that would break the file's actual purpose.
public enum CSVWriter {
    /// The bytes of `table`, ready to write to disk.
    public static func data(for table: CSVTable) -> Data {
        var text = ""
        text += table.header.map(escape).joined(separator: ",")
        text += lineEnding
        for row in table.rows {
            text += row.map(field).joined(separator: ",")
            text += lineEnding
        }
        return byteOrderMark + Data(text.utf8)
    }

    /// RFC 4180 specifies CRLF, and both Excel and every BI connector accept it.
    static let lineEnding = "\r\n"

    /// UTF-8 BOM. Without it, Excel guesses the encoding from the system code page and turns
    /// `Tokens de saída` into mojibake.
    static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    /// One field, formatted and escaped.
    static func field(_ value: CSVValue) -> String {
        switch value {
        case .blank:
            return ""
        case let .text(string):
            return escape(neutralizeFormula(string))
        case let .integer(number):
            return String(number)
        case let .number(number, decimals):
            guard number.isFinite else { return "" }
            return String(format: "%.\(decimals)f", number)
        case let .date(date):
            return isoDay(date)
        }
    }

    /// Quotes a field when it needs quoting, doubling any embedded quote.
    static func escape(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Defuses CSV formula injection.
    ///
    /// **Why this exists.** Project names come from directory names on disk, so a folder called
    /// `=cmd|'/c calc'!A1` is a string this writer will faithfully emit. Excel evaluates a cell whose
    /// text begins with `=`, `+`, `-` or `@` as a formula, which turns opening the export into running
    /// whatever the folder name says. It is the same class of problem as the panel's `</script>`
    /// escape, on the other artifact of the same package — and it was not in the architecture note.
    ///
    /// The fix is a leading apostrophe, which Excel consumes as "treat as text". It is applied **only
    /// to text fields**: numbers are formatted by this writer and can never carry a payload, and
    /// prefixing them would corrupt every negative value, since `-` is in the dangerous set.
    static func neutralizeFormula(_ value: String) -> String {
        guard let first = value.first else { return value }
        let dangerous: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        return dangerous.contains(first) ? "'" + value : value
    }

    /// `yyyy-MM-dd` in UTC, computed rather than formatted — no locale, no calendar setting, no
    /// mutable global under strict concurrency.
    static func isoDay(_ date: Date) -> String {
        var days = Int(floor(date.timeIntervalSince1970 / 86_400))
        days += 719_468
        let era = (days >= 0 ? days : days - 146_096) / 146_097
        let dayOfEra = days - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return String(format: "%04d-%02d-%02d", month <= 2 ? year + 1 : year, month, day)
    }
}
