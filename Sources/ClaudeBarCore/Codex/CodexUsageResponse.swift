import Foundation

/// Decodes `GET https://chatgpt.com/backend-api/wham/usage` (EXB-5.4 AC2).
///
/// The endpoint is **undocumented** (risk R15 of the wave): it can gain, lose or rename fields
/// without warning. So every field is optional and every nested decode is `try?` — a schema
/// change degrades the Codex panel to "window unknown", it never throws away the fields that
/// still decoded and it never takes the app down.
///
/// Same tolerance contract as `OAuthUsageResponse` for the Claude side.
public struct CodexUsageResponse: Decodable, Sendable, Equatable {
    /// `plan_type` as reported by the API. Preferred over the JWT claim when both are present:
    /// the API answers "now", the token answers "when it was issued".
    public let planType: String?
    public let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        // `additional_rate_limits` (Codex Spark and other model-specific caps) is deliberately
        // NOT decoded in this wave — Onda 11 candidate. It is additive: ignoring it cannot
        // disturb the primary/secondary mapping below.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
    }

    /// The plan the response asserts, if it is a value we can read.
    public var plan: CodexPlan? {
        self.planType.flatMap(CodexPlan.init(rawValue:))
    }
}

/// The `rate_limit` object: two windows, the shorter one first.
public struct CodexRateLimit: Decodable, Sendable, Equatable {
    /// The rolling session window (typically 5 h).
    public let primaryWindow: CodexRateLimitWindow?
    /// The long window (typically 7 days).
    public let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primaryWindow = try? container.decodeIfPresent(
            CodexRateLimitWindow.self,
            forKey: .primaryWindow)
        self.secondaryWindow = try? container.decodeIfPresent(
            CodexRateLimitWindow.self,
            forKey: .secondaryWindow)
    }
}

/// One window of `rate_limit`.
///
/// `used_percent` is already a 0–100 percentage and is carried verbatim into
/// `RateWindow.utilization` — never multiplied by 100, matching the `RateWindow` contract.
/// `reset_at` is an **absolute** epoch-seconds instant, not a countdown.
public struct CodexRateLimitWindow: Decodable, Sendable, Equatable {
    public let usedPercent: Double?
    public let resetAt: Date?
    public let limitWindowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = Self.double(in: container, forKey: .usedPercent)
        self.resetAt = Self.double(in: container, forKey: .resetAt)
            .map { Date(timeIntervalSince1970: $0) }
        self.limitWindowSeconds = Self.double(in: container, forKey: .limitWindowSeconds)
            .map { Int($0) }
    }

    public init(usedPercent: Double?, resetAt: Date?, limitWindowSeconds: Int?) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.limitWindowSeconds = limitWindowSeconds
    }

    /// Maps to the app-wide `RateWindow`.
    ///
    /// - Parameter fallbackWindowMinutes: used when the payload omits `limit_window_seconds`,
    ///   so a window with an unknown length still lands in the right lane (session vs weekly).
    public func rateWindow(fallbackWindowMinutes: Int) -> RateWindow {
        let minutes = self.limitWindowSeconds.map { max(1, $0 / 60) } ?? fallbackWindowMinutes
        return RateWindow(
            utilization: self.usedPercent ?? 0,
            resetsAt: self.resetAt,
            windowMinutes: minutes)
    }

    /// Numbers arrive as JSON numbers, but a tolerant reader accepts the string form too.
    private static func double(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> Double?
    {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text)
        }
        return nil
    }
}
