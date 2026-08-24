import Foundation

/// The slice of time on screen (EXB-5.8 §8).
///
/// This is the dashboard's unit of "what am I looking at", and it is a **range of days**, not a
/// window width. That distinction is the whole of §8: a width can only ever mean "the last N days",
/// so it cannot express a stretch the Senhor drags out of the middle of his own history.
///
/// Both bounds are start-of-day in the local time zone and both are inclusive — the same convention
/// `CostScanner.analytics(in:)` uses, so the two never disagree about which days a range covers.
struct DashboardSpan: Equatable, Hashable, Sendable {
    /// First day on screen, inclusive.
    let inicio: Date
    /// Last day on screen, inclusive (normally today).
    let fim: Date

    init(inicio: Date, fim: Date, calendar: Calendar = .current) {
        let a = calendar.startOfDay(for: inicio)
        let b = calendar.startOfDay(for: fim)
        self.inicio = Swift.min(a, b)
        self.fim = Swift.max(a, b)
    }

    /// Number of days covered, inclusive of both ends. Never below 1.
    func dias(calendar: Calendar = .current) -> Int {
        Swift.max(1, (calendar.dateComponents([.day], from: inicio, to: fim).day ?? 0) + 1)
    }

    /// The range to hand to `CostScanner.analytics(in:)`.
    var intervalo: ClosedRange<Date> { self.inicio...self.fim }

    /// The trailing `days`-day span ending today — how a shortcut becomes a concrete range.
    static func ultimos(_ days: Int, now: Date, calendar: Calendar = .current) -> DashboardSpan {
        let hoje = calendar.startOfDay(for: now)
        let inicio = calendar.date(byAdding: .day, value: -(Swift.max(1, days) - 1), to: hoje) ?? hoje
        return DashboardSpan(inicio: inicio, fim: hoje, calendar: calendar)
    }
}

/// A shortcut on the dashboard toolbar (EXB-5.8 §8).
///
/// These stopped being *modes* — the owner's decision. A shortcut no longer selects a different
/// scan; it writes a value into the same `DashboardSpan` the drag writes into. That is what keeps
/// the button and the drag coherent, instead of two controls asking two different questions.
///
/// `.ninetyDays` was retired for `.tudo`: with the history loaded once, an arbitrary ceiling of 90
/// days had nothing left to justify it, and on this machine it was drawing 35 days of blank anyway.
enum DashboardPeriod: String, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    /// Everything the archive can vouch for. Its day count is not fixed — it grows with the history,
    /// which is exactly why it could not exist while the period was an input to the scan.
    case tudo

    var id: String { self.rawValue }

    /// The concrete range this shortcut resolves to.
    ///
    /// `inicioDoHistorico` is the first day the archive covers. `.tudo` starts there and nowhere
    /// earlier: **nothing is drawn before the data actually begins** (the owner's decision), so the
    /// widest button cannot manufacture a stretch nobody ever observed.
    func span(inicioDoHistorico: Date?, now: Date, calendar: Calendar = .current) -> DashboardSpan {
        let hoje = calendar.startOfDay(for: now)
        switch self {
        case .sevenDays: return .ultimos(7, now: now, calendar: calendar)
        case .thirtyDays: return .ultimos(30, now: now, calendar: calendar)
        case .tudo:
            guard let inicio = inicioDoHistorico.map({ calendar.startOfDay(for: $0) }), inicio <= hoje
            else { return .ultimos(30, now: now, calendar: calendar) }
            return DashboardSpan(inicio: inicio, fim: hoje, calendar: calendar)
        }
    }

    /// Localized segmented-control label (`"7d"` / `"30d"` / `"Tudo"`).
    var label: String {
        switch self {
        case .sevenDays: return L("dashboard.period.7d")
        case .thirtyDays: return L("dashboard.period.30d")
        case .tudo: return L("dashboard.period.all")
        }
    }

    /// Compact tag used in the CSV export filename suggestion.
    var fileTag: String {
        switch self {
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        case .tudo: return "tudo"
        }
    }
}
