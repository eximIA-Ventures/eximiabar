import Foundation

/// The subscription plan the ChatGPT/Codex side reports, either in the `id_token` claims
/// (`https://api.openai.com/auth.chatgpt_plan_type`) or in the `plan_type` of `wham/usage`.
///
/// Deliberately **not** `ClaudePlan`: `ClaudePlan.brandedLoginMethod` renders "Claude Pro",
/// which would be a lie on a Codex account. The two plan vocabularies also barely overlap
/// (`plus`, `go`, `business` have no Claude counterpart).
public enum CodexPlan: Sendable, Equatable {
    case free
    case go
    case plus
    case pro
    case team
    case business
    case enterprise
    case edu
    /// Any value the API starts returning that this build does not know yet — kept verbatim
    /// so an unknown plan degrades to "shown as-is", never to a crash or a wrong label.
    case other(String)

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "free": self = .free
        case "go": self = .go
        case "plus": self = .plus
        case "pro": self = .pro
        case "team": self = .team
        case "business": self = .business
        case "enterprise": self = .enterprise
        case "edu", "education": self = .edu
        default: self = .other(normalized)
        }
    }

    public var rawValue: String {
        switch self {
        case .free: "free"
        case .go: "go"
        case .plus: "plus"
        case .pro: "pro"
        case .team: "team"
        case .business: "business"
        case .enterprise: "enterprise"
        case .edu: "edu"
        case let .other(value): value
        }
    }

    /// Label for the popover header — always branded "ChatGPT", never "Claude".
    public var displayName: String {
        switch self {
        case .free: "ChatGPT Free"
        case .go: "ChatGPT Go"
        case .plus: "ChatGPT Plus"
        case .pro: "ChatGPT Pro"
        case .team: "ChatGPT Team"
        case .business: "ChatGPT Business"
        case .enterprise: "ChatGPT Enterprise"
        case .edu: "ChatGPT Edu"
        case let .other(value): "ChatGPT \(value.capitalized)"
        }
    }
}

/// The claims carried by a Codex JWT (`tokens.id_token` / `tokens.access_token` of
/// `~/.codex/auth.json`), read **without verifying the signature** (EXB-5.4 AC2).
///
/// We are not the verifier — the signature is the Codex backend's business. What we need is
/// three facts the payload already carries, so identity and plan cost **zero** extra network
/// calls: `email`, `exp`, and the OpenAI-namespaced auth object with `chatgpt_plan_type` /
/// `chatgpt_account_id`.
///
/// Every field is optional and every decode path is total: a malformed segment, a payload that
/// is not an object, a missing claim — all yield `nil`, never a throw and never a crash.
public struct CodexJWTClaims: Sendable, Equatable {
    /// The OpenAI-namespaced claim that nests `chatgpt_plan_type` and friends.
    public static let openAIAuthClaimKey = "https://api.openai.com/auth"

    public let email: String?
    public let expiresAt: Date?
    public let plan: CodexPlan?
    public let chatGPTAccountID: String?

    public init(
        email: String? = nil,
        expiresAt: Date? = nil,
        plan: CodexPlan? = nil,
        chatGPTAccountID: String? = nil)
    {
        self.email = email
        self.expiresAt = expiresAt
        self.plan = plan
        self.chatGPTAccountID = chatGPTAccountID
    }

    /// Decodes the payload (second segment) of a JWT. Returns `nil` when the string is not
    /// shaped like a JWT or the payload is not a JSON object — the caller then treats the
    /// token as "claims unknown", which is never fatal by itself.
    public static func decode(_ token: String) -> CodexJWTClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        guard let payload = Self.base64URLDecode(String(segments[1])) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let claims = object as? [String: Any]
        else { return nil }

        let openAIAuth = claims[Self.openAIAuthClaimKey] as? [String: Any] ?? [:]
        let rawPlan = openAIAuth["chatgpt_plan_type"] as? String

        return CodexJWTClaims(
            email: Self.nonEmptyString(claims["email"]),
            expiresAt: Self.date(from: claims["exp"]),
            plan: rawPlan.flatMap(CodexPlan.init(rawValue:)),
            chatGPTAccountID: Self.nonEmptyString(openAIAuth["chatgpt_account_id"]))
    }

    /// Whether the token is past its expiry. **An unknown expiry is never treated as expired** —
    /// a token whose `exp` we cannot read is handed to the API, and a real 401 is the verdict.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 0) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(leeway) <= now
    }

    // MARK: Helpers

    /// base64url → `Data`: the URL alphabet (`-_`) mapped back to `+/`, then re-padded.
    static func base64URLDecode(_ segment: String) -> Data? {
        var normalized = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `iat` / `exp` are epoch seconds, but a tolerant reader accepts the string form too.
    private static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let text = value as? String, let seconds = TimeInterval(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
