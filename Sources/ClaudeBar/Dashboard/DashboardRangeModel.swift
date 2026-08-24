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

    /// The stretch on screen.
    private(set) var span: DashboardSpan
    /// The shortcut lit in the toolbar, or `nil` when the range was dragged.
    private(set) var atalho: DashboardPeriod?
    private(set) var dados: DashboardData?
    private(set) var historia: DashboardHistoria?
    /// `true` while a slice or a load is in flight with content already on screen.
    private(set) var isRefreshing = false

    private var tarefa: Task<Void, Never>?

    init(
        source: DashboardSource,
        atalhoInicial: DashboardPeriod = .thirtyDays,
        agora: @escaping @Sendable () -> Date = { Date() })
    {
        self.source = source
        self.agora = agora
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

    /// A shortcut is a *value* of the same range control, not another mode.
    @discardableResult
    func aplicarAtalho(_ atalho: DashboardPeriod) -> Task<Void, Never>? {
        aplicar(
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
