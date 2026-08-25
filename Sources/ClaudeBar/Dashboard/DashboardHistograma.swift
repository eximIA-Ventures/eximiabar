import ClaudeBarCore
import Foundation

/// One bar of the session-size histogram: a fixed token band and how many sessions fell in it.
struct FaixaDeSessoes: Equatable, Identifiable {
    /// The bucket index, `0 ..< UsageAnalytics.sessionTokenBucketCount` — doubles as identity.
    var id: Int { indice }
    let indice: Int
    /// Inclusive lower edge, in tokens.
    let minimo: Int
    /// Exclusive upper edge, in tokens.
    let maximo: Int
    let sessoes: Int
}

/// One of the ten dearest sessions, placed on the bar it belongs to.
struct MarcaDeSessao: Equatable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let projeto: String
    /// The model that carried most of the session's cost — half of what makes a dot actionable.
    let modeloDominante: String
    let tokens: Int
    let custoUSD: Double
    /// The bucket this session falls in, from ``UsageAnalytics/sessionTokenBucketIndex(forTokens:)``
    /// — the fold's own binning, never a second one computed at the drawing end.
    let faixa: Int
    /// 1-based position among the marks sharing this bucket. Drives the vertical offset that keeps
    /// two dear sessions of similar size from landing on the same pixel.
    let empilhamento: Int
}

/// Where the spend lives: in a handful of monstrous sessions, or in the habit of every day.
///
/// **The question the top-ten cannot answer.** Ten rows are ~5 % of this archive's 208 sessions, and
/// the same ten names appear in two worlds that call for opposite actions: "ten monsters and nothing
/// else" (attack the sessions) and "ten monsters plus two hundred ordinary ones" (the habit *is* the
/// spend). A ranked list is mathematically incapable of distinguishing them, because the evidence for
/// the distinction is precisely the sessions it drops.
///
/// **Why the axis is not fitted to the data.** The edges come from
/// ``UsageAnalytics/sessionTokenBucketEdges`` and never move: same bar, same meaning, at every drag
/// position, and two periods stay comparable. Empty buckets — inside *or* at the ends — are kept for
/// the same reason. Trimming the tails would make the axis a function of the slice, which is the same
/// defect as a percentage whose denominator is invisible, drawn instead of written.
///
/// Pure value transformation: no I/O, no formatters, safe from inside a `body`.
struct HistogramaDeSessoes: Equatable {
    /// All 20 bars, in bucket order — never trimmed, never compacted.
    let faixas: [FaixaDeSessoes]
    /// The ten dearest sessions, each on its own bucket.
    let marcas: [MarcaDeSessao]
    /// Median session size in tokens, computed by the fold from the exact totals.
    let mediana: Int
    /// The bucket the median falls in, so the rule line can be drawn on the same binning as the bars.
    /// `nil` when there is no session to take a median of.
    let faixaDaMediana: Int?
    /// Sample size — the true number of sessions in the window.
    ///
    /// **The true one**, which is not the same as `nomes.count`. A cap is a decision about payload,
    /// never a claim about the distribution: the bars count every session the fold saw, so the *shape*
    /// does not change with how much the caller asked to carry.
    let totalDeSessoes: Int
    /// Every session the caller carried, dearest first — the identity behind the bars.
    ///
    /// The histogram gives the **shape** at a fixed 20 integers however large the archive grows; this
    /// gives the **name**, which is what turns "there is an outlier in this band" into "it was
    /// `eximia-academy-v2`, on opus". Kept alongside rather than instead of the buckets, and read
    /// through ``nomes(naFaixa:)`` so a consumer never has to bin anything itself.
    let nomes: [SessionUsageEntry]
    /// `true` when ``nomes`` holds fewer rows than ``totalDeSessoes`` — so a hover that lists names can
    /// say that it is showing a subset of the bar it is standing on, instead of implying the bar is
    /// made of exactly what it lists.
    var nomesIncompletos: Bool { nomes.count < totalDeSessoes }
    /// Share of the window's session volume carried by the ten dearest, `0…1`.
    ///
    /// **The number that separates the two worlds**, and the reason the histogram earns its space:
    /// 0,62 says the monsters *are* the spend, 0,13 says the habit is. `nil` when the session list was
    /// cut — a share computed over a truncated numerator and an unknown denominator would be a
    /// plausible fabrication, which is worse than an absent number.
    let concentracaoDoTopo: Double?

    /// How many sessions the ten dearest represent, for the sentence that states the share.
    var tamanhoDoTopo: Int { marcas.count }

    /// `true` when there is a distribution to look at.
    ///
    /// One session draws a single bar and a rule line through it — an ornament implying a comparison
    /// it cannot make. Below this bar the card says the count in words instead.
    var vaiDesenhar: Bool { totalDeSessoes >= 2 && faixas.contains { $0.sessoes > 0 } }

    /// The tallest bar — the y domain, so a window with one busy bucket does not draw off the top.
    var maiorFaixa: Int { faixas.map(\.sessoes).max() ?? 0 }

    /// The sessions that fall in one band, largest first.
    ///
    /// Binned by ``UsageAnalytics/sessionTokenBucketIndex(forTokens:)`` — the same call that placed
    /// the marks and that the fold counted the bars with. Three uses, one implementation: a hover that
    /// listed a session the bar underneath does not count would be a tooltip contradicting its own
    /// chart, and nothing about it would look wrong.
    func nomes(naFaixa indice: Int) -> [SessionUsageEntry] {
        nomes
            .filter { UsageAnalytics.sessionTokenBucketIndex(forTokens: $0.totalTokens) == indice }
            .sorted { $0.totalTokens != $1.totalTokens
                ? $0.totalTokens > $1.totalTokens
                : $0.sessionId < $1.sessionId }
    }

    /// Build from the fold's own output.
    ///
    /// - Parameters:
    ///   - buckets: `UsageAnalytics.sessionTokenBuckets`. A shorter array is padded and a longer one
    ///     is cut, so a stale envelope cannot make the bars and the edges disagree in length.
    ///   - mediana: `UsageAnalytics.medianSessionTokens` — taken, never re-derived. A median read off
    ///     buckets √10 apart can be out by 3×.
    ///   - total: `UsageAnalytics.totalSessions`, the true sample size behind the bars.
    ///   - topo: `UsageAnalytics.topSessions` — the head of the same list the buckets counted.
    ///   - sessoes: every session in the window, for the concentration share. Pass `nil` (or a cut
    ///     list, flagged by `truncado`) to suppress the share rather than fabricate it.
    ///   - truncado: `UsageAnalytics.sessionsTruncated`.
    init(
        buckets: [Int],
        mediana: Int,
        total: Int,
        topo: [SessionUsageEntry],
        sessoes: [SessionUsageEntry] = [],
        truncado: Bool = false)
    {
        let contagem = UsageAnalytics.sessionTokenBucketCount
        let edges = UsageAnalytics.sessionTokenBucketEdges
        self.faixas = (0 ..< contagem).map { indice in
            FaixaDeSessoes(
                indice: indice,
                minimo: edges[indice],
                maximo: edges[indice + 1],
                sessoes: indice < buckets.count ? buckets[indice] : 0)
        }

        // Marks are placed by the fold's own binning function. Re-deriving `floor(2·log₁₀ n)` here
        // would work today and drift the first time either side changed — the mark and the bar under
        // it would then be computed by two different rules, and the picture would still look fine.
        var ocupacao: [Int: Int] = [:]
        self.marcas = topo.map { sessao in
            let faixa = UsageAnalytics.sessionTokenBucketIndex(forTokens: sessao.totalTokens)
            let posicao = (ocupacao[faixa] ?? 0) + 1
            ocupacao[faixa] = posicao
            return MarcaDeSessao(
                sessionId: sessao.sessionId,
                projeto: sessao.project,
                modeloDominante: sessao.dominantModel,
                tokens: sessao.totalTokens,
                custoUSD: sessao.costUSD,
                faixa: faixa,
                empilhamento: posicao)
        }

        self.nomes = sessoes
        self.mediana = mediana
        self.faixaDaMediana = mediana > 0
            ? UsageAnalytics.sessionTokenBucketIndex(forTokens: mediana)
            : nil
        self.totalDeSessoes = total

        // The share is only computable when the denominator is the real one. `sessions.count < total`
        // means rows were dropped, and the sum of what remains is not the window's volume.
        let volumeTotal = sessoes.reduce(0) { $0 + $1.totalTokens }
        if truncado || sessoes.isEmpty || sessoes.count < total || volumeTotal <= 0 {
            self.concentracaoDoTopo = nil
        } else {
            let volumeDoTopo = topo.reduce(0) { $0 + $1.totalTokens }
            self.concentracaoDoTopo = Double(volumeDoTopo) / Double(volumeTotal)
        }
    }

    /// Convenience over the view model, so the screen and the tests build it the same way.
    init(data: DashboardData) {
        self.init(
            buckets: data.sessionTokenBuckets,
            mediana: data.medianSessionTokens,
            total: data.totalSessions,
            topo: data.topSessions,
            sessoes: data.sessions,
            truncado: data.sessionsTruncated)
    }
}
