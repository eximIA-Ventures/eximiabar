import Foundation

/// One day's position on the "hoje entre os pares" strip (EXB-5.10 G3).
struct DiaDaDistribuicao: Equatable, Identifiable {
    var id: Double { date.timeIntervalSinceReferenceDate }
    let date: Date
    /// Tokens for the day — the same `input + output` measure the "hoje" card publishes, so the
    /// highlighted dot and the number above it are the same quantity.
    let tokens: Int
    /// `true` for the one dot drawn in the accent colour.
    let ehHoje: Bool
}

/// Today against every other day the source watched (EXB-5.10 G3).
///
/// **What this fixes, and what it does not.** The badge over this card compares today against the
/// *mean*. Token consumption is strongly right-skewed — a handful of enormous days pull the mean far
/// above the day the Senhor actually has most of the time — so "+40 % acima da média" can describe a
/// completely ordinary day, and "abaixo da média" can describe a busy one. Position among peers is
/// robust to that skew and needs no interpretation: the dot is either out at the edge or it is not.
///
/// It **complements** the badge rather than replacing it: the badge prorates by the fraction of the
/// day elapsed and can therefore speak at 09:00, which a raw position cannot.
///
/// Pure and deterministic; `hoje` is injected so the strip does not depend on when the suite runs.
struct DistribuicaoDiaria: Equatable {
    /// One dot per covered day, ascending by date.
    let dias: [DiaDaDistribuicao]
    /// Median tokens over the covered days — the rule line.
    ///
    /// The median and not the mean, deliberately: this strip exists because the mean is the statistic
    /// the skew defeats.
    let mediana: Double
    /// Today's tokens, when today is on the covered axis at all. `nil` for a dragged range that ends
    /// before today, where there is no "today" dot to highlight.
    let tokensDeHoje: Int?
    /// Where today falls among its peers, `0…1` — `nil` whenever ``tokensDeHoje`` is.
    ///
    /// The **mid-point of today's tie band**, not the count of days at or below it. On an axis with a
    /// heavy mode — a run of days at the same round volume, which is common here — counting `<=` puts
    /// a perfectly typical day at the top of its own band and reports "acima de 91% dos dias" about a
    /// day that is tied with 90 % of them. Counting `<` puts the same day at the bottom and reports
    /// 0 %. Both are arithmetically defensible and both mislead; the midpoint of the band is the one
    /// that says what the reader is going to conclude anyway.
    let posicaoDeHoje: Double?

    /// Build from the day axis.
    ///
    /// - Parameters:
    ///   - dias: the covered day axis — pass `DashboardData.diasCobertos`, never `dailyCosts`. An
    ///     uncovered day carries `tokens == 0` and would land on the pile at the left edge, which is
    ///     the "we never watched this" / "nothing happened" confusion this screen exists to refuse.
    ///     Covered days with a genuine zero **do** belong: a day off is a real day.
    ///   - hoje: any instant of the current day; normalized to the start of the local day.
    init(dias entradas: [DashboardDailyEntry], hoje: Date, calendar: Calendar = .current) {
        let inicioDeHoje = calendar.startOfDay(for: hoje)
        self.dias = entradas
            .sorted { $0.date < $1.date }
            .map {
                DiaDaDistribuicao(date: $0.date, tokens: $0.tokens, ehHoje: $0.date == inicioDeHoje)
            }

        let valores = entradas.map(\.tokens).sorted()
        self.mediana = Self.mediana(deOrdenados: valores)

        let hojeEntrada = entradas.first { $0.date == inicioDeHoje }
        self.tokensDeHoje = hojeEntrada?.tokens
        if let tokens = hojeEntrada?.tokens, !valores.isEmpty {
            let abaixo = valores.filter { $0 < tokens }.count
            let abaixoOuIgual = valores.filter { $0 <= tokens }.count
            self.posicaoDeHoje =
                (Double(abaixo) + Double(abaixoOuIgual)) / 2 / Double(valores.count)
        } else {
            self.posicaoDeHoje = nil
        }
    }

    /// Median of an already-sorted array: the middle value, or the mean of the two middles for an even
    /// count. `0` for an empty input — there is no median of nothing, and the strip draws no rule then.
    static func mediana(deOrdenados valores: [Int]) -> Double {
        guard !valores.isEmpty else { return 0 }
        let meio = valores.count / 2
        if valores.count % 2 == 1 { return Double(valores[meio]) }
        return (Double(valores[meio - 1]) + Double(valores[meio])) / 2
    }

    /// `true` when there is enough spread to be worth drawing.
    ///
    /// One dot, or a run of identical days, produces a strip on which every position looks the same —
    /// an ornament that implies a comparison it cannot make. Below this bar the card shows the badge
    /// alone.
    var vaiDesenhar: Bool {
        guard dias.count >= 3 else { return false }
        let valores = dias.map(\.tokens)
        return (valores.max() ?? 0) > (valores.min() ?? 0)
    }
}
