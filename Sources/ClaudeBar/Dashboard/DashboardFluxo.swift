import ClaudeBarCore
import Foundation

/// One band of the composition flow — a project with a colour of its own, or the aggregate.
struct BandaDeProjeto: Equatable, Identifiable {
    var id: String { nome }
    /// The project name, or the injected label of the aggregate band.
    let nome: String
    /// Position in the **archive-wide** ranking, which is what the colour is drawn from.
    ///
    /// Not the position in this array. A band missing from the slice shortens the array; if colour
    /// followed the array, every band after the gap would shift swatch mid-drag and a project would
    /// appear to have become another one.
    let ordemGlobal: Int
    /// `true` on the aggregate band.
    let ehAgregado: Bool
}

/// One `(day, band)` value of the flow. Zero is a value, not an absence: the band exists on a covered
/// day the project did not touch, and drawing the series without it would let the area interpolate
/// straight across a gap it never measured.
struct PontoDoFluxo: Equatable, Identifiable {
    var id: String { "\(dia.timeIntervalSinceReferenceDate)|\(banda)" }
    let dia: Date
    let banda: String
    let tokens: Int
}

/// One row of the hover tooltip: a band's own value on the day and its own change since the previous
/// covered day.
struct LinhaDoFluxo: Equatable, Identifiable {
    var id: String { banda }
    let banda: String
    let tokens: Int
    /// Change against the previous covered day. `nil` on the first day of the axis, where there is no
    /// previous day to compare with — a zero there would assert stability nobody measured.
    let variacao: Int?
}

/// Which project **rose** — not which one is large.
///
/// **Why a common stacked area and not a centred streamgraph.** The wiggle of a streamgraph is chosen
/// to minimize visual movement, which is exactly the movement this chart exists to show; and it moves
/// the baseline of *every* band, so no band can be read against a fixed line. The baseline here is
/// pinned at zero.
///
/// **The distortion that remains, stated rather than hidden.** In any stacked area a band's own base
/// rides on the one below it, so a project that did not change *looks* like it rose when its
/// neighbour grew. That attacks the very question this chart poses, and it cannot be designed away
/// while the chart is stacked — a total the reader can also see is worth the trade. It is mitigated
/// where the reader actually looks for the answer: the tooltip publishes each band's own value and
/// its own day-over-day change (``LinhaDoFluxo``), which are free of the neighbour's movement.
///
/// **The ranking is taken, never recomputed.** `rankedProjects` is ranked over the whole archive
/// precisely so that dragging the range does not re-rank the bands. Recomputing a top-N over the
/// slice would make the same colour a different project halfway through a gesture, and a band would
/// appear to grow when it had merely changed owner.
///
/// Pure value transformation — no I/O, no formatters, safe from inside a `body`.
struct FluxoDeProjetos: Equatable {
    /// The bands in stable rank order, aggregate last.
    let bandas: [BandaDeProjeto]
    /// One point per `(covered day, band)`, ascending by day then by band order.
    let pontos: [PontoDoFluxo]
    /// The day axis actually drawn, ascending.
    let dias: [Date]
    /// How many distinct projects in this slice were folded into the aggregate band.
    let projetosAgregados: Int
    /// The label the aggregate band carries, kept so the view can identify it without string matching
    /// against its own localization table.
    let rotuloDoAgregado: String

    /// `true` when a top-N is being shown. The screen has to say so: a top-8 that does not admit it
    /// is a top-8 is an instrument that lies.
    var truncado: Bool { projetosAgregados > 0 }

    /// `true` when there is something to draw.
    var vaiDesenhar: Bool { dias.count >= 2 && pontos.contains { $0.tokens > 0 } }

    /// The band names in draw order — the `chartForegroundStyleScale` domain.
    var dominio: [String] { bandas.map(\.nome) }

    /// Total tokens on a day, across every band. The tooltip's header, and the figure that has to
    /// agree with the rest of the panel — the aggregate band is a sum, so it does.
    func total(em dia: Date) -> Int {
        pontos.lazy.filter { $0.dia == dia }.reduce(0) { $0 + $1.tokens }
    }

    /// Each band's own value on `dia`, with its own change since the previous covered day.
    ///
    /// Ordered by volume descending, so the rows read in the order the eye scans the stack, and the
    /// change travels beside the value rather than being left for the reader to infer from two
    /// heights whose baselines both moved.
    func linhas(em dia: Date) -> [LinhaDoFluxo] {
        guard let indice = dias.firstIndex(of: dia) else { return [] }
        let anterior = indice > 0 ? dias[indice - 1] : nil
        var doDia: [String: Int] = [:]
        var doAnterior: [String: Int] = [:]
        for ponto in pontos {
            if ponto.dia == dia { doDia[ponto.banda] = ponto.tokens }
            if let anterior, ponto.dia == anterior { doAnterior[ponto.banda] = ponto.tokens }
        }
        return bandas
            .map { banda in
                LinhaDoFluxo(
                    banda: banda.nome,
                    tokens: doDia[banda.nome] ?? 0,
                    variacao: anterior == nil ? nil : (doDia[banda.nome] ?? 0) - (doAnterior[banda.nome] ?? 0))
            }
            .filter { $0.tokens > 0 || ($0.variacao ?? 0) != 0 }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.banda < $1.banda }
    }

    /// Build the flow.
    ///
    /// - Parameters:
    ///   - porDiaProjeto: `DashboardData.byDayProject`, already clipped to the covered days.
    ///   - rankeados: `DashboardData.rankedProjects` — **used as given**.
    ///   - projetosAgregados: `DashboardData.otherProjectCount`.
    ///   - rotuloDoAgregado: the localized name of the aggregate band, injected so this type carries
    ///     no localization of its own.
    ///   - eixo: the covered day axis — pass `DashboardData.diasCobertos.map(\.date)`. Empty falls
    ///     back to the days the rows themselves carry.
    init(
        porDiaProjeto: [DayProjectEntry],
        rankeados: [String],
        projetosAgregados: Int,
        rotuloDoAgregado: String,
        eixo: [Date] = [])
    {
        self.projetosAgregados = projetosAgregados
        self.rotuloDoAgregado = rotuloDoAgregado

        // The axis is the **covered** days, not the days that happen to carry a row. A covered day on
        // which nothing was run is a real zero, and leaving it off the axis would let the area
        // interpolate straight over it — drawing a smooth ramp across a day that measured nothing.
        // Uncovered days never reach here: `DashboardData.build` clips the rows, and a caller passing
        // its own axis passes `diasCobertos`.
        let dosDados = Set(porDiaProjeto.map(\.day))
        let dias = eixo.isEmpty ? Array(dosDados).sorted() : eixo.sorted()
        self.dias = dias

        let rankeadosSet = Set(rankeados)
        // A row whose project is not in the ranking lands on the aggregate rather than being dropped.
        // The fold should never emit one — everything outside the ranking is already keyed to the
        // aggregate — so this is a guard, and it is a *summing* guard on purpose: dropping the row
        // would make the day's bands quietly add up to less than the day's real total, which is the
        // one property that makes a stacked chart readable at all.
        var valores: [String: [Date: Int]] = [:]
        var agregado: [Date: Int] = [:]
        var comVolume: Set<String> = []
        var agregadoTemVolume = false
        for linha in porDiaProjeto {
            if linha.isOthers || !rankeadosSet.contains(linha.project) {
                agregado[linha.day, default: 0] += linha.totalTokens
                if linha.totalTokens > 0 { agregadoTemVolume = true }
            } else {
                valores[linha.project, default: [:]][linha.day, default: 0] += linha.totalTokens
                if linha.totalTokens > 0 { comVolume.insert(linha.project) }
            }
        }

        // Filtering to the bands that actually carry volume shortens the legend; it does **not**
        // re-order anything, and the colour index below is the position in `rankeados`, not in the
        // filtered array.
        var bandas: [BandaDeProjeto] = []
        for (ordem, projeto) in rankeados.enumerated() where comVolume.contains(projeto) {
            bandas.append(BandaDeProjeto(nome: projeto, ordemGlobal: ordem, ehAgregado: false))
        }
        if agregadoTemVolume {
            bandas.append(BandaDeProjeto(
                nome: rotuloDoAgregado, ordemGlobal: rankeados.count, ehAgregado: true))
        }
        self.bandas = bandas

        var pontos: [PontoDoFluxo] = []
        pontos.reserveCapacity(dias.count * Swift.max(1, bandas.count))
        for dia in dias {
            for banda in bandas {
                let tokens = banda.ehAgregado
                    ? (agregado[dia] ?? 0)
                    : (valores[banda.nome]?[dia] ?? 0)
                pontos.append(PontoDoFluxo(dia: dia, banda: banda.nome, tokens: tokens))
            }
        }
        self.pontos = pontos
    }

    /// Convenience over the view model — one construction path for the screen and the suite.
    init(data: DashboardData, rotuloDoAgregado: String) {
        self.init(
            porDiaProjeto: data.byDayProject,
            rankeados: data.rankedProjects,
            projetosAgregados: data.otherProjectCount,
            rotuloDoAgregado: rotuloDoAgregado,
            eixo: data.diasCobertos.map(\.date))
    }
}
