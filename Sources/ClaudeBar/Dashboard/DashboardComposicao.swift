import Foundation

/// Which question the per-day model chart is answering (EXB-5.10 G2).
///
/// The two readings are not interchangeable and neither replaces the other: **absolute** answers "how
/// much did I use", **proportion** answers "what did I use it on". A day of peak volume makes the
/// first chart legible and the second one irrelevant, and a quiet week does the reverse — so this is
/// a toggle on one chart rather than two charts stacked, which on a menu-bar window would only trade
/// an illegible panel for a longer illegible panel.
enum ModoComposicao: String, CaseIterable, Identifiable {
    case absoluto
    case proporcao

    var id: String { rawValue }

    var label: String {
        switch self {
        case .absoluto: return L("dashboard.models_by_day.mode.absolute")
        case .proporcao: return L("dashboard.models_by_day.mode.share")
        }
    }
}

/// One `(day, model)` slice of a day's mix, as a fraction of that day's own total.
struct FracaoModeloDia: Equatable, Identifiable {
    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(modelName)" }
    let date: Date
    let modelName: String
    /// `0…1`. All the fractions of one day sum to 1 by construction.
    let fracao: Double
}

/// The per-day mix, normalized to 100 % (EXB-5.10 G2).
///
/// **What normalizing buys.** Daily volume on this screen swings by an order of magnitude, and a
/// stacked absolute chart is scaled by its tallest day — so on a normal day the mix is squeezed into a
/// sliver at the bottom of the plot, invisible precisely where the Senhor spends most of his days.
/// Dividing each day by its own total separates "I used more" from "I used it differently"; only the
/// second is a change in behaviour, and only the second is worth acting on.
///
/// Pure, deterministic, allocation-bounded — safe inside a chart `body`.
enum ComposicaoDiaria {
    /// Normalize per-`(day, model)` volumes into per-day fractions.
    ///
    /// Two days are deliberately absent from the output rather than drawn as something:
    ///
    /// - **A day the source never watched** (`coberto == false`, so its date is not in `datasCobertas`)
    ///   — the same rule every other chart here follows. An uncovered day has no mix, and inventing a
    ///   flat one would be the confident-zero defect wearing a percentage sign.
    /// - **A day whose total is zero** — there is no denominator, and the alternative is a division
    ///   that yields `NaN` or `inf` and hands Swift Charts a mark it silently drops or draws at the
    ///   top of the plot. Absent is the honest shape for "nothing to divide".
    ///
    /// - Parameters:
    ///   - entradas: per-`(day, model)` token volume, in any order.
    ///   - datasCobertas: the day axis the charts are allowed to draw — `DashboardData.datasCobertas`.
    /// - Returns: fractions ascending by date, model name as tiebreak (the order `byDayByModel` uses).
    static func fracoes(
        entradas: [DailyModelEntry],
        datasCobertas: Set<Date>) -> [FracaoModeloDia]
    {
        // The coverage clip happens ONCE, before anything is summed, and both passes below read the
        // clipped list. Written as two separate `where` clauses it worked and was untestable: removing
        // either one left the other silently covering for it, so a mutation of the rule produced no
        // failure at all and the test that claimed to pin it was passing for the wrong reason.
        let cobertas = entradas.filter { datasCobertas.contains($0.date) }

        var totalPorDia: [Date: Int] = [:]
        for entrada in cobertas {
            totalPorDia[entrada.date, default: 0] += entrada.tokens
        }

        var saida: [FracaoModeloDia] = []
        saida.reserveCapacity(cobertas.count)
        for entrada in cobertas {
            guard let total = totalPorDia[entrada.date], total > 0 else { continue }
            saida.append(FracaoModeloDia(
                date: entrada.date,
                modelName: entrada.modelName,
                fracao: Double(entrada.tokens) / Double(total)))
        }
        return saida.sorted { $0.date != $1.date ? $0.date < $1.date : $0.modelName < $1.modelName }
    }
}
