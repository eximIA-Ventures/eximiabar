import ClaudeBarCore
import Foundation
import os

/// One calendar day's roll-up for the dashboard charts (EXB-2.3 / EXB-3.2).
///
/// `tokens` is the combined input + output count for the day; the cost-per-day chart plots `costUSD`,
/// the stacked-tokens chart plots the four `cache*`/input/output components (EXB-3.2 AC4).
struct DashboardDailyEntry: Equatable, Sendable {
    /// Start-of-day in the user's local time zone.
    let date: Date
    /// Total spend for the day, USD.
    let costUSD: Double
    /// Total tokens (input + output) for the day. Kept as the historical "tokens per day" semantic.
    let tokens: Int
    /// Input tokens for the day (stacked-tokens chart, AC4).
    let inputTokens: Int
    /// Output tokens for the day (AC4).
    let outputTokens: Int
    /// Cache-read tokens for the day (AC4).
    let cacheReadTokens: Int
    /// Cache-write (creation) tokens for the day (AC4).
    let cacheWriteTokens: Int
    /// `true` when this day falls inside the span the archive can vouch for (EXB-5.7 §5).
    ///
    /// The distinction the charts were missing: a covered day with no tokens is a day the Senhor did
    /// not work; an *uncovered* day with no tokens is a day exímIABar never saw. Both carry
    /// `costUSD == 0`, so no amount of looking at the value can tell them apart — which is why the
    /// 90-day window used to draw ~35 bars of confident zero over a period nobody observed.
    ///
    /// A flag rather than an optional `costUSD`: every summing call site would otherwise have to
    /// unwrap, and summing zeros is already the right answer for totals.
    let coberto: Bool

    init(
        date: Date,
        costUSD: Double,
        tokens: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        coberto: Bool = true)
    {
        self.date = date
        self.costUSD = costUSD
        self.tokens = tokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.coberto = coberto
    }
}

/// One model's window totals for the breakdown table (EXB-2.3 / EXB-3.2 AC5).
struct DashboardModelEntry: Equatable, Sendable, Identifiable {
    /// The normalized model identifier — doubles as the row `id` (one row per model).
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

/// One `(day, model)` token-volume roll-up for the "Models per day" stacked chart (EXB-3.7 AC4).
///
/// `tokens` is the combined activity volume (input + output + cache read + cache write) for the day
/// and model — the same volume metric the heatmap uses, so a busy cache-heavy day reads as activity.
/// A value type so it is `Sendable` and the aggregation can run inside the off-main `Task.detached`
/// pipeline (anti-freeze invariant).
struct DailyModelEntry: Equatable, Sendable, Identifiable {
    /// Stable identity for `ForEach` — one entry per `(day, model)`.
    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(modelName)" }
    /// Start-of-day in the user's local time zone.
    let date: Date
    /// The normalized model identifier (matches `DashboardModelEntry.model`).
    let modelName: String
    /// Total token volume (input + output + cache read + cache write) for the `(day, model)`.
    let tokens: Int
}

/// The busiest weekday over the window (EXB-4.5 AC3): a named pair so `DashboardData` stays a flat
/// `Equatable`/`Sendable` value (tuples can't be optional stored properties with synthesized `==`).
struct BusiestDay: Equatable, Sendable {
    /// 0 = Sunday … 6 = Saturday (`Calendar.component(.weekday) - 1`).
    let dayOfWeek: Int
    /// Total spend for that weekday over the window, USD.
    let cost: Double
}

/// What the today-vs-average badge is allowed to say (EXB-5.7 §2).
///
/// The old `Double?` collapsed two different silences into one `nil`, and the view had to guess which
/// it was holding. They are not the same thing: *no usage today* is a fact about the Senhor's day;
/// *too early to tell* is a fact about the clock. Naming them separately is what stops the badge from
/// announcing "sem uso hoje" at 00:20 on a day that has barely begun.
enum DailyDeltaState: Equatable, Sendable {
    /// The day is under way and there is a rate to compare: signed fraction vs. the daily average.
    case comparado(Double)
    /// Nothing recorded today, and enough of the day has passed for that to mean something.
    case semUsoHoje
    /// Inside the first hour of the day — any projection here is noise amplified ~288×.
    case cedoDemais
    /// There is no daily average to compare against (an empty window).
    case semBase
}

/// This month against the previous one, in tokens, over **equivalent stretches** (EXB-5.7 §7).
struct ComparacaoMensal: Equatable, Sendable {
    /// Tokens on days 1…`diasComparados` of the current month.
    let tokensAtual: Int
    /// Tokens on days 1…`diasComparados` of the previous month.
    let tokensAnterior: Int
    /// Signed fraction: `(atual − anterior) / anterior`.
    let variacao: Double
    /// How many days of each month were compared — always the same number on both sides.
    let diasComparados: Int
    /// `true` when today's day-of-month exceeded the previous month's length and the stretch was cut
    /// to fit (31 March against February). The label has to say so; 31 days against 28 in silence is
    /// the same category of lie this whole correction is about.
    let truncado: Bool
}

/// The window's top model by token volume (EXB-4.5 AC3 top-model card).
struct TopModel: Equatable, Sendable {
    /// The normalized model identifier (matches `DashboardModelEntry.model`).
    let name: String
    /// Total token volume (input + output + cache read + cache write) for the model.
    let tokens: Int
}

// EXB-5.7 §3/§4: `CachePricing` used to live here, feeding a single consumer — an "economia estimada"
// in dollars that priced cache *reads* (input-side tokens) off the **output** table, inflating the
// figure by exactly 5,44× for every Claude model. With the dollar figure off the screen by the
// owner's decision, the type had no consumer left, so it was deleted rather than corrected. Deleting
// it also removed an `await` on the `Pricing` actor from inside the scan path.

/// The fully-derived analytics dashboard view model (EXB-3.2).
///
/// Built off-MainActor from the `UsageAnalytics` the `CostScanner` produces (EXB-1.7 + EXB-3.2) — the
/// dashboard does **no** JSONL parsing of its own. `dailyCosts` is the zero-filled day axis shared by
/// the cost and stacked-tokens charts.
struct DashboardData: Equatable, Sendable {
    /// The slice of time this data covers (EXB-5.8 §8) — the day axis, and the range the Senhor is
    /// looking at whether he got there by a shortcut or by dragging.
    let span: DashboardSpan
    /// The shortcut that produced `span`, when one did. `nil` after a drag — the CSV filename and the
    /// weekly recap then fall back to naming the dates instead of a button.
    let atalho: DashboardPeriod?
    /// Days on the axis — `span.dias()`, resolved once at build time.
    let spanDays: Int
    /// Per-day cost + token split, ascending by date, zero-filled across the full window (AC3/AC4).
    let dailyCosts: [DashboardDailyEntry]
    /// Alias for the tokens chart — same day axis (AC4).
    var dailyTokens: [DashboardDailyEntry] { dailyCosts }

    /// Per-model totals over the window, sorted by **token volume** descending (EXB-5.7 §6).
    let byModel: [DashboardModelEntry]
    /// Per-`(day, model)` token volume for the "Models per day" stacked chart (EXB-3.7 AC4). Ascending
    /// by date; one entry per `(day, model)` that has activity.
    let byDayByModel: [DailyModelEntry]
    /// Per-project totals over the window, sorted by **token volume** descending (EXB-5.7 §6).
    let byProject: [ProjectUsageEntry]
    /// Weekday × hour token-volume heatmap, 7 × 24 (AC7).
    let heatmap: [[HeatmapBucket]]
    /// Top 10 sessions by cost (AC8).
    let topSessions: [SessionUsageEntry]

    let todayCost: Double
    let todayTokens: Int
    let sevenDayCost: Double
    let sevenDayTokens: Int
    let thirtyDayCost: Double
    let thirtyDayTokens: Int
    /// Average daily spend over the period, divided by the days the source could actually be *seen*
    /// (EXB-5.7) — never by the width of the requested window.
    ///
    /// Dividing by `period.days` was the dashboard's oldest wrong answer: on a 90-day window over an
    /// archive that only reaches back ~55 days, the divisor was 90 for 55 days of data and the average
    /// came out ~40% low. Worse, `dailyDelta` consumes this number, so the distortion reached the badge.
    let averageDailyCost: Double
    /// The divisor behind `averageDailyCost` (EXB-5.7): days from the coverage start through today,
    /// clipped to the window. Exposed because the card has to *name* its divisor — an average whose
    /// denominator is invisible is exactly how the old one hid its error for so long.
    let diasComDado: Int
    /// Average daily **tokens** over the covered days — the headline of the average card, and the
    /// baseline `dailyDelta` compares against (EXB-5.7 §2/§6).
    ///
    /// Same token measure as `todayTokens` (input + output) on purpose: a badge that compared one
    /// definition of "tokens" against another would be arithmetically fine and still wrong.
    let averageDailyTokens: Int
    /// Current-month run-rate projection: `(month-to-date spend ÷ days elapsed) × days in month` (AC2).
    /// Kept as the card's secondary line — the Senhor pays a subscription, not an invoice per token.
    let monthProjection: Double
    /// Projected total **tokens** for the current month (EXB-5.7 §6.2): the same run-rate applied to
    /// `UsageAnalytics.monthToDateTokens`.
    ///
    /// It used to be `monthProjection` scaled by the window's tokens÷cost ratio — a second-hand number
    /// that was wrong whenever the month's model mix differed from the window's, which is most months.
    let projectedTokens: Int

    // MARK: - Efficiency insights (EXB-4.5)

    /// Cache hit rate over the window: `cacheRead ÷ (input + cacheRead + cacheWrite)`, `0…1`.
    /// `0` when there is no input-side activity to divide by.
    let cacheHitRate: Double
    /// Cache-read tokens over the window — the numerator, published so the rate can be stated with the
    /// absolutes beside it. A percentage without its counts is a number nobody can check.
    let tokensDeCache: Int
    /// All input-side tokens over the window (`input + cacheRead + cacheWrite`) — the denominator.
    let tokensDeEntrada: Int
    /// Today's **rate** relative to the daily token average (EXB-5.7 §2), with the reason when there
    /// is no comparison to make.
    let dailyDeltaState: DailyDeltaState
    /// The signed fraction when there is one — `nil` for every state that has nothing to compare.
    var dailyDelta: Double? {
        if case let .comparado(value) = dailyDeltaState { return value }
        return nil
    }
    /// Busiest hour of day (0…23) by total token volume across the heatmap (AC3 peak-hour card).
    let peakHour: Int
    /// The weekday with the highest cost in the window (AC3 busiest-day card): `(0=Sun…6=Sat, cost)`.
    /// `nil` when the window has no spend.
    let busiestDay: BusiestDay?
    /// The model with the most token volume in the window (AC3 top-model card). `nil` when empty.
    let topModelByTokens: TopModel?
    /// This month vs. the previous one, in tokens, over equivalent stretches (EXB-5.7 §7). `nil` when
    /// the archive does not cover the previous month in full — the card is then absent, not estimated.
    let comparacaoMensal: ComparacaoMensal?

    /// `true` when the scan returned no priced entries at all → the empty state is shown.
    var isEmpty: Bool { byModel.isEmpty }

    /// Tag for the CSV filename. A shortcut names itself; a dragged range names its dates, because
    /// `claude-usage-30d.csv` for a stretch that is not the last 30 days would be a file that lies
    /// about its own contents long after anyone remembers dragging it.
    var fileTag: String {
        if let atalho { return atalho.fileTag }
        let f = DateFormatter()
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return "\(f.string(from: span.inicio))-\(f.string(from: span.fim))"
    }

    // MARK: - Period totals (EXB-3.6 AC14)

    /// Total spend over the selected window — the highlight number on the cost card header.
    var totalCost: Double { dailyCosts.reduce(0) { $0 + $1.costUSD } }

    /// Total tokens (all four token types) over the window — the highlight number on the tokens card.
    var totalTokens: Int {
        dailyCosts.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
    }

    /// Total heatmap volume over the window — the highlight number on the heatmap card.
    var totalHeatmapTokens: Int { heatmap.flatMap { $0 }.reduce(0) { $0 + $1.tokens } }

    // MARK: - Period date range (EXB-3.6 AC13)

    /// The first day of the window (inclusive) — start of the section subtitle range.
    var rangeStart: Date? { dailyCosts.first?.date }
    /// The last day of the window (inclusive, normally today) — end of the section subtitle range.
    var rangeEnd: Date? { dailyCosts.last?.date }

    /// The x-domain the day charts must span: the **requested** window, whether or not the archive
    /// covered all of it (EXB-5.7 §5.2).
    ///
    /// Without pinning this, filtering the uncovered days out of the marks would let Swift Charts
    /// auto-fit the axis to the covered span — trading one lie (confident zeros) for another (a
    /// 90-day button that draws 55 days and says nothing about it). The upper bound is pushed one day
    /// out so the final `.day`-wide bar has room to draw.
    var windowDomain: ClosedRange<Date>? {
        guard let rangeStart, let rangeEnd,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: rangeEnd),
              rangeStart < end
        else { return nil }
        return rangeStart...end
    }

    // MARK: - Consistent model → colour mapping (EXB-3.6 AC12)

    /// The window's models, ordered by token volume descending (the donut/table order). The order is
    /// what makes the colour assignment consistent across the donut, the table, and any future
    /// per-model chart: model *N* always gets palette colour *N* for a given period.
    var sortedModelNames: [String] { byModel.map(\.model) }
}

extension DashboardData {
    /// Build for a shortcut, by resolving it to a range and delegating (EXB-5.8 §8).
    ///
    /// One expression, no second implementation: the shortcut door and the range door cannot drift
    /// apart because there is only one door behind them. This mirrors what `CostScanner` did with
    /// `windowDayRange(days:now:)` — equivalence made structural rather than left to two expressions
    /// that happen to agree today.
    static func build(
        from analytics: UsageAnalytics,
        period: DashboardPeriod,
        inicioDoHistorico: Date? = nil,
        now: Date = Date()) -> DashboardData
    {
        build(
            from: analytics,
            span: period.span(inicioDoHistorico: inicioDoHistorico, now: now),
            atalho: period,
            now: now)
    }

    /// Build the analytics dashboard view model from a `UsageAnalytics` scan (EXB-3.2).
    ///
    /// - `analytics`: the rich scan output (per-`(day, model)` rows with cache split, projects,
    ///   heatmap, sessions, month-to-date spend).
    /// - `span`: the slice of time on screen (EXB-5.8 §8) — the day axis runs from `inicio` to `fim`.
    /// - `atalho`: the shortcut that produced `span`, when one did.
    /// - `now`: injected for deterministic day bucketing in tests.
    ///
    /// Anti-freeze: pure value transformation (no I/O), safe from `Task.detached`.
    static func build(
        from analytics: UsageAnalytics,
        span: DashboardSpan,
        atalho: DashboardPeriod? = nil,
        now: Date = Date()) -> DashboardData
    {
        let calendar = Calendar.current
        let spanDays = span.dias(calendar: calendar)

        // AC8: instrument the pure aggregation so Instruments can see build vs. scan vs. apply.
        let signposter = CostScanner.perfSignposter
        let buildState = signposter.beginInterval("DashboardData.build", "span=\(spanDays)d")
        defer { signposter.endInterval("DashboardData.build", buildState) }

        // "Today" keeps meaning *today*, not the last day of the slice: the Today card and its badge
        // are about the Senhor's current day, and they must not start reporting on some day in the
        // middle of a dragged range just because that range happens to end there.
        let todayStart = calendar.startOfDay(for: now)
        let spanInicio = span.inicio
        let spanFim = span.fim

        // --- Coverage anchor (EXB-5.7): ONE definition, two consumers (the average's divisor and the
        // charts' gap/zero distinction). A day at or after this anchor is a day the app watched, so a
        // zero there means "no usage"; before it, a zero means "never observed".
        let coberturaInicio = Self.coverageStart(
            analytics: analytics, windowStart: spanInicio, calendar: calendar)
        // Days from the anchor through the end of the slice, inclusive. Never zero — the average
        // needs a divisor.
        let diasComDado = Swift.max(
            1, (calendar.dateComponents([.day], from: coberturaInicio, to: spanFim).day ?? 0) + 1)

        // --- Daily axis (AC3/AC4): one zero-filled entry per day, summing the token split ---
        struct DayAcc { var cost = 0.0; var input = 0; var output = 0; var cacheRead = 0; var cacheWrite = 0 }
        var byDay: [Date: DayAcc] = [:]
        for entry in analytics.byDayModel {
            let day = calendar.startOfDay(for: entry.date)
            byDay[day, default: DayAcc()].cost += entry.cost
            byDay[day]!.input += entry.inputTokens
            byDay[day]!.output += entry.outputTokens
            byDay[day]!.cacheRead += entry.cacheReadTokens
            byDay[day]!.cacheWrite += entry.cacheWriteTokens
        }

        var daily: [DashboardDailyEntry] = []
        daily.reserveCapacity(spanDays)
        for offset in 0..<spanDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: spanInicio) else { continue }
            let acc = byDay[day] ?? DayAcc()
            daily.append(DashboardDailyEntry(
                date: day,
                costUSD: acc.cost,
                tokens: acc.input + acc.output,
                inputTokens: acc.input,
                outputTokens: acc.output,
                cacheReadTokens: acc.cacheRead,
                cacheWriteTokens: acc.cacheWrite,
                coberto: day >= coberturaInicio))
        }

        // --- Model breakdown (AC5): fold per-(day, model) into one row per model ---
        var byModelAcc: [String: (input: Int, output: Int, cost: Double)] = [:]
        for entry in analytics.byDayModel {
            byModelAcc[entry.model, default: (0, 0, 0)].input += entry.inputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].output += entry.outputTokens
            byModelAcc[entry.model, default: (0, 0, 0)].cost += entry.cost
        }
        let byModel = byModelAcc
            .map { model, totals in
                DashboardModelEntry(model: model, inputTokens: totals.input, outputTokens: totals.output, costUSD: totals.cost)
            }
            // EXB-5.7 §6: ordered by token **volume**, not cost. This is also what assigns the palette
            // (`sortedModelNames`), so the donut, the table and the per-day chart all re-colour with
            // it — intended, not a regression.
            .sorted {
                let l = $0.inputTokens + $0.outputTokens, r = $1.inputTokens + $1.outputTokens
                return l != r ? l > r : $0.model < $1.model
            }

        // --- Models-per-day (AC4): fold per-(day, model) token *volume* (in + out + cache r/w) ---
        // Sum activity volume per (startOfDay, model); emit ascending by date, model name as tiebreak.
        var byDayModelAcc: [Date: [String: Int]] = [:]
        for entry in analytics.byDayModel {
            let day = calendar.startOfDay(for: entry.date)
            let volume = entry.inputTokens + entry.outputTokens + entry.cacheReadTokens + entry.cacheWriteTokens
            byDayModelAcc[day, default: [:]][entry.model, default: 0] += volume
        }
        let byDayByModel: [DailyModelEntry] = byDayModelAcc
            .flatMap { day, models in
                models.map { DailyModelEntry(date: day, modelName: $0.key, tokens: $0.value) }
            }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.modelName < $1.modelName }

        // --- Summary windows (AC2): today / 7d / period totals from the day axis ---
        let sevenDayEarliest = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var todayCost = 0.0, todayTokens = 0
        var sevenDayCost = 0.0, sevenDayTokens = 0
        var periodCost = 0.0, periodTokens = 0
        for entry in daily {
            periodCost += entry.costUSD
            periodTokens += entry.tokens
            if entry.date == todayStart {
                todayCost += entry.costUSD
                todayTokens += entry.tokens
            }
            if entry.date >= sevenDayEarliest, entry.date <= todayStart {
                sevenDayCost += entry.costUSD
                sevenDayTokens += entry.tokens
            }
        }

        // --- Run-rate projection (AC2) ---
        let projection = Self.monthProjection(monthToDateCost: analytics.monthToDateCost, now: now, calendar: calendar)
        // Average daily over the days the source covers — not over the window's width (EXB-5.7).
        let averageDaily = periodCost / Double(diasComDado)

        // --- Projected tokens (EXB-5.7 §6.2): the month's own measured volume, not a ratio ---
        let projectedTokens = Self.monthProjectionTokens(
            monthToDateTokens: analytics.monthToDateTokens, now: now, calendar: calendar)
        // Average daily tokens over the covered days — same divisor as the cost average, same token
        // measure as `todayTokens`, so the badge and the card it sits under speak the same language.
        let averageDailyTokens = periodTokens / diasComDado

        // --- Efficiency insights (EXB-4.5) — all derived from the data already folded above (AC13) ---

        // Cache hit rate over the whole day axis, with the full input-side denominator (EXB-5.7 §3).
        let totalInput = daily.reduce(0) { $0 + $1.inputTokens }
        let totalCacheRead = daily.reduce(0) { $0 + $1.cacheReadTokens }
        let totalCacheWrite = daily.reduce(0) { $0 + $1.cacheWriteTokens }
        let cacheHitRate = Self.cacheHitRate(
            input: totalInput, cacheRead: totalCacheRead, cacheWrite: totalCacheWrite)

        // EXB-5.7 §2/§6: today's *rate* in tokens vs. the daily token average, prorated by the
        // fraction of the day that has actually elapsed.
        let dailyDeltaState = Self.dailyDeltaState(
            todayTokens: todayTokens, averageDailyTokens: averageDailyTokens,
            now: now, calendar: calendar)

        // AC3: busiest hour over the heatmap (argmax of token volume per hour).
        let peakHour = Self.peakHour(heatmap: analytics.heatmap)

        // AC3: busiest weekday by cost over the day axis (0=Sun…6=Sat).
        let busiestDay = Self.busiestDay(daily: daily, calendar: calendar)

        // AC3: top model by token volume (reuses the per-model fold; volume = all four token types).
        let topModelByTokens = Self.topModelByTokens(byDayModel: analytics.byDayModel)

        // EXB-5.7 §7: this month vs. the previous one, equivalent stretches, tokens. The day axis is
        // enough as a source: the comparison only fires when coverage reaches the previous month's
        // first day, and coverage is bounded by the window, so those days are on the axis.
        let comparacaoMensal = Self.comparacaoMensal(
            tokensPorDia: Dictionary(daily.map { ($0.date, $0.tokens) }, uniquingKeysWith: +),
            coberturaInicio: coberturaInicio, now: now, calendar: calendar)

        return DashboardData(
            span: span,
            atalho: atalho,
            spanDays: spanDays,
            dailyCosts: daily,
            byModel: byModel,
            byDayByModel: byDayByModel,
            // EXB-5.7 §6: projects re-ordered by token volume too; `UsageAnalytics` hands them over
            // sorted by cost.
            byProject: analytics.byProject.sorted {
                $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.project < $1.project
            },
            heatmap: analytics.heatmap,
            topSessions: analytics.topSessions,
            todayCost: todayCost,
            todayTokens: todayTokens,
            sevenDayCost: sevenDayCost,
            sevenDayTokens: sevenDayTokens,
            thirtyDayCost: periodCost,
            thirtyDayTokens: periodTokens,
            averageDailyCost: averageDaily,
            diasComDado: diasComDado,
            averageDailyTokens: averageDailyTokens,
            monthProjection: projection,
            projectedTokens: projectedTokens,
            cacheHitRate: cacheHitRate,
            tokensDeCache: totalCacheRead,
            tokensDeEntrada: totalInput + totalCacheRead + totalCacheWrite,
            dailyDeltaState: dailyDeltaState,
            peakHour: peakHour,
            busiestDay: busiestDay,
            topModelByTokens: topModelByTokens,
            comparacaoMensal: comparacaoMensal)
    }

    /// The first day the archive can vouch for, clipped to the window (EXB-5.7).
    ///
    /// Prefers `UsageAnalytics.coveredDays` — the scanner's own, explicitly-recorded claim about which
    /// days it managed to watch. Falls back to the earliest day with *activity* for callers that supply
    /// no coverage (tests, older cache envelopes). The fallback's residual error is bounded and its
    /// direction is known: a run of unused days at the very start of the history is excluded, which
    /// shrinks the divisor and pushes the average **up**. Conservative in the right direction — it
    /// never makes consumption look smaller than it was.
    static func coverageStart(
        analytics: UsageAnalytics,
        windowStart: Date,
        calendar: Calendar = .current) -> Date
    {
        let observed = analytics.coveredDays.map { calendar.startOfDay(for: $0) }.min()
            ?? analytics.byDayModel.map { calendar.startOfDay(for: $0.date) }.min()
        guard let observed else { return windowStart }
        return Swift.max(observed, windowStart)
    }

    // MARK: - Efficiency insight helpers (EXB-4.5) — pure, deterministic, unit-tested directly

    /// Cache hit rate: `cacheRead ÷ (input + cacheRead + cacheWrite)`. Returns `0` when the
    /// denominator is zero — never a NaN.
    ///
    /// EXB-5.7 §3: `cacheWrite` used to be missing from the denominator, which made the rate read
    /// higher than it is. A cache *write* is an input token the Senhor paid for and did not save on;
    /// leaving it out counts only the tokens that flatter the number.
    static func cacheHitRate(input: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let denominator = input + cacheRead + cacheWrite
        guard denominator > 0 else { return 0 }
        return Double(cacheRead) / Double(denominator)
    }

    /// The lower edge of the dead zone: inside the first hour there is no honest projection to make.
    static let deltaZonaMorta = 1.0 / 24.0
    /// The floor the elapsed fraction is clamped to — 3 hours.
    static let deltaPisoFracao = 0.125

    /// Today's rate vs. the daily token average, normalized by how much of the day has actually
    /// elapsed (EXB-5.7 §2).
    ///
    /// The defect this replaces: today, still in progress, was compared against an average of **whole**
    /// days. At 09:00 only 37,5% of the day has passed, so the badge was arithmetically forced to read
    /// "below average" on a record-setting morning. The error peaked just after midnight and vanished
    /// by 23:59 — the panel was most wrong exactly when the Senhor opened it earliest.
    ///
    /// Both limits earn their place. **Without the dead zone**, 00:05 divides by 0,0035 and amplifies a
    /// single message into "+28.000% acima da média". **Without the floor**, the 1h–3h band still
    /// amplifies by 24× down to 8×. The 3-hour floor makes the projection *understate* in that band,
    /// which is the deliberate direction: a panel saying "ainda abaixo" at 02:00 is honest; one
    /// shouting "recorde histórico" off forty minutes of work is not.
    static func dailyDelta(todayTokens: Int, averageDailyTokens: Int, now: Date,
                           calendar: Calendar = .current) -> Double?
    {
        guard averageDailyTokens > 0 else { return nil }
        guard todayTokens > 0 else { return nil }
        let fracao = fracaoDoDiaDecorrida(now: now, calendar: calendar)
        guard fracao >= deltaZonaMorta else { return nil }
        let fracaoEfetiva = Swift.max(fracao, deltaPisoFracao)
        let projetado = Double(todayTokens) / fracaoEfetiva
        let media = Double(averageDailyTokens)
        return (projetado - media) / media
    }

    /// How much of the local day has elapsed at `now`, `0…1`.
    static func fracaoDoDiaDecorrida(now: Date, calendar: Calendar = .current) -> Double {
        let inicio = calendar.startOfDay(for: now)
        let decorrido = now.timeIntervalSince(inicio)
        return Swift.min(Swift.max(decorrido / 86_400, 0), 1)
    }

    /// The badge's full state, with the reason when there is nothing to compare (EXB-5.7 §2.1).
    static func dailyDeltaState(todayTokens: Int, averageDailyTokens: Int, now: Date,
                                calendar: Calendar = .current) -> DailyDeltaState
    {
        guard averageDailyTokens > 0 else { return .semBase }
        // The clock is checked before the usage: at 00:20 "sem uso hoje" is technically true and
        // completely uninformative, because no day has any usage twenty minutes in.
        guard fracaoDoDiaDecorrida(now: now, calendar: calendar) >= deltaZonaMorta else { return .cedoDemais }
        guard todayTokens > 0 else { return .semUsoHoje }
        guard let delta = dailyDelta(
            todayTokens: todayTokens, averageDailyTokens: averageDailyTokens,
            now: now, calendar: calendar)
        else { return .semUsoHoje }
        return .comparado(delta)
    }

    /// Peak hour of day (AC3): argmax of summed token volume per hour over the 7 × 24 heatmap.
    /// Returns `0` for an all-zero heatmap (a defined, stable default).
    static func peakHour(heatmap: [[HeatmapBucket]]) -> Int {
        var hourTotals = [Int](repeating: 0, count: 24)
        for day in heatmap {
            for bucket in day where bucket.hour >= 0 && bucket.hour < 24 {
                hourTotals[bucket.hour] += bucket.tokens
            }
        }
        // argmax; ties resolve to the earliest hour. All-zero → hour 0.
        return hourTotals.indices.max(by: { hourTotals[$0] < hourTotals[$1] }) ?? 0
    }

    /// Busiest weekday by cost (AC3) over the day axis. `nil` when no day has spend.
    static func busiestDay(daily: [DashboardDailyEntry], calendar: Calendar = .current) -> BusiestDay? {
        var costByDay: [Int: Double] = [:]
        for entry in daily where entry.costUSD > 0 {
            let dow = calendar.component(.weekday, from: entry.date) - 1 // 0 = Sun … 6 = Sat
            costByDay[dow, default: 0] += entry.costUSD
        }
        // Pick the max cost; ties resolve to the lower weekday index for determinism.
        guard let best = costByDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
        else { return nil }
        return BusiestDay(dayOfWeek: best.key, cost: best.value)
    }

    /// Top model by token volume (AC3): fold per-`(day, model)` rows by total volume (all four token
    /// types), then argmax. `nil` when there are no rows. Ties resolve to the lexicographically
    /// smaller model name for determinism.
    static func topModelByTokens(byDayModel: [ModelCostEntry]) -> TopModel? {
        var tokensByModel: [String: Int] = [:]
        for entry in byDayModel {
            let volume = entry.inputTokens + entry.outputTokens + entry.cacheReadTokens + entry.cacheWriteTokens
            tokensByModel[entry.model, default: 0] += volume
        }
        guard let best = tokensByModel.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
        else { return nil }
        return TopModel(name: best.key, tokens: best.value)
    }

    /// This month against the previous one, in tokens, over **equivalent stretches** (EXB-5.7 §7).
    ///
    /// The obvious comparison — this month so far against the previous month *whole* — is wrong, and
    /// wrong with a fixed sign. On 24 August it puts 24 days against 31 and reports −22,6% even when
    /// the daily rate is rigorously identical. A panel built that way would announce "consumo caindo"
    /// on the first of every month, for ever, and be believed.
    ///
    /// So: days 1…N of this month against days 1…N of the last, with `N` = today's day of month,
    /// truncated to the previous month's length when it does not fit.
    ///
    /// Returns `nil` — and the card disappears — when the archive does not cover the previous month
    /// **from its first day**. Comparing against a month the app only half-watched would understate
    /// the past and manufacture growth. There is no estimate here on purpose: the honest answer to
    /// "how does this month compare?" with no baseline is that we do not know.
    static func comparacaoMensal(
        tokensPorDia: [Date: Int],
        coberturaInicio: Date,
        now: Date,
        calendar: Calendar = .current) -> ComparacaoMensal?
    {
        guard let inicioAtual = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let inicioAnterior = calendar.date(byAdding: .month, value: -1, to: inicioAtual),
              let diasNoAnterior = calendar.range(of: .day, in: .month, for: inicioAnterior)?.count
        else { return nil }

        // The baseline has to be whole. Coverage starting mid-month is not a smaller month, it is an
        // unknown one.
        guard calendar.startOfDay(for: coberturaInicio) <= inicioAnterior else { return nil }

        let hoje = calendar.component(.day, from: now)
        let dias = Swift.min(hoje, diasNoAnterior)
        guard dias > 0 else { return nil }

        func soma(desde inicio: Date) -> Int {
            (0..<dias).reduce(0) { total, offset in
                guard let dia = calendar.date(byAdding: .day, value: offset, to: inicio) else { return total }
                return total + (tokensPorDia[calendar.startOfDay(for: dia)] ?? 0)
            }
        }
        let anterior = soma(desde: inicioAnterior)
        guard anterior > 0 else { return nil }
        let atual = soma(desde: inicioAtual)

        return ComparacaoMensal(
            tokensAtual: atual,
            tokensAnterior: anterior,
            variacao: (Double(atual) - Double(anterior)) / Double(anterior),
            diasComparados: dias,
            truncado: hoje > diasNoAnterior)
    }

    /// Current-month run-rate projection (AC2): `(spent this month ÷ days elapsed) × days in month`.
    /// Days elapsed counts today as day 1; guards against a zero divisor.
    static func monthProjection(monthToDateCost: Double, now: Date, calendar: Calendar = .current) -> Double {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count
        else { return monthToDateCost }
        let elapsedComponent = calendar.dateComponents([.day], from: startOfMonth, to: now).day ?? 0
        let daysElapsed = max(1, elapsedComponent + 1)
        return (monthToDateCost / Double(daysElapsed)) * Double(daysInMonth)
    }

    /// Current-month run-rate projection in **tokens** (EXB-5.7 §6.2) — the same run-rate the cost
    /// projection uses, applied to the month's own measured volume.
    ///
    /// Replaces `projectedTokens(periodTokens:periodCost:projectedCost:)`, which derived tokens from
    /// the *cost* projection by the window's tokens÷cost ratio. That ratio only held when the month's
    /// model mix matched the window's; the rest of the time the headline number was a plausible
    /// fabrication. `UsageAnalytics.monthToDateTokens` measures the month directly, so nothing is
    /// derived any more.
    static func monthProjectionTokens(monthToDateTokens: Int, now: Date, calendar: Calendar = .current) -> Int {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count
        else { return monthToDateTokens }
        let elapsedComponent = calendar.dateComponents([.day], from: startOfMonth, to: now).day ?? 0
        let daysElapsed = max(1, elapsedComponent + 1)
        return Int(((Double(monthToDateTokens) / Double(daysElapsed)) * Double(daysInMonth)).rounded())
    }

    /// Render the period's daily aggregate as CSV (AC9). Header + one row per day in the axis:
    /// `date,cost_usd,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens`.
    func csvExport() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        var lines = ["date,cost_usd,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens"]
        for entry in dailyCosts {
            let date = formatter.string(from: entry.date)
            let cost = String(format: "%.4f", entry.costUSD)
            lines.append("\(date),\(cost),\(entry.inputTokens),\(entry.outputTokens),\(entry.cacheReadTokens),\(entry.cacheWriteTokens)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
