import Foundation

#if os(macOS)
import Security
#endif

/// The local roster of accounts the app has seen, persisted in two layers (EXB-5.2 AC2).
///
/// **Layer 1 — index (metadata).** `[AccountRosterEntry]` as JSON in
/// `~/Library/Application Support/exímIABar/accounts.json`, mode `0600`. Enumerable and
/// readable with **no keychain access at all**, which is what keeps the switcher cheap.
///
/// **Layer 2 — secret.** Only for `.archived` accounts, one generic-password item per account
/// in this store's own keychain service. The payload is `ArchivedToken`: access token plus
/// expiry, nothing more (decision D-A).
///
/// The keychain service is injectable, and that is not a nicety. `CredentialsStore.swift:36-40`
/// documents the root cause of the keychain Allow/Deny pop-up that EXB-3.8 spent a whole wave
/// killing: the test process touching the real keychain item. This store inherits that seam
/// from its first commit so the same bug cannot be reintroduced through a new service.
///
/// A plain `actor`: no main-actor annotation anywhere, all file and keychain I/O behind
/// `await` (AC6 / R10).
public actor AccountRosterStore {
    // MARK: Constants (exact contract strings)

    public static let indexDirectoryName = "exímIABar"
    public static let indexFileName = "accounts.json"
    public static let keychainService = "com.eximia.eximiabar.accounts"

    /// Decision D-B: the roster holds at most 8 accounts; the 9th evicts the least recently
    /// seen one (LRU by `lastSeenAt`), secret included.
    public static let maxEntries = 8

    private static let indexFilePermissions: NSNumber = 0o600
    private static let indexDirectoryPermissions: NSNumber = 0o700

    // MARK: State

    private let indexFileURL: URL
    private let keychainService: String
    private let log = CoreLog.logger(CoreLog.Category.credentials)

    private var entries: [AccountRosterEntry] = []
    private var hasLoaded = false

    public init(
        supportDirectory: URL = AccountRosterStore.defaultSupportDirectory,
        keychainService: String = AccountRosterStore.keychainService)
    {
        self.indexFileURL = supportDirectory.appendingPathComponent(Self.indexFileName)
        self.keychainService = keychainService
    }

    /// `~/Library/Application Support/exímIABar` — the production index location.
    public static var defaultSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Self.indexDirectoryName)
    }

    /// Where this instance writes its index. Exposed so tests can assert isolation.
    public nonisolated var indexURL: URL { self.indexFileURL }

    /// The keychain service this instance uses. Exposed so tests can prove they are not on the
    /// production one.
    public nonisolated var activeKeychainService: String { self.keychainService }

    // MARK: Public API

    /// The whole roster, most recently seen first. Reads the index only, never the keychain.
    public func roster() -> [AccountRosterEntry] {
        self.loadIfNeeded()
        return self.entries.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// The archived secret of one account, read on demand. Returns `nil` for a live account —
    /// a live account's token belongs to the CLI, not to us.
    public func archivedToken(for key: AccountKey) -> ArchivedToken? {
        self.loadIfNeeded()
        guard let entry = self.entries.first(where: { $0.key == key }),
              entry.lifecycle == .archived
        else { return nil }
        return self.readSecret(for: key)
    }

    /// Records `current` as the live account, archiving the one we are switching away from.
    ///
    /// - Parameters:
    ///   - current: the identity resolved **now** (i.e. after `claude login` rewrote its config).
    ///   - credentials: the credentials still in hand at call time. On a switch these belong to
    ///     the account being left behind — which is exactly what gets archived, and why the
    ///     caller must invoke this **before** dropping its caches (AC4.11).
    ///
    /// R11: an empty access token means the caller read a half-written file. That is a no-op,
    /// never a partial overwrite — the next poll (60 s later) tries again.
    @discardableResult
    public func captureIfIdentityChanged(
        current: AccountIdentity,
        credentials: ClaudeOAuthCredentials) -> CaptureOutcome
    {
        self.loadIfNeeded()

        let accessToken = credentials.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return .skipped("empty access token — partial read, nothing written (R11)")
        }

        let now = Date()

        guard let live = self.liveEntry(provider: current.key.provider) else {
            // First observation of this provider: nothing to archive yet.
            self.putLive(
                current,
                plan: credentials.subscriptionType,
                tokenExpiresAt: credentials.expiresAt,
                capturedAt: now,
                now: now)
            self.persist()
            return .captured(archived: nil, live: current.key)
        }

        guard live.key != current.key else {
            self.putLive(
                current,
                plan: credentials.subscriptionType ?? live.plan,
                tokenExpiresAt: credentials.expiresAt,
                capturedAt: live.capturedAt,
                now: now)
            self.persist()
            return .unchanged(current.key)
        }

        // A real switch. Archive the account we are leaving, using the credentials that are
        // still in hand — after the caller invalidates its caches they no longer exist anywhere.
        self.archive(
            live,
            token: ArchivedToken(accessToken: accessToken, expiresAt: credentials.expiresAt),
            now: now)
        // The credentials at hand belong to the *previous* account, so the plan and expiry of
        // the incoming one are unknown until the next successful load.
        self.putLive(
            current,
            plan: nil,
            tokenExpiresAt: nil,
            capturedAt: self.entries.first { $0.key == current.key }?.capturedAt ?? now,
            now: now)
        self.persist()
        return .captured(archived: live.key, live: current.key)
    }

    /// Forgets one account entirely: index row and archived secret.
    public func remove(_ key: AccountKey) {
        self.loadIfNeeded()
        guard self.entries.contains(where: { $0.key == key }) else { return }
        self.entries.removeAll { $0.key == key }
        self.deleteSecret(for: key)
        self.persist()
    }

    // MARK: Roster mutation

    private func liveEntry(provider: Provider) -> AccountRosterEntry? {
        self.entries.first { $0.lifecycle == .live && $0.key.provider == provider }
    }

    private func putLive(
        _ identity: AccountIdentity,
        plan: String?,
        tokenExpiresAt: Date?,
        capturedAt: Date,
        now: Date)
    {
        // At most one account per provider is live: the only caller archives the outgoing one
        // before getting here.
        self.upsert(AccountRosterEntry(
            identity: identity,
            lifecycle: .live,
            plan: plan,
            capturedAt: capturedAt,
            lastSeenAt: now,
            tokenExpiresAt: tokenExpiresAt))
        // A live account's token belongs to the CLI — we hold no copy of it.
        self.deleteSecret(for: identity.key)
    }

    private func archive(_ entry: AccountRosterEntry, token: ArchivedToken, now: Date) {
        self.upsert(AccountRosterEntry(
            identity: entry.identity,
            lifecycle: .archived,
            plan: entry.plan,
            capturedAt: entry.capturedAt,
            lastSeenAt: now,
            tokenExpiresAt: token.expiresAt))
        self.writeSecret(token, for: entry.key)
    }

    private func upsert(_ entry: AccountRosterEntry) {
        if let index = self.entries.firstIndex(where: { $0.key == entry.key }) {
            self.entries[index] = entry
            return
        }
        self.evictUntilRoomForOneMore()
        self.entries.append(entry)
    }

    /// Decision D-B: hard ceiling of 8, LRU by `lastSeenAt`.
    private func evictUntilRoomForOneMore() {
        while self.entries.count >= Self.maxEntries {
            guard let oldest = self.entries
                .min(by: { $0.lastSeenAt < $1.lastSeenAt })
            else { return }
            self.log.debug("Roster full — evicting least recently seen account")
            self.entries.removeAll { $0.key == oldest.key }
            self.deleteSecret(for: oldest.key)
        }
    }

    // MARK: Index file (layer 1)

    private func loadIfNeeded() {
        guard !self.hasLoaded else { return }
        self.hasLoaded = true
        guard let data = try? Data(contentsOf: self.indexFileURL) else { return }
        guard let decoded = try? Self.decoder.decode([AccountRosterEntry].self, from: data) else {
            self.log.debug("accounts.json is unreadable — starting from an empty roster")
            return
        }
        self.entries = decoded
    }

    private func persist() {
        let directory = self.indexFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.indexDirectoryPermissions])
            let data = try Self.encoder.encode(self.entries)
            try data.write(to: self.indexFileURL, options: .atomic)
            // An atomic write replaces the inode, so the mode comes from the umask — re-apply
            // `0600` on every write, not just on creation (AC2.3).
            try FileManager.default.setAttributes(
                [.posixPermissions: Self.indexFilePermissions],
                ofItemAtPath: self.indexFileURL.path)
        } catch {
            self.log.error("Failed to persist the account roster index")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Keychain (layer 2)

    /// `"{provider}:{identifier}"` — the account attribute of the keychain item (AC2.4).
    static func keychainAccount(for key: AccountKey) -> String {
        "\(key.provider.rawValue):\(key.identifier)"
    }

    private func readSecret(for key: AccountKey) -> ArchivedToken? {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount(for: key),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? Self.decoder.decode(ArchivedToken.self, from: data)
        #else
        return nil
        #endif
    }

    private func writeSecret(_ token: ArchivedToken, for key: AccountKey) {
        #if os(macOS)
        guard let data = try? Self.encoder.encode(token) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount(for: key),
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // This device only, never synchronized to iCloud (AC2.4).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            self.log.error("Could not store the archived account secret (OSStatus \(status))")
        }
        #endif
    }

    private func deleteSecret(for key: AccountKey) {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount(for: key),
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
