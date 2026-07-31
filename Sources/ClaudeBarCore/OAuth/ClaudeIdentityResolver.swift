import Foundation

/// Resolves the identity of the Claude account currently logged in, from `~/.claude.json`
/// (EXB-5.1 AC2, AC3).
///
/// `~/.claude.json` is the Claude Code CLI's own config: an **undocumented** ~45 KB JSON file,
/// mode `0600`, plain text, no keychain and no prompt. Its `oauthAccount` object is the only
/// place the account's e-mail is observable (`emailAddress`, `accountUuid`, `displayName`,
/// `organizationName`).
///
/// Two properties follow from that, and both are load-bearing:
///
/// - **Fingerprint gate.** The file is re-read only when its `(mtime, size)` fingerprint
///   changes — same contract as `CredentialsStore.pollFingerprintsAndInvalidateIfChanged`
///   (`CredentialsStore.swift:429`). A 60 s refresh cycle must never re-parse 45 KB.
/// - **Tolerant decode.** Only `oauthAccount` is extracted; every other top-level key is
///   ignored, and a missing or malformed object degrades to the opaque fallback (R12) instead
///   of failing.
///
/// All I/O happens inside this actor, so callers `await` and nothing touches the main thread (I1).
public actor ClaudeIdentityResolver {
    public static let configFileRelativePath = ".claude.json"

    private let homeDirectory: URL
    private let log = CoreLog.logger(CoreLog.Category.credentials)

    // MARK: Fingerprint-gated cache

    private var cachedFingerprint: String?
    private var cachedIdentity: AccountIdentity?
    private var hasCachedResult = false

    /// Ordinals handed out to opaque (e-mail-less) identifiers, in discovery order — the `N`
    /// of the `"Conta N"` label required by AC3.
    private var opaqueOrdinals: [String: Int] = [:]

    /// How many times the config file has actually been read and decoded.
    ///
    /// The fingerprint gate is otherwise invisible from the outside: two `resolve` calls look
    /// identical whether or not the 45 KB file was re-parsed. This counter is the only way to
    /// assert the gate holds, so it is part of the public surface on purpose.
    public private(set) var parseCount = 0

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public nonisolated var configFileURL: URL {
        self.homeDirectory.appendingPathComponent(Self.configFileRelativePath)
    }

    // MARK: Public API

    /// Resolves the current account identity.
    ///
    /// - Parameter accessToken: the live access token, used only to derive the opaque fallback
    ///   key when `oauthAccount` yields no e-mail (AC3). Pass `nil` to skip the fallback.
    /// - Returns: the resolved identity, or `nil` when neither an e-mail nor a token is available.
    public func resolve(accessToken: String? = nil) -> AccountIdentity? {
        if let identity = self.identityFromConfigFile() { return identity }
        return self.fallbackIdentity(accessToken: accessToken)
    }

    // MARK: Config file (AC2)

    private func identityFromConfigFile() -> AccountIdentity? {
        let fingerprint = self.currentFingerprint()
        if self.hasCachedResult, fingerprint == self.cachedFingerprint {
            return self.cachedIdentity
        }
        self.cachedFingerprint = fingerprint
        self.hasCachedResult = true
        self.cachedIdentity = self.parseIdentity()
        return self.cachedIdentity
    }

    private func parseIdentity() -> AccountIdentity? {
        guard let data = try? Data(contentsOf: self.configFileURL) else { return nil }
        self.parseCount += 1

        guard let account = try? JSONDecoder()
            .decode(ClaudeConfigEnvelope.self, from: data).oauthAccount
        else {
            self.log.debug("~/.claude.json has no decodable oauthAccount — falling back")
            return nil
        }

        let email = account.emailAddress.map(AccountKey.normalize) ?? ""
        guard !email.isEmpty else { return nil }

        return AccountIdentity(
            key: AccountKey(provider: .claude, identifier: email),
            email: email,
            displayName: Self.nonEmpty(account.displayName),
            organizationName: Self.nonEmpty(account.organizationName),
            accountUUID: Self.nonEmpty(account.accountUuid))
    }

    /// File fingerprint = (mtime ms, size) — mirrors `CredentialsStore.currentFileFingerprint`.
    private func currentFingerprint() -> String? {
        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: self.configFileURL.path)
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtimeMs = (attrs[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return "\(mtimeMs):\(size)"
    }

    // MARK: Opaque fallback (AC3 / R12)

    private func fallbackIdentity(accessToken: String?) -> AccountIdentity? {
        guard let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        let identifier = CredentialsStore.sha256Prefix(Data(token.utf8))
        return AccountIdentity(
            key: AccountKey(provider: .claude, identifier: identifier),
            email: "",
            displayName: "Conta \(self.ordinal(for: identifier))",
            organizationName: nil,
            accountUUID: nil)
    }

    private func ordinal(for identifier: String) -> Int {
        if let known = self.opaqueOrdinals[identifier] { return known }
        let next = self.opaqueOrdinals.count + 1
        self.opaqueOrdinals[identifier] = next
        return next
    }

    // MARK: Helpers

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

// MARK: - Tolerant decoding (AC2.5)

/// Extracts **only** `oauthAccount`; every other key of the ~45 KB config is ignored, and a
/// malformed `oauthAccount` decodes to `nil` rather than throwing (R12).
private struct ClaudeConfigEnvelope: Decodable {
    let oauthAccount: ClaudeOAuthAccountPayload?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard let key = DynamicCodingKey(stringValue: "oauthAccount") else {
            self.oauthAccount = nil
            return
        }
        self.oauthAccount = try? container.decodeIfPresent(
            ClaudeOAuthAccountPayload.self,
            forKey: key)
    }
}

/// The observed shape of `oauthAccount`. Every field is optional — the file is undocumented
/// and may drop or rename any of them without notice.
private struct ClaudeOAuthAccountPayload: Decodable {
    let emailAddress: String?
    let accountUuid: String?
    let displayName: String?
    let organizationName: String?
}
