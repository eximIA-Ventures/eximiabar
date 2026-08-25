import Foundation

/// The colour ramp of the 12-month calendar, cut by **quantile** rather than by value (EXB-5.10 G4).
///
/// **Why not a linear ramp.** Daily token volume is strongly right-skewed: a few enormous days sit an
/// order of magnitude above the rest. Spreading colour linearly from `0` to `max` therefore parks the
/// great majority of days in the bottom sliver of the ramp, and a calendar built to show a year of
/// rhythm renders as one uniform pale sheet with two or three bright squares. Cutting at quantiles
/// spends the same amount of colour on the same number of days, which is what makes the *pattern*
/// legible instead of only the peaks.
///
/// Four non-zero levels plus a zero level, in the spirit of the contribution calendars this reads
/// like. Ties are resolved by value, never by rank, so two days with identical volume can never be
/// painted differently.
struct CalendarioQuantis: Equatable {
    /// The three cut points between the four non-zero levels, non-decreasing. Empty when there is no
    /// non-zero day to cut.
    let cortes: [Int]
    /// How many non-zero days the cuts were computed from — published so the legend can say when the
    /// sample is too thin for the gradation to mean much.
    let amostra: Int

    /// The number of non-zero levels. Level `0` is the zero day, so the ramp has `níveis + 1` steps.
    static let niveis = 4

    /// Compute the cuts from the days that will actually be painted.
    ///
    /// Only `tokens > 0` feeds the quantiles: a year of a new install is mostly zeros, and letting
    /// them into the sample would push all three cuts to `0` and collapse the four active levels into
    /// one. Zero is not a low value on this ramp — it is its own level.
    init(tokens: [Int]) {
        let naoZero = tokens.filter { $0 > 0 }.sorted()
        amostra = naoZero.count
        guard !naoZero.isEmpty else {
            cortes = []
            return
        }
        cortes = [0.25, 0.5, 0.75].map { Self.quantil(deOrdenados: naoZero, $0) }
    }

    /// Nearest-rank quantile of an already-sorted array, `q` in `(0, 1]`.
    static func quantil(deOrdenados valores: [Int], _ q: Double) -> Int {
        guard !valores.isEmpty else { return 0 }
        let posicao = Int((q * Double(valores.count)).rounded(.up)) - 1
        return valores[Swift.min(Swift.max(posicao, 0), valores.count - 1)]
    }

    /// The level for a day: `0` for a zero day, `1…4` for a day with activity.
    ///
    /// A zero day is level `0` and **is drawn** — it is a day the source watched and on which nothing
    /// happened, which is a fact. A day the source never watched has no level at all: it is absent
    /// from the grid, and that difference is the whole reason this chart is on the screen.
    func nivel(tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        var nivel = 1
        for corte in cortes where tokens > corte { nivel += 1 }
        return Swift.min(nivel, Self.niveis)
    }

    /// The level as a `0…1` position on the shared terracotta ramp.
    func intensidade(tokens: Int) -> Double {
        Double(nivel(tokens: tokens)) / Double(Self.niveis)
    }
}

/// One painted cell of the calendar. Days the source never watched produce **no** `CalendarioDia` —
/// the grid has a hole there, which is a different visual channel from the floor of the colour ramp.
struct CalendarioDia: Equatable, Identifiable {
    var id: Double { data.timeIntervalSinceReferenceDate }
    let data: Date
    /// Column index, `0` at the oldest week on the grid.
    let coluna: Int
    /// Row index within the week, `0` at the calendar's own first weekday (locale-aware).
    let linha: Int
    /// Tokens for the day — `0` is a legitimate, painted value.
    let tokens: Int
}

/// A month name anchored to the column where that month begins.
struct RotuloDeMes: Equatable {
    let coluna: Int
    let rotulo: String
}

/// A rolling 12-month day grid (EXB-5.10 G4).
///
/// **Why a rolling window and not the calendar year, nor the whole archive.** A year-to-date grid
/// changes width every January, and a whole-history grid shrinks its cells every month the archive
/// grows — both make the chart's own geometry depend on the date it is read. Twelve months back from
/// the end of the axis keeps the cell size fixed for ever.
///
/// **What it is actually for.** Every other chart here reports on the selected window; this one draws
/// a fixed year and paints only the days inside that window, so the reader *sees* how much of a year
/// the panel is really talking about. That is not decoration — it is the coverage statement at the
/// top of the screen, rendered in a form nobody has to read a sentence to feel.
struct CalendarioAnual: Equatable {
    /// The painted cells — covered days inside the grid only, ascending by date.
    let dias: [CalendarioDia]
    /// Every column of the grid, including the ones with no painted day. Pinned as the chart's x
    /// domain so an empty stretch stays an empty stretch instead of collapsing the grid.
    let colunas: [Int]
    /// Row labels in display order, top row first — the weekday symbols rotated to the calendar's own
    /// `firstWeekday`, so a Monday-first locale reads as a Monday-first calendar.
    let linhas: [String]
    /// Month names at the columns where they begin.
    let rotulosDeMes: [RotuloDeMes]
    /// The quantile cuts, computed from the painted days.
    let quantis: CalendarioQuantis
    /// First and last day the grid spans — the subtitle names them.
    let inicio: Date
    let fim: Date
    /// How many days of the grid have no cell at all. The number the chart is making visible.
    var diasSemCelula: Int { Swift.max(0, totalDeDias - dias.count) }
    /// Days between ``inicio`` and ``fim`` inclusive.
    let totalDeDias: Int

    /// Build the grid ending at `fim`, painting whichever of `entradas` fall inside it.
    ///
    /// - Parameters:
    ///   - entradas: the covered day axis — pass `DashboardData.diasCobertos`. Anything uncovered that
    ///     slipped in would be painted as a real zero, which is the one thing this chart must not do.
    ///   - fim: the last day on the grid (the end of the selected window).
    init(entradas: [DashboardDailyEntry], fim: Date, calendar: Calendar = .current) {
        let ultimoDia = calendar.startOfDay(for: fim)
        // Twelve months back, plus one day, so the grid spans a year inclusive of both ends.
        let umAnoAtras = calendar.date(byAdding: .month, value: -12, to: ultimoDia) ?? ultimoDia
        let primeiroDia = calendar.date(byAdding: .day, value: 1, to: umAnoAtras) ?? umAnoAtras

        // Columns are whole weeks, so the grid starts at the beginning of the week containing the
        // first day. Without this the first column would be a partial week whose rows are offset from
        // every other column — the rows would stop meaning "weekday".
        let inicioDaGrade = Self.inicioDaSemana(de: primeiroDia, calendar: calendar)
        let fimDaSemanaFinal = Self.inicioDaSemana(de: ultimoDia, calendar: calendar)
        let totalDeColunas = Swift.max(
            1, (calendar.dateComponents([.day], from: inicioDaGrade, to: fimDaSemanaFinal).day ?? 0) / 7 + 1)

        self.inicio = primeiroDia
        self.fim = ultimoDia
        self.totalDeDias = Swift.max(
            0, (calendar.dateComponents([.day], from: primeiroDia, to: ultimoDia).day ?? 0) + 1)
        self.colunas = Array(0 ..< totalDeColunas)

        // Row order follows the calendar's own first weekday, so the grid is a calendar in every
        // locale rather than a Sunday-first grid with re-labelled rows.
        let simbolos = calendar.shortWeekdaySymbols // index 0 = Sunday, Gregorian
        let deslocamento = calendar.firstWeekday - 1
        self.linhas = (0 ..< 7).map { simbolos[($0 + deslocamento) % 7] }

        var pintados: [CalendarioDia] = []
        pintados.reserveCapacity(entradas.count)
        for entrada in entradas {
            let dia = calendar.startOfDay(for: entrada.date)
            guard dia >= primeiroDia, dia <= ultimoDia else { continue }
            let semana = Self.inicioDaSemana(de: dia, calendar: calendar)
            guard let offset = calendar.dateComponents([.day], from: inicioDaGrade, to: semana).day
            else { continue }
            let coluna = offset / 7
            guard coluna >= 0, coluna < totalDeColunas else { continue }
            let diaDaSemana = calendar.component(.weekday, from: dia) - 1 // 0 = Sunday
            let linha = (diaDaSemana - deslocamento + 7) % 7
            pintados.append(CalendarioDia(data: dia, coluna: coluna, linha: linha, tokens: entrada.tokens))
        }
        self.dias = pintados.sorted { $0.data < $1.data }
        self.quantis = CalendarioQuantis(tokens: pintados.map(\.tokens))

        // A month label sits on the column containing that month's first day, and only when that day
        // is inside the grid — a label for a month the grid does not reach would point at nothing.
        var rotulos: [RotuloDeMes] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: primeiroDia)) ?? primeiroDia
        if cursor < primeiroDia {
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor
        }
        let formatador = Self.mesFormatador
        while cursor <= ultimoDia {
            let semana = Self.inicioDaSemana(de: cursor, calendar: calendar)
            if let offset = calendar.dateComponents([.day], from: inicioDaGrade, to: semana).day {
                let coluna = offset / 7
                if coluna >= 0, coluna < totalDeColunas {
                    rotulos.append(RotuloDeMes(coluna: coluna, rotulo: formatador.string(from: cursor)))
                }
            }
            guard let proximo = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = proximo
        }
        self.rotulosDeMes = rotulos
    }

    /// Start-of-day of the first day of the week containing `date`, in the given calendar.
    static func inicioDaSemana(de date: Date, calendar: Calendar) -> Date {
        let dia = calendar.startOfDay(for: date)
        let diaDaSemana = calendar.component(.weekday, from: dia)
        let recuo = (diaDaSemana - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -recuo, to: dia) ?? dia
    }

    /// Abbreviated month name. A `static let`, created once for the whole view tree — never inside a
    /// `body` or a chart closure (the anti-freeze rule this screen is built on).
    static let mesFormatador: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()
}
