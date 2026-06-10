import Foundation

/// Who owns the credentials we loaded. Determines the refresh contract (AC13):
///  - `.claudeCLI`  → NEVER POST to the refresh endpoint; delegate via `claude /status`.
///  - `.claudebar`  → direct refresh allowed.
///  - `.environment` → no refresh.
public enum CredentialOwner: String, Codable, Sendable, Equatable {
    case claudeCLI
    case claudebar
    case environment
}

/// Which layer produced the credentials (for diagnostics / cache decisions).
public enum CredentialSource: String, Sendable, Equatable {
    case environment
    case memoryCache
    case cacheKeychain
    case credentialsFile
    case claudeKeychain
}

/// Typed Claude OAuth credentials.
///
/// Ported from
/// `_reference_codexbar/.../ClaudeOAuth/ClaudeOAuthCredentialModels.swift`.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        rateLimitTier: String?,
        subscriptionType: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
    }

    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }

    public var expiresIn: TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }

    /// Parses the `~/.claude/.credentials.json` shape — `claudeAiOauth.accessToken`, etc.
    public static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(ClaudeCredentialsFile.self, from: data) else {
            throw ClaudeOAuthCredentialsError.decodeFailed
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeOAuthCredentialsError.missingOAuth
        }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw ClaudeOAuthCredentialsError.missingAccessToken
        }
        let expiresAt = oauth.expiresAt.map { millis in
            Date(timeIntervalSince1970: millis / 1000.0)
        }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            rateLimitTier: oauth.rateLimitTier,
            subscriptionType: oauth.subscriptionType)
    }
}

/// JSON shape of `~/.claude/.credentials.json`.
public struct ClaudeCredentialsFile: Decodable, Sendable {
    public let claudeAiOauth: OAuth?

    public struct OAuth: Decodable, Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let expiresAt: Double?
        public let scopes: [String]?
        public let rateLimitTier: String?
        public let subscriptionType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case expiresAt
            case scopes
            case rateLimitTier
            case subscriptionType
        }
    }
}

/// A loaded credential plus its provenance.
public struct ClaudeOAuthCredentialRecord: Sendable, Equatable {
    public let credentials: ClaudeOAuthCredentials
    public let owner: CredentialOwner
    public let source: CredentialSource

    public init(
        credentials: ClaudeOAuthCredentials,
        owner: CredentialOwner,
        source: CredentialSource)
    {
        self.credentials = credentials
        self.owner = owner
        self.source = source
    }
}

public enum ClaudeOAuthCredentialsError: LocalizedError, Sendable, Equatable {
    case decodeFailed
    case missingOAuth
    case missingAccessToken
    case notFound
    case keychainError(Int)
    case readFailed(String)
    case refreshFailed(String)
    case noRefreshToken
    case refreshDelegatedToClaudeCLI

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            "Claude OAuth credentials are invalid."
        case .missingOAuth:
            "Claude OAuth credentials missing. Run `claude` to authenticate."
        case .missingAccessToken:
            "Claude OAuth access token missing. Run `claude` to authenticate."
        case .notFound:
            "Claude OAuth credentials not found. Run `claude` to authenticate."
        case let .keychainError(status):
            "Claude OAuth keychain error: \(status)"
        case let .readFailed(message):
            "Claude OAuth credentials read failed: \(message)"
        case let .refreshFailed(message):
            "Claude OAuth token refresh failed: \(message)"
        case .noRefreshToken:
            "Claude OAuth refresh token missing. Run `claude` to authenticate."
        case .refreshDelegatedToClaudeCLI:
            "Claude OAuth refresh is delegated to Claude CLI."
        }
    }
}
