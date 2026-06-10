import Foundation

/// Typed errors surfaced by the OAuth usage pipeline.
public enum UsageError: Error, Sendable, Equatable {
    /// HTTP 401 — token rejected; user must re-authenticate.
    case authRequired(String)
    /// HTTP 403 with a missing `user:profile` scope.
    case scopeMissing(String)
    /// HTTP 429 — rate limited until `retryAfter`.
    case rateLimited(retryAfter: Date)
    /// Transport-level failure (DNS, timeout, connection).
    case networkError(String)
    /// Response body could not be decoded.
    case parseError(String)
    /// A gate (rate-limit or refresh-failure) is blocking further attempts.
    case blocked(String)

    public var message: String {
        switch self {
        case let .authRequired(message): message
        case let .scopeMissing(message): message
        case let .rateLimited(retryAfter):
            "Rate limited. Retry after \(retryAfter)."
        case let .networkError(message): message
        case let .parseError(message): message
        case let .blocked(message): message
        }
    }

    /// Whether `auto` mode should fall through to the next source on this error.
    public var isAuthOrScope: Bool {
        switch self {
        case .authRequired, .scopeMissing: true
        case .rateLimited, .networkError, .parseError, .blocked: false
        }
    }
}

extension UsageError: LocalizedError {
    public var errorDescription: String? { message }
}
