import Foundation

/// Which upstream account provider an identity belongs to (EXB-5.1 AC1).
///
/// `.codex` is declared here — and only here — so that `EXB-5.4` can build its own
/// `AccountKey` without introducing a second, divergent provider enum.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// The stable, comparable key of one account of one provider (EXB-5.1 AC1).
///
/// `identifier` is the **normalized** e-mail (lowercase + trimmed). When the provider gives
/// us no e-mail at all, the resolver substitutes an opaque token digest (R12 fallback) — the
/// key stays usable for comparison and indexing either way.
public struct AccountKey: Hashable, Codable, Sendable {
    public let provider: Provider
    public let identifier: String

    public init(provider: Provider, identifier: String) {
        self.provider = provider
        self.identifier = identifier
    }

    /// The single normalization rule for identifiers: trim, then lowercase.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The resolved identity of an account (EXB-5.1 AC1).
///
/// Distinct from `UsageSnapshot.Identity` on purpose: this is the *roster* type consumed by
/// `EXB-5.2` / `EXB-5.4`, while `UsageSnapshot.Identity` is the display shape the popover
/// header already reads. The wiring between them is a mapping, never a substitution (AC4.9).
public struct AccountIdentity: Sendable, Equatable {
    public let key: AccountKey
    public let email: String
    public let displayName: String?
    public let organizationName: String?
    public let accountUUID: String?

    public init(
        key: AccountKey,
        email: String,
        displayName: String? = nil,
        organizationName: String? = nil,
        accountUUID: String? = nil)
    {
        self.key = key
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.accountUUID = accountUUID
    }

    /// `false` when this identity came from the opaque R12 fallback (no e-mail known).
    public var hasResolvedEmail: Bool { !self.email.isEmpty }
}
