import ClaudeBarCore
import Foundation

/// One point of the project concentration curve: a rank on the x axis and the cumulative share of
/// token volume that rank and everything above it account for.
struct ParetoPonto: Equatable, Identifiable {
    /// 1-based position in the descending order — doubles as the identity, one point per rank.
    var id: Int { rank }
    let rank: Int
    /// The project sitting at this rank, carried so the tooltip can name it.
    let projeto: String
    /// Tokens for this project alone.
    let tokens: Int
    /// Cumulative share of the window's project tokens, `0…1`, non-decreasing in `rank`.
    let acumulado: Double
}

/// The concentration curve of project token volume, and the one number it exists to produce.
///
/// **Why a curve and not the table that is already on screen.** The project table is ordered by
/// volume, so the concentration is *in* it — but reading it out of 101 rows means summing 101 numbers
/// by eye. The curve answers "how many projects do I actually have to care about?" in one glance, and
/// it answers it in **both** directions: a crossing at rank 7 says attention has an address; a
/// crossing at rank 45 says there is no lever at the project level at all. The table says neither.
///
/// Pure value transformation — no I/O, no formatters, safe from any thread and from inside a `body`
/// (the anti-freeze invariant this screen is built on).
struct ParetoCurva: Equatable {
    /// One point per project, ranked by token volume descending.
    let pontos: [ParetoPonto]
    /// Total project tokens over the window — the denominator every share divides by.
    let total: Int
    /// The share the curve is being read against (0,8 for the conventional Pareto reading).
    let limiar: Double
    /// The smallest rank whose cumulative share reaches ``limiar``.
    ///
    /// `nil` only when there is nothing to concentrate: no projects, or no tokens across them. A
    /// threshold that cannot be crossed produces no number rather than a misleading one.
    let rankNoLimiar: Int?

    /// How many projects there are in total — the denominator of the headline sentence
    /// ("7 de 101 projetos"). Without it, "7 projects" is not yet actionable.
    var quantidadeDeProjetos: Int { pontos.count }

    /// Build the curve from the per-project totals.
    ///
    /// The input is re-sorted here rather than trusted. `DashboardData.build` already hands over
    /// `byProject` in descending token order, but a cumulative curve over an unsorted input is not a
    /// weaker curve — it is a different, meaningless one, and it would still draw. Sorting is
    /// idempotent on the input we actually get, and the tiebreak (project name) matches the one the
    /// builder uses, so the ordering here and there cannot drift.
    init(projetos: [ProjectUsageEntry], limiar: Double = 0.8) {
        let ordenados = projetos.sorted {
            $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.project < $1.project
        }
        let total = ordenados.reduce(0) { $0 + $1.totalTokens }
        self.total = total
        self.limiar = limiar

        guard total > 0 else {
            self.pontos = []
            self.rankNoLimiar = nil
            return
        }

        var acumulado = 0
        var pontos: [ParetoPonto] = []
        pontos.reserveCapacity(ordenados.count)
        var cruzamento: Int?
        for (indice, projeto) in ordenados.enumerated() {
            acumulado += projeto.totalTokens
            let fracao = Double(acumulado) / Double(total)
            let rank = indice + 1
            pontos.append(ParetoPonto(
                rank: rank, projeto: projeto.project, tokens: projeto.totalTokens, acumulado: fracao))
            // The first rank to reach the threshold, kept — later ranks also clear it, and the answer
            // to "how many do I need?" is the smallest such count, not the last one.
            if cruzamento == nil, fracao >= limiar { cruzamento = rank }
        }
        self.pontos = pontos
        // The final point is 1.0 by construction, so on any non-empty, non-zero input the threshold
        // is always crossed; the optional exists for the empty case above, not for this loop.
        self.rankNoLimiar = cruzamento
    }
}
