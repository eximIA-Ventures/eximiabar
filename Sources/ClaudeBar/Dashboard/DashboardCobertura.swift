import Foundation

/// What the source actually covers, and the averages that name their own divisor.
///
/// **Why these live here and not in `DashboardData.build`.** Every value below is a projection of
/// three fields the build already produced — `dailyCosts` (with its per-day `coberto` flag),
/// `diasComDado` and `spanDays`. Storing them would mean a second copy of the same fact that a future
/// change could leave behind; deriving them keeps one source and makes the derivation itself
/// assertable.
///
/// **Why the names mirror `PainelData`.** `painel.html` publishes exactly these figures
/// (`PainelData.tokensPorDiaDaJanela`, `PainelCobertura.diasSemDado`, …), and the app's own screen now
/// publishes them too. Two independent derivations of the same number is how a panel and the screen
/// that exported it end up disagreeing — with nobody able to say which one is lying. So the adapter
/// that fills `PainelData` reads from here rather than re-dividing.
///
/// **One definition of "covered", not two.** `coberto` is the flag `DashboardData.build` set from the
/// coverage anchor (`coverageStart`), and it is the same flag the charts filter on when they refuse to
/// draw a day. So the block at the top of the screen announces precisely the span the charts below it
/// drew — a coverage statement that disagreed with the chart under it would be worse than none.
extension DashboardData {
    // MARK: - Coverage

    /// The first day the archive vouches for, `nil` only when the axis is empty.
    ///
    /// `coberto` is a contiguous suffix of the day axis (the flag is `day >= coberturaInicio`), so the
    /// first covered entry is the anchor itself.
    var primeiroDiaComDado: Date? { dailyCosts.first(where: \.coberto)?.date }

    /// The last day the archive vouches for — normally today, the end of the requested span.
    var ultimoDiaComDado: Date? { dailyCosts.last(where: \.coberto)?.date }

    /// Days of the **requested** window the source never saw.
    ///
    /// These are the days the charts leave blank. They are not zeros: a zero would assert that nothing
    /// was consumed, which is the one thing the app cannot know about a day it never watched.
    var diasSemDado: Int { Swift.max(0, spanDays - diasComDado) }

    /// Whether the source reaches as far back as the window asked for.
    var cobreJanelaInteira: Bool { diasComDado >= spanDays }

    // MARK: - The two averages, one numerator

    /// Token average over the days the source covers — divides by ``diasComDado``.
    ///
    /// **This is deliberately not `averageDailyTokens`,** and the difference is the reason this
    /// property exists. `averageDailyTokens` counts `input + output` only, because it is the baseline
    /// the today-vs-average badge compares `todayTokens` against, and that badge must compare like with
    /// like. Every *volume* figure on the screen — the chart headers, the section total, the panel —
    /// counts all four token kinds through ``DashboardData/totalTokens``.
    ///
    /// Showing `averageDailyTokens` on a card directly beneath a total of all four kinds would put two
    /// numbers side by side that cannot be reconciled by any arithmetic the reader can perform:
    /// `média × dias ≠ total`, with nothing on screen explaining why. So the pair of averages below is
    /// built from the section's own total, and `averageDailyTokens` stays where it belongs — inside the
    /// badge, against the measure it was defined for.
    var tokensPorDiaComUso: Double {
        diasComDado > 0 ? Double(totalTokens) / Double(diasComDado) : 0
    }

    /// Token average over the **requested window** — divides by `spanDays`, same numerator as
    /// ``tokensPorDiaComUso``.
    ///
    /// Published beside it rather than instead of it. Choosing one and hiding the divisor is exactly
    /// the defect that let a ~40% error survive on this screen: both are correct answers to different
    /// questions, and the only way to tell them apart is to write the denominator on the label.
    var tokensPorDiaDaJanela: Double {
        spanDays > 0 ? Double(totalTokens) / Double(spanDays) : 0
    }

    /// Cost average over the days the source covers — an alias for ``averageDailyCost``, which already
    /// divides `totalCost` by `diasComDado`.
    ///
    /// An alias and not a second division on purpose: the cost side has only one measure, so there is
    /// nothing to reconcile and no reason to compute it twice. The name exists so the cost pair reads
    /// symmetrically with the token pair on screen and in the panel adapter.
    var custoPorDiaComUso: Double { averageDailyCost }

    /// Cost average over the **requested window** — divides by `spanDays`.
    var custoPorDiaDaJanela: Double {
        spanDays > 0 ? totalCost / Double(spanDays) : 0
    }
}
