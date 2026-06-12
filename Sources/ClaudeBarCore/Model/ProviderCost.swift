import Foundation

/// A single `(day, model)` cost roll-up produced by the local JSONL scan (EXB-1.7).
///
/// One entry per `(date, model)` pair: token totals and the priced cost in USD. The popover's
/// cost-detail submenu renders `byModel` (AC8): `"claude-sonnet-4: $0.04 · 12K tokens"`.
public struct ModelCostEntry: Sendable, Equatable {
    /// The model identifier (normalized, e.g. `"claude-sonnet-4"`).
    public let model: String
    /// The calendar day (start-of-day, user's local time zone) this roll-up covers.
    public let date: Date
    /// Input tokens billed for this `(day, model)`.
    public let inputTokens: Int
    /// Output tokens billed for this `(day, model)`.
    public let outputTokens: Int
    /// Cache-read input tokens for this `(day, model)` (`cache_read_input_tokens`, EXB-3.2).
    public let cacheReadTokens: Int
    /// Cache-creation / write input tokens for this `(day, model)`
    /// (`cache_creation_input_tokens`, EXB-3.2).
    public let cacheWriteTokens: Int
    /// Estimated cost in USD for this `(day, model)`.
    public let cost: Double

    public init(
        model: String,
        date: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cost: Double)
    {
        self.model = model
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
    }

    /// Total tokens (input + output) for convenience formatting. Excludes cache tokens so the value
    /// matches the historical popover "tokens" semantics (EXB-1.7 callers unaffected by EXB-3.2).
    public var totalTokens: Int { self.inputTokens + self.outputTokens }
}

/// Estimated spend derived from a local scan of Claude Code's JSONL session logs (EXB-1.7).
///
/// Values are in major units (USD). The scan aggregates `usage.input_tokens` /
/// `usage.output_tokens` per `(day, model)` and prices them with `Pricing` (models.dev with a
/// hardcoded fallback table). `today` / `last30Days` are convenience totals over the scan window;
/// `byModel` carries the per-`(day, model)` breakdown for the popover's cost-detail submenu (AC7/AC8).
public struct ProviderCost: Sendable, Equatable {
    /// Spend in the current calendar day (user's local time zone), USD.
    public let today: Double
    /// Spend over the trailing `costDays` window (default 30 days), USD.
    public let last30Days: Double
    /// Token count today (input + output).
    public let todayTokens: Int
    /// Token count over the trailing window (input + output).
    public let last30DaysTokens: Int
    /// Per-`(day, model)` breakdown, sorted descending by cost. Drives the cost-detail submenu (AC8).
    public let byModel: [ModelCostEntry]

    public init(
        today: Double,
        last30Days: Double,
        todayTokens: Int,
        last30DaysTokens: Int,
        byModel: [ModelCostEntry] = [])
    {
        self.today = today
        self.last30Days = last30Days
        self.todayTokens = todayTokens
        self.last30DaysTokens = last30DaysTokens
        self.byModel = byModel
    }
}

/// "Extra usage" overage cap, normalized to major units (dollars).
public struct ExtraUsage: Sendable, Equatable {
    public let isEnabled: Bool
    /// Monthly cap in major units (centavos / 100).
    public let monthlyLimit: Double
    /// Used credits in major units (centavos / 100).
    public let usedCredits: Double
    /// Percentage of the cap consumed, 0–100, if reported.
    public let utilization: Double?
    /// ISO currency code, uppercased (e.g. `"USD"`).
    public let currency: String

    public init(
        isEnabled: Bool,
        monthlyLimit: Double,
        usedCredits: Double,
        utilization: Double?,
        currency: String)
    {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
    }
}
