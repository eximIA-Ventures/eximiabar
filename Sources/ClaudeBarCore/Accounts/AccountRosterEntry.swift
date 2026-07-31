import Foundation

/// Whether an account is the one the CLI is logged into right now, or one the app captured
/// when the user switched away from it (EXB-5.2 AC1).
public enum AccountLifecycle: String, Codable, Sendable {
    case live
    case archived
}

/// One row of the local account roster — **pure metadata, never a secret**.
///
/// This split is the whole point of the design: the switcher (`EXB-5.5`) renders the entire
/// account list and derives "expired" from `tokenExpiresAt` **without touching the keychain**.
/// Only the card of one specific archived account asks `AccountRosterStore.archivedToken(for:)`,
/// and only when it is actually rendered.
public struct AccountRosterEntry: Codable, Sendable, Equatable {
    public let identity: AccountIdentity
    public let lifecycle: AccountLifecycle
    public let plan: String?
    public let capturedAt: Date
    public var lastSeenAt: Date
    public let tokenExpiresAt: Date?

    public init(
        identity: AccountIdentity,
        lifecycle: AccountLifecycle,
        plan: String?,
        capturedAt: Date,
        lastSeenAt: Date,
        tokenExpiresAt: Date?)
    {
        self.identity = identity
        self.lifecycle = lifecycle
        self.plan = plan
        self.capturedAt = capturedAt
        self.lastSeenAt = lastSeenAt
        self.tokenExpiresAt = tokenExpiresAt
    }

    public var key: AccountKey { self.identity.key }
}

/// The secret half of an archived account, kept in its own keychain item.
///
/// It carries the access token and its expiry — and **nothing else** (EXB-5.2 AC2.5, decision
/// D-A). An archived account is strictly read-only: it is never renewed and never fetched
/// (AC5), so the renewal credential of that account has no functional use here and would be a
/// pure security liability. The type simply has no field for it, which makes storing one
/// impossible rather than merely forbidden.
public struct ArchivedToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

/// What one capture attempt did (EXB-5.2 AC2.6).
public enum CaptureOutcome: Sendable, Equatable {
    /// The live account is the same one we already knew; only `lastSeenAt` moved.
    case unchanged(AccountKey)
    /// A new live account was recorded. `archived` is the account we switched away from,
    /// or `nil` on the first observation of this process.
    case captured(archived: AccountKey?, live: AccountKey)
    /// Nothing was written (R11): a partial read must never overwrite a good entry.
    case skipped(String)
}

// MARK: - Codable for AccountIdentity

/// `AccountIdentity` (EXB-5.1) is deliberately not `Codable` at its declaration — it is a
/// runtime resolution result. The roster is the first thing that needs it on disk, so the
/// conformance lives here, written by hand because Swift only synthesizes it in the file that
/// declares the type.
extension AccountIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case key
        case email
        case displayName
        case organizationName
        case accountUUID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(AccountKey.self, forKey: .key),
            email: try container.decode(String.self, forKey: .email),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            organizationName: try container.decodeIfPresent(String.self, forKey: .organizationName),
            accountUUID: try container.decodeIfPresent(String.self, forKey: .accountUUID))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.key, forKey: .key)
        try container.encode(self.email, forKey: .email)
        try container.encodeIfPresent(self.displayName, forKey: .displayName)
        try container.encodeIfPresent(self.organizationName, forKey: .organizationName)
        try container.encodeIfPresent(self.accountUUID, forKey: .accountUUID)
    }
}
