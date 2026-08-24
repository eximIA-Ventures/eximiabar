import Foundation

/// The one place a column title or a series name is written down.
///
/// **Why this type exists.** The export is a package of several artifacts built by different code
/// paths — the workbook, the panel, the tidy CSVs. Each of them named its own columns, and the names
/// drifted apart: the panel's legend said `Entrada` and `Cache — leitura` while the same package's
/// spreadsheet said `Tokens de entrada` and `Cache de leitura`. The owner opens two files from one
/// folder and reads different names for the same quantity.
///
/// The mechanism is what makes it worth a type rather than a fix: **each side tested its own piece
/// against its own expectation, and both passed.** No test could see the divergence, because the
/// comparison between pieces belonged to nobody. A duplicated literal will drift again at the next
/// edit, so the literal is removed rather than corrected.
///
/// **Choice of wording, and its cost.** The canonical labels are the long forms. A chart legend under
/// a title that already says "Tokens por dia" would read better as just `Entrada`, but the same words
/// have to work as a spreadsheet column header, where nothing supplies that context — and in the
/// workbook the chart legend is *derived from the header cell*, so the two cannot diverge there even
/// in principle. Short legends would mean decoupling the workbook's legend from its header, which is a
/// larger change than this one buys.
public enum ExportLabels {
    // MARK: - Token kinds (series names and column titles)

    /// The four kinds of token, in the order they are stacked and columned everywhere.
    public enum Token {
        public static let entrada = "Tokens de entrada"
        public static let saida = "Tokens de saída"
        public static let cacheLeitura = "Cache de leitura"
        public static let cacheEscrita = "Cache de escrita"

        /// The four, in canonical order. Any artifact that plots or lists them uses this order.
        public static let todos = [entrada, saida, cacheLeitura, cacheEscrita]
    }

    // MARK: - Shared column titles

    public static let dia = "Dia"
    public static let tokensTotal = "Tokens (total)"
    public static let custoEstimado = "Custo estimado (USD)"
    public static let modelo = "Modelo"
    public static let projeto = "Projeto"
    public static let diaDaSemana = "Dia da semana"
    public static let total = "Total"

    // MARK: - Header rows

    /// Columns of the daily sheet and of `dados/diario.csv`. Tokens first, cost last — the owner pays
    /// a subscription, so volume is the primary quantity and the dollar figure is an estimate beside it.
    public static let diario: [String] =
        [dia, tokensTotal] + Token.todos + [custoEstimado]

    /// Columns of the models sheet and of `dados/modelos.csv`.
    public static let modelos: [String] =
        [modelo, tokensTotal, Token.entrada, Token.saida, custoEstimado]

    /// Columns of the projects sheet and of `dados/projetos.csv`.
    public static let projetos: [String] = [projeto, tokensTotal, custoEstimado]
}
