import ClaudeBarCore
import Foundation

/// Why a month's divisor is smaller than the calendar's — the distinction `MonthCoverage` carries in
/// three separate numbers and that a label must not collapse into one.
///
/// `daysInRange` and `daysCovered` answer different questions. The first says the **selection** did
/// not take the whole month ("the Senhor dragged across it"); the second says the **archive** was not
/// watching ("that history does not exist"). Both shrink the denominator; only the second is a claim
/// about missing data, and a cascade that reports "sem histórico" for a month the user merely dragged
/// past would be blaming the archive for the user's gesture.
enum RecorteDoMes: Equatable {
    /// Every day of the calendar month was both selected and watched.
    case completo
    /// The selection clipped the month: `dias` of `daysInMonth` fell inside the dragged range.
    case selecao(dias: Int, noMes: Int)
    /// The archive is missing days the selection did include: `dias` watched of `naSelecao` selected.
    case historico(dias: Int, naSelecao: Int)
    /// Both at once — the selection clipped it *and* part of what remained was never watched.
    case ambos(cobertos: Int, naSelecao: Int, noMes: Int)

    /// Read the three numbers into one reason, without losing either of them.
    ///
    /// **"Complete" is asked of the contract, not re-derived.** `daysInRange == daysInMonth &&
    /// daysCovered == daysInRange` is arithmetically the same as `isComplete`, and that is exactly the
    /// problem: a second expression of one fact agrees until the day the first one moves. The guard
    /// below reads `MonthCoverage.isComplete`, so there is one definition of a whole month in this
    /// codebase and it lives beside the three numbers it is computed from.
    init(_ cobertura: MonthCoverage) {
        guard !cobertura.isComplete else { self = .completo; return }
        let selecaoRecortou = cobertura.daysInRange < cobertura.daysInMonth
        let historicoFaltou = cobertura.daysCovered < cobertura.daysInRange
        switch (selecaoRecortou, historicoFaltou) {
        case (true, false): self = .selecao(dias: cobertura.daysInRange, noMes: cobertura.daysInMonth)
        case (true, true):
            self = .ambos(
                cobertos: cobertura.daysCovered,
                naSelecao: cobertura.daysInRange,
                noMes: cobertura.daysInMonth)
        // Not whole, and the selection took the month entire: the missing days are the archive's.
        // `(false, false)` reaches here only on a malformed coverage row (covered days beyond the
        // selection, say), and reporting the two real numbers is more honest than calling it whole
        // because a flag did not fire.
        case (false, _): self = .historico(dias: cobertura.daysCovered, naSelecao: cobertura.daysInRange)
        }
    }
}

/// One month of the pair, with the divisor it is being read against.
struct MesDaCascata: Equatable {
    /// First day of the month, local time zone.
    let mes: Date
    /// Days that actually contributed — the divisor, and the number the label has to say out loud.
    let diasComDado: Int
    /// Total tokens the month contributed within the selection.
    let tokens: Int
    let recorte: RecorteDoMes

    /// Tokens per day with data. **The measure the whole chart is drawn in.**
    var porDia: Double { diasComDado > 0 ? Double(tokens) / Double(diasComDado) : 0 }
}

/// One bar of the waterfall.
struct PassoDaCascata: Equatable, Identifiable {
    enum Tipo: Equatable {
        /// The previous month's rate, drawn from zero — where the reading starts.
        case base
        /// One project's contribution to the change.
        case contribuicao
        /// Everything outside the cap, plus the archive's own aggregate rows, summed.
        case outros
        /// The current month's rate, drawn from zero — where the reading ends.
        case total
    }

    /// Position on the x axis, left to right — **and the x value itself**.
    ///
    /// The bars are placed by ordinal rather than by name because two of them (the base and the
    /// total) are named after months, which the view formats. Keying the axis on the label would let
    /// two bars with the same string collapse into one category, and a waterfall that silently merges
    /// two bars still draws.
    var id: Int { ordem }
    let ordem: Int
    /// The project name, or the injected label for the aggregate bar. Empty on the base and total
    /// bars, which the view names after their month.
    let rotulo: String
    let tipo: Tipo
    /// Where the bar starts on the y axis, in tokens per day with data.
    let inicio: Double
    /// Where it ends. `fim - inicio` is the contribution.
    let fim: Double

    /// Signed contribution — positive when the project pushed the month up.
    var variacao: Double { fim - inicio }
}

/// Who made the month change, and the guard that stops it from answering when it cannot.
///
/// **The defect this is built around.** Comparing an incomplete month with a complete one fabricates
/// a fall. On the 25th, August holds 25 days and July holds 31: *every* project reads as having
/// slowed, the chart agrees with itself perfectly, and the conclusion — "everything decelerated" — is
/// false by construction. It is the same shape as the "-99 % below average" this screen corrected two
/// days ago, and it is invisible precisely because every bar points the same way.
///
/// **The decision, and why.** Three responses were available; this takes all three, layered, because
/// they answer different failures:
///
/// 1. **Normalize** — every figure is *tokens per day with data*, always, including when both months
///    are complete. A measure that switches definition depending on the calendar is a measure whose
///    two readings cannot be compared with each other, and choosing the divisor silently is the exact
///    defect that let a ~40 % error live on the averages card. Dividing always costs nothing when the
///    months are whole (31 and 30 are honest divisors) and is the only correct answer when they are not.
/// 2. **Label** — the divisor travels with the number, per month, naming *which* of the three coverage
///    figures shrank it (see ``RecorteDoMes``).
/// 3. **Refuse** — below ``minimoDeDiasComDado`` there is no rate to speak of, only one or two days
///    wearing the word "average". The chart then states why it is silent instead of drawing.
///
/// Pure and deterministic; the calendar is injected so the suite can run under three time zones.
struct CascataMensal: Equatable {
    /// Why there is nothing to draw. Never a silent empty chart: an absent explanation is how a guard
    /// gets mistaken for "no usage".
    enum Recusa: Equatable {
        /// Fewer than two months of coverage in the selection.
        case parInsuficiente
        /// One of the two months has too few days with data for a rate to mean anything.
        case coberturaFina(mes: Date, dias: Int)
    }

    /// How few days with data is too few for a "per day" figure to be an average rather than a day.
    ///
    /// Three is a floor, not a precision claim: at one or two days the divisor is small enough that a
    /// single unusual session moves the whole month, and the bar would read as a behavioural change.
    /// Stated here as a named constant because a threshold nobody can find is a threshold nobody can
    /// argue with.
    static let minimoDeDiasComDado = 3

    /// How many movers get a bar of their own before the rest are summed into "others".
    static let maximoDeMovimentadores = 6

    /// The earlier month of the pair, `nil` when the cascade refused.
    let anterior: MesDaCascata?
    /// The later month of the pair, `nil` when the cascade refused.
    let atual: MesDaCascata?
    /// The bars, left to right: base, movers (positive then negative), others, total. Empty on refusal.
    let passos: [PassoDaCascata]
    /// How many movers past the cap were folded into the "others" bar.
    ///
    /// Separate from ``incluiAgregadoDoArquivo`` on purpose: the archive's own aggregate row already
    /// stands for an unknown number of small projects, so adding 1 for it would publish a project
    /// count that is simply wrong. Two facts, stated as two facts.
    let movimentadoresEmOutros: Int
    /// `true` when the "others" bar also carries the archive's own aggregate rows (`isOthers`).
    let incluiAgregadoDoArquivo: Bool
    /// Why nothing is drawn, when nothing is drawn.
    let recusa: Recusa?

    /// The change between the two rates — the number the whole chart decomposes.
    var variacaoTotal: Double { (atual?.porDia ?? 0) - (anterior?.porDia ?? 0) }

    /// `true` when there is a comparison on screen.
    var vaiDesenhar: Bool { recusa == nil && !passos.isEmpty }

    /// Build the comparison between the two most recent months the selection covers.
    ///
    /// - Parameters:
    ///   - porDiaProjeto: `DashboardData.byDayProject`, already clipped to the covered days.
    ///   - cobertura: `DashboardData.monthCoverage`, ascending by month.
    ///   - rotuloDeOutros: the localized name of the aggregate bar, injected so this type stays free
    ///     of the localization table and testable without it.
    init(
        porDiaProjeto: [DayProjectEntry],
        cobertura: [MonthCoverage],
        rotuloDeOutros: String,
        calendar: Calendar = .current)
    {
        // The **last two months the archive can speak about**, not the last two on the calendar. A
        // month absent from `monthCoverage` is one the scan never watched inside this selection, and
        // reaching past it to find a pair would compare across a hole.
        let ordenados = cobertura.sorted { $0.month < $1.month }
        guard ordenados.count >= 2,
              let coberturaAnterior = ordenados.dropLast().last,
              let coberturaAtual = ordenados.last
        else {
            self.anterior = nil
            self.atual = nil
            self.passos = []
            self.movimentadoresEmOutros = 0
            self.incluiAgregadoDoArquivo = false
            self.recusa = .parInsuficiente
            return
        }

        // Tokens per `(month, project)`, folded from the day grain. Aggregate rows keep their own
        // identity here — they are a sum of real projects, not a remainder, so they belong in the
        // "others" bar rather than being dropped.
        var tokensPorMes: [Date: Int] = [:]
        var porProjeto: [String: (anterior: Int, atual: Int)] = [:]
        var outros: (anterior: Int, atual: Int) = (0, 0)
        for linha in porDiaProjeto {
            guard let mes = calendar.date(
                from: calendar.dateComponents([.year, .month], from: linha.day))
            else { continue }
            guard mes == coberturaAnterior.month || mes == coberturaAtual.month else { continue }
            let ehAnterior = mes == coberturaAnterior.month
            tokensPorMes[mes, default: 0] += linha.totalTokens
            if linha.isOthers {
                if ehAnterior { outros.anterior += linha.totalTokens } else { outros.atual += linha.totalTokens }
            } else if ehAnterior {
                porProjeto[linha.project, default: (0, 0)].anterior += linha.totalTokens
            } else {
                porProjeto[linha.project, default: (0, 0)].atual += linha.totalTokens
            }
        }

        let mesAnterior = MesDaCascata(
            mes: coberturaAnterior.month,
            diasComDado: coberturaAnterior.daysCovered,
            tokens: tokensPorMes[coberturaAnterior.month] ?? 0,
            recorte: RecorteDoMes(coberturaAnterior))
        let mesAtual = MesDaCascata(
            mes: coberturaAtual.month,
            diasComDado: coberturaAtual.daysCovered,
            tokens: tokensPorMes[coberturaAtual.month] ?? 0,
            recorte: RecorteDoMes(coberturaAtual))
        self.anterior = mesAnterior
        self.atual = mesAtual

        // The refusal is checked on both months and reports the thinner one, so the message names the
        // month the reader has to go and look at.
        let magro = [mesAnterior, mesAtual].min { $0.diasComDado < $1.diasComDado }
        if let magro, magro.diasComDado < Self.minimoDeDiasComDado {
            self.passos = []
            self.movimentadoresEmOutros = 0
            self.incluiAgregadoDoArquivo = false
            self.recusa = .coberturaFina(mes: magro.mes, dias: magro.diasComDado)
            return
        }
        self.recusa = nil

        let diasAnterior = Double(Swift.max(1, mesAnterior.diasComDado))
        let diasAtual = Double(Swift.max(1, mesAtual.diasComDado))

        struct Movimento {
            let projeto: String
            let variacao: Double
        }
        let movimentos = porProjeto
            .map { projeto, valores in
                Movimento(
                    projeto: projeto,
                    variacao: Double(valores.atual) / diasAtual - Double(valores.anterior) / diasAnterior)
            }
            // Largest movement first, whichever way it moved: the question is "who changed the month",
            // and a project that fell by a lot changed it exactly as much as one that rose by a lot.
            .sorted { abs($0.variacao) != abs($1.variacao)
                ? abs($0.variacao) > abs($1.variacao)
                : $0.projeto < $1.projeto }

        let destacados = Array(movimentos.prefix(Self.maximoDeMovimentadores))
        let restantes = movimentos.dropFirst(Self.maximoDeMovimentadores)
        // Positives before negatives, each group already in magnitude order. A waterfall that
        // interleaves the two directions makes the running line saw back and forth and hides which
        // side won.
        let ordenadas = destacados.filter { $0.variacao > 0 } + destacados.filter { $0.variacao <= 0 }

        // The residual is a **sum, not a remainder**: the archive's own aggregate rows plus every
        // mover past the cap. Computed by addition rather than as `total − Σ bars`, because a
        // remainder always closes the waterfall — including when a contribution above it is wrong,
        // which is precisely when the reader needs to see that it does not close.
        let variacaoDeOutros = restantes.reduce(0.0) { $0 + $1.variacao }
            + (Double(outros.atual) / diasAtual - Double(outros.anterior) / diasAnterior)
        self.movimentadoresEmOutros = restantes.count
        self.incluiAgregadoDoArquivo = outros.anterior > 0 || outros.atual > 0

        var passos: [PassoDaCascata] = []
        passos.append(PassoDaCascata(
            ordem: 0,
            rotulo: "",                       // the view names the base bar with the month itself
            tipo: .base,
            inicio: 0,
            fim: mesAnterior.porDia))
        var corrente = mesAnterior.porDia
        for movimento in ordenadas {
            passos.append(PassoDaCascata(
                ordem: passos.count,
                rotulo: movimento.projeto,
                tipo: .contribuicao,
                inicio: corrente,
                fim: corrente + movimento.variacao))
            corrente += movimento.variacao
        }
        if variacaoDeOutros != 0 || !restantes.isEmpty {
            passos.append(PassoDaCascata(
                ordem: passos.count,
                rotulo: rotuloDeOutros,
                tipo: .outros,
                inicio: corrente,
                fim: corrente + variacaoDeOutros))
            corrente += variacaoDeOutros
        }
        passos.append(PassoDaCascata(
            ordem: passos.count,
            rotulo: "",
            tipo: .total,
            inicio: 0,
            fim: mesAtual.porDia))
        self.passos = passos
    }

    /// Convenience over the view model — one construction path for the screen and the suite.
    init(data: DashboardData, rotuloDeOutros: String, calendar: Calendar = .current) {
        self.init(
            porDiaProjeto: data.byDayProject,
            cobertura: data.monthCoverage,
            rotuloDeOutros: rotuloDeOutros,
            calendar: calendar)
    }
}
