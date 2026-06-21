import Foundation

/// Claude subscription plan, resolved from `subscriptionType` / `rateLimitTier`.
///
/// Ported and adapted from
/// `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudePlan.swift:8,49-106`.
/// Covers Max / Pro / Team / Enterprise / Ultra.
public enum ClaudePlan: String, CaseIterable, Sendable, Equatable {
    case max
    case pro
    case team
    case enterprise
    case ultra

    /// Convenience initializer matching the story contract (AC10).
    public init?(subscriptionType: String?, rateLimitTier: String?) {
        guard let plan = Self.fromOAuthCredentials(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier)
        else { return nil }
        self = plan
    }

    public var brandedLoginMethod: String {
        switch self {
        case .max: "Claude Max"
        case .pro: "Claude Pro"
        case .team: "Claude Team"
        case .enterprise: "Claude Enterprise"
        case .ultra: "Claude Ultra"
        }
    }

    public var compactLoginMethod: String {
        switch self {
        case .max: "Max"
        case .pro: "Pro"
        case .team: "Team"
        case .enterprise: "Enterprise"
        case .ultra: "Ultra"
        }
    }

    public var countsAsSubscription: Bool {
        switch self {
        case .max, .pro, .team, .ultra: true
        case .enterprise: false
        }
    }

    /// Approximate published monthly price in USD, used to frame the local cost estimate as a value
    /// multiplier (EXB redesign #2). `nil` when the price varies per-seat or is custom (team /
    /// enterprise / ultra) — then no ROI multiplier is shown, only the raw number. Max uses the
    /// higher published tier ($200) so the multiplier is a conservative floor, never inflated.
    public var approxMonthlyPriceUSD: Double? {
        switch self {
        case .max: 200
        case .pro: 20
        case .team, .enterprise, .ultra: nil
        }
    }

    public static func fromOAuthRateLimitTier(_ rateLimitTier: String?) -> Self? {
        self.fromRateLimitTier(rateLimitTier)
    }

    public static func fromOAuthCredentials(subscriptionType: String?, rateLimitTier: String?) -> Self? {
        self.fromCompatibilityLoginMethod(subscriptionType)
            ?? self.fromOAuthRateLimitTier(rateLimitTier)
    }

    public static func fromCompatibilityLoginMethod(_ loginMethod: String?) -> Self? {
        let words = Self.normalizedWords(loginMethod)
        if words.isEmpty { return nil }
        if words.contains("max") { return .max }
        if words.contains("pro") { return .pro }
        if words.contains("team") { return .team }
        if words.contains("enterprise") { return .enterprise }
        if words.contains("ultra") { return .ultra }
        return nil
    }

    public static func oauthLoginMethod(subscriptionType: String?, rateLimitTier: String?) -> String? {
        self.fromOAuthCredentials(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier)?.brandedLoginMethod
    }

    private static func fromRateLimitTier(_ rateLimitTier: String?) -> Self? {
        let tier = Self.normalized(rateLimitTier)
        if tier.contains("max") { return .max }
        if tier.contains("pro") { return .pro }
        if tier.contains("team") { return .team }
        if tier.contains("enterprise") { return .enterprise }
        if tier.contains("ultra") { return .ultra }
        return nil
    }

    private static func normalized(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedWords(_ text: String?) -> [String] {
        self.normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
