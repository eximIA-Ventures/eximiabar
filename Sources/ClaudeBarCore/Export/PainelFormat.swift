import Foundation

// MARK: - Escaping

/// The two — and only two — boundaries where data crosses into the page.
///
/// **Why this is a security surface and not a formatting detail.** Project names come from
/// `CostScanner.projectName(fromCWD:)`, which is the last path component of a directory the user
/// created: arbitrary text. A folder named `</script><img src=x onerror=alert(1)>` would close the
/// data block and run in the browser of the person who double-clicks the file. There is no server
/// and no CSP here to catch it afterwards.
///
/// The panel therefore has exactly two escapes, both centralised in this type:
///
/// | Boundary | Function | Where |
/// |---|---|---|
/// | JSON inside `<script type="application/json">` | ``json(_:)`` | the single data block |
/// | text inside HTML/SVG markup | ``marcacao(_:)`` | KPI cards, axis labels, `<title>` tooltips |
///
/// The second one is **not** in the architecture note, which describes a single injection point. It
/// exists because the SVG charts label their axes with model and project names, and those labels have
/// to be in the bytes for the charts to work with JavaScript off. Rendering them from JSON at runtime
/// would remove this boundary and break that guarantee instead — so the boundary is kept, named, and
/// tested with the same hostile fixture.
public enum PainelEscape {
    /// Escapes a string for a JSON string literal that will live inside `<script>` in an HTML file.
    ///
    /// Beyond the escapes JSON requires, four characters are written as `\u00XX` / `\u202X`:
    ///
    /// - `<` and `>` — the two ways out of a `<script>` block are `</script>` and `<!--`
    /// - `&` — keeps the payload from being read as an HTML entity
    /// - U+2028 / U+2029 — legal in JSON, but line terminators to a JavaScript parser
    ///
    /// A unicode escape is still valid JSON, so `JSON.parse` in the browser reads the original text.
    public static func json(_ texto: String) -> String {
        var saida = ""
        saida.reserveCapacity(texto.count + 8)
        for escalar in texto.unicodeScalars {
            switch escalar {
            case "\"": saida += "\\\""
            case "\\": saida += "\\\\"
            case "\n": saida += "\\n"
            case "\r": saida += "\\r"
            case "\t": saida += "\\t"
            case "<": saida += "\\u003c"
            case ">": saida += "\\u003e"
            case "&": saida += "\\u0026"
            case "\u{2028}": saida += "\\u2028"
            case "\u{2029}": saida += "\\u2029"
            default:
                if escalar.value < 0x20 {
                    saida += String(format: "\\u%04x", escalar.value)
                } else {
                    saida.unicodeScalars.append(escalar)
                }
            }
        }
        return saida
    }

    /// Escapes text destined for an HTML or SVG text node, or for a double-quoted attribute.
    ///
    /// One function for both because the panel's markup quotes every attribute with `"`, so the same
    /// five replacements are sufficient in either position — and one function is one thing to audit.
    public static func marcacao(_ texto: String) -> String {
        var saida = ""
        saida.reserveCapacity(texto.count + 8)
        for caractere in texto {
            switch caractere {
            case "&": saida += "&amp;"
            case "<": saida += "&lt;"
            case ">": saida += "&gt;"
            case "\"": saida += "&quot;"
            case "'": saida += "&#39;"
            default: saida.append(caractere)
            }
        }
        return saida
    }
}

// MARK: - Numbers

/// Deterministic pt-BR formatting, done by hand.
///
/// **`NumberFormatter` is not used, and that is the point.** A formatter reads the machine's locale,
/// so the same input would produce different bytes on a differently configured Mac — which would make
/// the sha256 determinism gate pass here and fail there, for a reason no test message would name.
/// Grouping with `.` and decimals with `,` are written out explicitly instead.
public enum PainelFormat {
    /// `1234567` → `1.234.567`.
    public static func inteiro(_ valor: Int) -> String {
        let negativo = valor < 0
        var digitos = Array(String(abs(valor)))
        var grupos: [String] = []
        while digitos.count > 3 {
            grupos.insert(String(digitos.suffix(3)), at: 0)
            digitos.removeLast(3)
        }
        grupos.insert(String(digitos), at: 0)
        return (negativo ? "-" : "") + grupos.joined(separator: ".")
    }

    /// `1234.5` with 2 places → `1.234,50`.
    public static func decimal(_ valor: Double, casas: Int) -> String {
        guard valor.isFinite else { return "—" }
        let texto = String(format: "%.\(casas)f", valor)
        let negativo = texto.hasPrefix("-")
        let semSinal = negativo ? String(texto.dropFirst()) : texto
        let partes = semSinal.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let inteiraFormatada = inteiro(Int(partes[0]) ?? 0)
        let fracionaria = partes.count > 1 ? "," + partes[1] : ""
        return (negativo ? "-" : "") + inteiraFormatada + fracionaria
    }

    /// `1.9412` → `US$ 1,94`.
    public static func moeda(_ valor: Double, casas: Int = 2) -> String {
        "US$ " + decimal(valor, casas: casas)
    }

    /// `0.4237` → `42,4%`. The input is a fraction, never an already-multiplied percentage.
    public static func percentual(_ fracao: Double) -> String {
        guard fracao.isFinite else { return "—" }
        return decimal(fracao * 100, casas: 1) + "%"
    }

    /// Short form for axis labels: `1.240.000` → `1,24 mi`, `8_500` → `8,5 mil`.
    public static func compacto(_ valor: Double) -> String {
        let absoluto = abs(valor)
        if absoluto >= 1_000_000_000 { return decimal(valor / 1_000_000_000, casas: 1) + " bi" }
        if absoluto >= 1_000_000 { return decimal(valor / 1_000_000, casas: 2) + " mi" }
        if absoluto >= 1_000 { return decimal(valor / 1_000, casas: 1) + " mil" }
        return decimal(valor, casas: 0)
    }

    /// A number for a JSON literal: shortest exact-enough form, with `.` as the decimal mark.
    ///
    /// Six decimal places then trimmed, rather than `"\(double)"`, because Swift's own description
    /// can emit exponent notation (`1e-05`) — valid JSON, but a needless difference between two
    /// numbers of the same magnitude in a file whose bytes are asserted.
    public static func literalJSON(_ valor: Double) -> String {
        guard valor.isFinite else { return "null" }
        var texto = String(format: "%.6f", valor)
        if texto.contains(".") {
            while texto.hasSuffix("0") { texto.removeLast() }
            if texto.hasSuffix(".") { texto.removeLast() }
        }
        return texto.isEmpty || texto == "-0" ? "0" : texto
    }
}

// MARK: - Dates

/// Calendar formatting without `DateFormatter`.
///
/// `DateFormatter` is a reference type and not `Sendable`, so it cannot be a `static let` under Swift
/// 6's strict concurrency; and its output depends on the machine's locale. Both problems disappear by
/// pulling components out of `Calendar` and printing them with a fixed pattern.
public enum PainelDatas {
    /// The calendar the dashboard itself used to bucket days, so a "day" means the same thing here.
    static var calendario: Calendar { Calendar.current }

    /// `2026-08-24` — the machine-readable form, used in the JSON block.
    public static func iso(_ data: Date) -> String {
        let partes = calendario.dateComponents([.year, .month, .day], from: data)
        return String(format: "%04d-%02d-%02d", partes.year ?? 0, partes.month ?? 0, partes.day ?? 0)
    }

    /// `24/08` — the compact form, used on a crowded axis.
    public static func diaMes(_ data: Date) -> String {
        let partes = calendario.dateComponents([.month, .day], from: data)
        return String(format: "%02d/%02d", partes.day ?? 0, partes.month ?? 0)
    }

    /// `24/08/2026` — the form a person reads in the coverage block.
    public static func longa(_ data: Date) -> String {
        let partes = calendario.dateComponents([.year, .month, .day], from: data)
        return String(format: "%02d/%02d/%04d", partes.day ?? 0, partes.month ?? 0, partes.year ?? 0)
    }

    /// Weekday names, index 0 = Sunday, matching the heat map's row order.
    public static let diasDaSemana = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
}
