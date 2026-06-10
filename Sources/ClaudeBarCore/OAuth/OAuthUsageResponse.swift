import Foundation

/// Decodes the `GET /api/oauth/usage` response (AC6, AC7).
///
/// - Unknown keys are tolerated via `DynamicCodingKey`.
/// - Probe fields `iguana_necktie`, `seven_day_design`, `seven_day_omelette` are decoded
///   and silently discarded.
/// - `extra_usage` monetary fields are in centavos (callers divide by 100).
///
/// Ported from `_reference_codexbar/.../ClaudeOAuth/ClaudeOAuthUsageFetcher.swift:141-251`.
public struct OAuthUsageResponse: Decodable, Sendable, Equatable {
    public let fiveHour: OAuthUsageWindow?
    public let sevenDay: OAuthUsageWindow?
    public let sevenDayOAuthApps: OAuthUsageWindow?
    public let sevenDayOpus: OAuthUsageWindow?
    public let sevenDaySonnet: OAuthUsageWindow?
    public let sevenDayRoutines: OAuthUsageWindow?
    /// The key that supplied `sevenDayRoutines` (or, when present-but-null, the first null key).
    /// Non-nil even when the window is null so callers can render a 0% bar (AC9).
    public let sevenDayRoutinesSourceKey: String?
    /// Anthropic probe field — decoded then discarded (AC6).
    public let iguanaNecktie: OAuthUsageWindow?
    public let extraUsage: OAuthExtraUsage?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.fiveHour = Self.decodeWindow(in: container, keys: ["five_hour"])
        self.sevenDay = Self.decodeWindow(in: container, keys: ["seven_day"])
        self.sevenDayOAuthApps = Self.decodeWindow(in: container, keys: ["seven_day_oauth_apps"])
        self.sevenDayOpus = Self.decodeWindow(in: container, keys: ["seven_day_opus"])
        self.sevenDaySonnet = Self.decodeWindow(in: container, keys: ["seven_day_sonnet"])
        let routines = Self.decodeWindowWithSource(in: container, keys: [
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ])
        self.sevenDayRoutines = routines.window
        self.sevenDayRoutinesSourceKey = routines.sourceKey
        self.iguanaNecktie = Self.decodeWindow(in: container, keys: ["iguana_necktie"])
        self.extraUsage = Self.decodeValue(in: container, keys: ["extra_usage"])
        // `seven_day_design` and `seven_day_omelette` share the main limit; never decoded
        // as separate windows — they are silently discarded by virtue of not being read.
    }

    private static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> OAuthUsageWindow?
    {
        self.decodeValue(in: container, keys: keys)
    }

    private static func decodeWindowWithSource(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> (window: OAuthUsageWindow?, sourceKey: String?)
    {
        var firstNullKey: String?
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            guard container.contains(key) else { continue }
            if let value = try? container.decodeIfPresent(OAuthUsageWindow.self, forKey: key) {
                return (value, keyName)
            }
            if firstNullKey == nil {
                firstNullKey = keyName
            }
        }
        return (nil, firstNullKey)
    }

    private static func decodeValue<T: Decodable>(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> T?
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            if let value = try? container.decodeIfPresent(T.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

/// A coding key that accepts any string — enables unknown-key tolerance.
struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue _: Int) {
        nil
    }
}

/// A single rate window in the OAuth response.
public struct OAuthUsageWindow: Decodable, Sendable, Equatable {
    public let utilization: Double?
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Extra-usage block. Monetary fields are in centavos (minor units) — divide by 100 (AC7).
public struct OAuthExtraUsage: Decodable, Sendable, Equatable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}
