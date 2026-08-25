import AppKit
import Foundation
import Testing
@testable import ClaudeBar

/// Every KPI card title has to FIT the card it sits on, in **both** languages (EXB-5.10 follow-up).
///
/// **The defect that earned this file.** `"Average per day of the window"` shipped on screen as
/// `"Average per day of the win…"`. Thirty-four tests were green and none of them could see it: the
/// title is rendered, the value is right, the derivation is right — the string is simply wider than
/// the box. It is the same family as the clipped spreadsheet header fixed the day before, moved from
/// a file to a screen.
///
/// **Why a measurement and not a length limit.** "Keep titles under N characters" is a rule about
/// the wrong quantity: `"Média por dia da janela"` and `"Average per day of the window"` differ by
/// six characters and by far more than six points. So this measures the **typeset width** of the
/// actual string in the actual font, and compares it against the width the card actually offers.
///
/// **What it approximates, stated plainly.** SwiftUI's `.headline` resolves to
/// `NSFont.preferredFont(forTextStyle: .headline)`, and `boundingRect` is the same typesetter
/// AppKit uses — but SwiftUI's own layout can differ by a hair, so this is a close ruler rather than
/// a pixel-exact one.
///
/// **Calibrated, not assumed.** Set `linhasPermitidas` to 1 — the configuration that shipped — and
/// this suite fails on exactly two strings and no others:
///
/// - `en/dashboard.volume.avg_window`, `"Average per day of the window"` (198pt against a 180pt box),
///   which is the truncation seen in the render, and
/// - `en/dashboard.cost.total`, `"Estimated cost for the period"` (188pt), which was clipping too and
///   was **not** visible in any screenshot, because the cost section had not been rendered.
///
/// The second one is why the ruler exists at all: an eye finds the defect it happened to look at, and
/// a measurement finds the ones nobody photographed.
struct DashboardCardLabelFitTests {
    /// `GridItem(.adaptive(minimum: 168))` minus `MetricCard`'s 12pt padding on each side.
    static let larguraDisponivel: CGFloat = 168 - 24

    /// `MetricCard` allows the title to shrink to 80 % before it would clip, so a string may be this
    /// much wider than the box and still be drawn whole.
    static let fatorDeReducao: CGFloat = 0.8

    /// How many lines the title is allowed to occupy.
    static let linhasPermitidas: Int = 2

    static var fonte: NSFont { .preferredFont(forTextStyle: .headline) }

    /// Every string used as a card title anywhere on the dashboard.
    static let chavesDeTitulo = [
        "dashboard.volume.total",
        "dashboard.volume.avg_covered",
        "dashboard.volume.avg_window",
        "dashboard.summary.today",
        "dashboard.summary.last_7_days",
        "dashboard.summary.projection",
        "dashboard.cost.total",
        "dashboard.cost.today",
        "dashboard.insights.cache_hit.title",
        "dashboard.insights.month.title",
    ]

    private func withLanguage<T>(_ language: String, _ body: () -> T) -> T {
        ClaudeBarLocalization.$languageOverride.withValue(language) {
            resetClaudeBarLocalizationCache()
            defer { resetClaudeBarLocalizationCache() }
            return body()
        }
    }

    /// Typeset height of `texto` wrapped into `largura`, in the card's title font.
    static func altura(_ texto: String, largura: CGFloat) -> CGFloat {
        let atributos: [NSAttributedString.Key: Any] = [.font: fonte]
        return (texto as NSString).boundingRect(
            with: NSSize(width: largura, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: atributos).height
    }

    /// Typeset width of `texto` on a single line.
    static func largura(_ texto: String) -> CGFloat {
        (texto as NSString).size(withAttributes: [.font: fonte]).width
    }

    /// The ceiling for `linhasPermitidas` lines, with a little slack for leading rounding.
    static var alturaMaxima: CGFloat { fonte.boundingRectForFont.height * CGFloat(linhasPermitidas) + 2 }

    /// **The gate.** No card title overflows the box it is drawn in, in either language.
    @Test
    func noCardTitleOverflowsItsCardInEitherLanguage() {
        for idioma in ["en", "pt-BR"] {
            withLanguage(idioma) {
                for chave in Self.chavesDeTitulo {
                    let texto = L(chave)
                    #expect(texto != chave, "\(idioma)/\(chave) is missing from the table")
                    let caixa = Self.larguraDisponivel / Self.fatorDeReducao
                    let altura = Self.altura(texto, largura: caixa)
                    #expect(
                        altura <= Self.alturaMaxima,
                        "\(idioma)/\(chave) needs \(Int(altura))pt for \"\(texto)\" — the card offers \(Int(Self.alturaMaxima))pt")
                }
            }
        }
    }

    /// The measurements themselves, printed so the margins are visible rather than merely asserted.
    ///
    /// A gate that only says PASS teaches nothing about how close the next translation is to failing —
    /// and the whole reason this file exists is that a string cleared its box by less than nobody
    /// noticed.
    @Test
    func theMarginsArePublishedNotJustAsserted() {
        var maisLargo: (String, CGFloat) = ("", 0)
        for idioma in ["en", "pt-BR"] {
            withLanguage(idioma) {
                for chave in Self.chavesDeTitulo {
                    let texto = L(chave)
                    let largura = Self.largura(texto)
                    if largura > maisLargo.1 { maisLargo = ("\(idioma)/\(texto)", largura) }
                    print(String(
                        format: "FIT %-6s %-38s %6.1fpt (uma linha) / caixa %5.1fpt",
                        (idioma as NSString).utf8String!, (chave as NSString).utf8String!,
                        largura, Self.larguraDisponivel / Self.fatorDeReducao))
                }
            }
        }
        print("FIT widest: \(maisLargo.0) at \(Int(maisLargo.1))pt")
        #expect(maisLargo.1 > 0)
    }
}
