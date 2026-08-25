import ClaudeBarCore
import Foundation
import Observation

/// The two doors the dashboard uses to get numbers, named apart so the difference between them is
/// enforceable rather than remembered (EXB-5.8 §8).
///
/// `carregarHistoria` is the expensive one: it walks the directory, stats every candidate log and
/// re-reads whatever changed. `fatiar` is pure arithmetic over the archive already in memory.
/// Separating them is what lets a test *prove* that dragging a range never reaches the disk —
/// with one combined method, "did this do I/O?" would be a question about an implementation detail
/// instead of a fact about which method was called.
protocol DashboardSource: Sendable {
    /// One scan of everything, refreshing the archive from disk. Returns the source fingerprint (for
    /// cache invalidation) and the first day the archive can vouch for.
    func carregarHistoria(now: Date) async -> DashboardHistoria
    /// A slice of the archive already in memory. **Must not touch the filesystem.**
    func fatiar(_ intervalo: ClosedRange<Date>, now: Date) async -> UsageAnalytics
}

/// What one full load yields: the fingerprint that invalidates the cache, and where the data begins.
struct DashboardHistoria: Sendable {
    let fingerprint: String
    /// First day the archive covers, or `nil` when there is nothing at all. Drives `.tudo` and stops
    /// the dashboard from drawing anything before the data actually begins.
    let inicio: Date?
}

/// `CostScanner` behind the two doors.
struct CostScannerSource: DashboardSource {
    let scanner: CostScanner

    /// A window wide enough to mean "everything". The archive keeps every day it ever saw, so the
    /// only job of this number is to not clip; it is not a retention policy.
    private static let tudo = 100_000

    func carregarHistoria(now: Date) async -> DashboardHistoria {
        let scan = await scanner.scanAnalyticsResult(windowDays: Self.tudo, now: now)
        return DashboardHistoria(
            fingerprint: scan.fingerprint,
            inicio: scan.analytics.coveredDays.min())
    }

    func fatiar(_ intervalo: ClosedRange<Date>, now: Date) async -> UsageAnalytics {
        await scanner.analytics(in: intervalo, now: now)
    }
}

/// Owns what the dashboard is looking at (EXB-5.8 §8).
///
/// The architecture this replaces made the period an **input to the scan**: choosing 7d re-scanned
/// for 7 days. That is why a draggable range could not exist — a gesture that emits dozens of events
/// per second cannot pay a directory walk per event. Here the history is loaded once and the range is
/// a slice: `carregarUmaVez()` is the only method that reads disk, and `aplicar(...)` is arithmetic.
///
/// The shortcuts are not modes. `aplicarAtalho(.seteDias)` resolves to a range and goes through the
/// same `aplicar` the drag uses, so a button and a drag cannot drift into meaning different things.
@MainActor
@Observable
final class DashboardRangeModel {
    private let source: DashboardSource
    private let agora: @Sendable () -> Date
    /// How still the gesture has to be before the fold runs (see ``aplicarArrasto(_:)``).
    private let assentamento: Duration

    /// The stretch on screen.
    private(set) var span: DashboardSpan
    /// The shortcut lit in the toolbar, or `nil` when the range was dragged.
    private(set) var atalho: DashboardPeriod?
    private(set) var dados: DashboardData?
    private(set) var historia: DashboardHistoria?
    /// `true` while a slice or a load is in flight with content already on screen.
    private(set) var isRefreshing = false

    private var tarefa: Task<Void, Never>?
    /// The fold waiting for the gesture to settle. At most one exists; a new emission cancels it.
    private var arrastoPendente: Task<Void, Never>?

    /// The default settling window.
    ///
    /// 120 ms is under the ~150 ms at which a delay stops reading as "instant" to a person moving a
    /// pointer, and long enough that a continuous gesture emitting dozens of events per second
    /// collapses to one fold. It is a constant rather than a tuning knob because a value chosen per
    /// call site is a value that will differ between the drag and whatever comes after it.
    static let assentamentoPadrao: Duration = .milliseconds(120)

    init(
        source: DashboardSource,
        atalhoInicial: DashboardPeriod = .thirtyDays,
        agora: @escaping @Sendable () -> Date = { Date() },
        assentamento: Duration = DashboardRangeModel.assentamentoPadrao)
    {
        self.source = source
        self.agora = agora
        self.assentamento = assentamento
        self.atalho = atalhoInicial
        self.span = atalhoInicial.span(inicioDoHistorico: nil, now: agora())
    }

    /// Read the disk. **The only method here that does.** Everything after it is arithmetic.
    func carregarUmaVez() async {
        let now = agora()
        let historia = await source.carregarHistoria(now: now)
        self.historia = historia
        // Re-resolve the shortcut now that the history's start is known — `.tudo` has no meaning
        // until then, and no shortcut may reach back past the first day of real data.
        if let atalho {
            span = atalho.span(inicioDoHistorico: historia.inicio, now: now)
        }
        await recomputar()
    }

    /// Point the dashboard at `intervalo`. Slice only — never a scan (the §8 invariant).
    ///
    /// Returns the fold so a caller can await it. The alternative — polling `isRefreshing` — looked
    /// fine and was not: it let a test read the *previous* range's data and call it the new one, and
    /// only the absolute assertions caught it. A handle on the work is checkable; a spin loop is a
    /// guess about timing.
    @discardableResult
    func aplicar(_ intervalo: ClosedRange<Date>, atalho: DashboardPeriod? = nil) -> Task<Void, Never>? {
        let novo = DashboardSpan(inicio: intervalo.lowerBound, fim: intervalo.upperBound)
        // A drag settling on the range already displayed is not a reason to re-fold.
        guard novo != span || self.atalho != atalho else { return nil }
        span = novo
        self.atalho = atalho
        tarefa?.cancel()
        if dados != nil { isRefreshing = true }
        let t = Task { [weak self] in
            guard let self else { return }
            await self.recomputar()
        }
        tarefa = t
        return t
    }

    /// Point the dashboard at `intervalo` **once the gesture stops moving** (EXB-6.1).
    ///
    /// **Why this door exists beside `aplicar`.** `chartXSelection(range:)` emits continuously while
    /// the pointer is down — dozens of events a second — and every emission that reached `aplicar`
    /// paid a full `analytics(in:)`, which re-folds *every* bucket: `byProject`, `heatmap`,
    /// `topSessions` and now the per-`(day, project)` and session dimensions as well. Measured by the
    /// scanner's own doc: 3,1 ms over this machine's archive and 22 ms over a synthesised two-year
    /// one. Folding per frame is how the freeze this screen already killed (22,26 s → 0,067 s) comes
    /// back through a different door.
    ///
    /// The rule is one line: **fold on settle, not per emission.** Each call cancels the fold that was
    /// waiting and starts a new wait, so a burst of N emissions costs one fold rather than N. The
    /// gesture stays free because nothing on this path touches the disk either way — the §8 invariant
    /// is untouched, this is about the arithmetic, not the I/O.
    ///
    /// Returns the pending work so a caller — or a test — can await the settle instead of guessing at
    /// a timing. A cancelled wait returns immediately, so awaiting an emission that was superseded is
    /// cheap and correct rather than a hang.
    @discardableResult
    func aplicarArrasto(_ intervalo: ClosedRange<Date>) -> Task<Void, Never> {
        arrastoPendente?.cancel()
        let t = Task { [weak self] in
            guard let self else { return }
            // `Task.sleep` throws on cancellation; `try?` turns that into the same early return the
            // explicit check below makes for a cancellation that lands after the wait.
            try? await Task.sleep(for: self.assentamento)
            guard !Task.isCancelled else { return }
            await self.aplicar(intervalo)?.value
        }
        arrastoPendente = t
        return t
    }

    /// A shortcut is a *value* of the same range control, not another mode.
    @discardableResult
    func aplicarAtalho(_ atalho: DashboardPeriod) -> Task<Void, Never>? {
        // A button is not a gesture: it emits once, and making it wait 120 ms would be latency bought
        // for nothing. It does cancel a drag still settling, so the last thing the Senhor touched is
        // the thing that ends up on screen.
        arrastoPendente?.cancel()
        return aplicar(
            atalho.span(inicioDoHistorico: historia?.inicio, now: agora()).intervalo,
            atalho: atalho)
    }

    private func recomputar() async {
        let now = agora()
        let span = self.span
        let analytics = await source.fatiar(span.intervalo, now: now)
        guard !Task.isCancelled, span == self.span else { return }
        dados = DashboardData.build(from: analytics, span: span, atalho: atalho, now: now)
        isRefreshing = false
    }
}
