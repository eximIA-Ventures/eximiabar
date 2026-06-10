import Foundation

/// Monetary usage ("extra usage" / overage credits).
///
/// The OAuth API returns monetary fields in centavos (minor units). Values here are
/// already normalized to major units (dollars) by the snapshot mapper — see
/// `UsageSnapshot+OAuth.swift`.
public struct ProviderCost: Sendable, Equatable {
    /// Spend in the current day, in major units.
    public let today: Double
    /// Spend in the trailing 30 days, in major units.
    public let last30Days: Double
    /// Token count today.
    public let todayTokens: Int
    /// Token count over the trailing 30 days.
    public let last30DaysTokens: Int

    public init(today: Double, last30Days: Double, todayTokens: Int, last30DaysTokens: Int) {
        self.today = today
        self.last30Days = last30Days
        self.todayTokens = todayTokens
        self.last30DaysTokens = last30DaysTokens
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
