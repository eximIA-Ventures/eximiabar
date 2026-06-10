import CryptoKit
import Foundation

#if os(macOS)
import LocalAuthentication
import Security
#endif

/// Loads Claude OAuth credentials from five sources in strict priority order, with
/// fingerprint-based change detection and a no-UI keychain read path (AC2, AC3, AC4).
///
/// All work runs inside this actor — callers `await`. There are no `@MainActor`
/// annotations and no synchronous I/O on the main thread.
///
/// Priority (AC2):
///   1. env `CLAUDEBAR_OAUTH_TOKEN`            → owner `.environment`
///   2. in-memory cache (TTL 30 min)          → owner from cache
///   3. keychain cache (own service/account)  → owner from cache
///   4. file `~/.claude/.credentials.json`    → owner `.claudeCLI`
///   5. keychain `"Claude Code-credentials"`  → owner `.claudeCLI`
public actor CredentialsStore {
    // MARK: Constants (exact contract strings)

    public static let environmentTokenKey = "CLAUDEBAR_OAUTH_TOKEN"
    public static let credentialsFileRelativePath = ".claude/.credentials.json"
    public static let claudeKeychainService = "Claude Code-credentials"
    public static let cacheKeychainService = "com.eximia.eximiabar.cache"
    public static let cacheKeychainAccount = "oauth.claude"

    private static let memoryCacheTTL: TimeInterval = 1800 // 30 min
    private static let fingerprintThrottle: TimeInterval = 60 // at most once per 60 s
    private static let fileFingerprintDefaultsKey = "ClaudeBarCredentialsFileFingerprintV1"
    private static let keychainFingerprintDefaultsKey = "ClaudeBarClaudeKeychainFingerprintV1"

    private let log = CoreLog.logger(CoreLog.Category.credentials)
    private let environment: [String: String]
    private let homeDirectory: URL
    private let defaults: UserDefaults
    private let promptPolicy: PromptPolicy
    /// Whether the system `"Claude Code-credentials"` keychain layer (e) participates.
    /// Defaults to `true`; tests disable it to isolate the deterministic env/file/cache layers.
    private let enableSystemKeychain: Bool

    // MARK: In-memory cache

    private var cachedRecord: ClaudeOAuthCredentialRecord?
    private var cacheTimestamp: Date?
    private var lastFingerprintCheckAt: Date?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        promptPolicy: PromptPolicy = .onUserAction,
        enableSystemKeychain: Bool = true)
    {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.defaults = defaults
        self.promptPolicy = promptPolicy
        self.enableSystemKeychain = enableSystemKeychain
    }

    // MARK: Public API

    /// Loads the best available credential record. Background phase never prompts; a
    /// prompt is only possible when `promptPolicy == .onUserAction` AND `phase == .userInitiated`.
    public func load(phase: RefreshPhase = .background) throws -> ClaudeOAuthCredentialRecord {
        // Throttled fingerprint poll → invalidate caches on change (AC3).
        self.pollFingerprintsAndInvalidateIfChanged()

        // (a) environment
        if let credentials = self.loadFromEnvironment() {
            return ClaudeOAuthCredentialRecord(
                credentials: credentials,
                owner: .environment,
                source: .environment)
        }

        // (b) in-memory cache (TTL 30 min)
        if let cachedRecord, let cacheTimestamp,
           Date().timeIntervalSince(cacheTimestamp) < Self.memoryCacheTTL,
           !cachedRecord.credentials.isExpired
        {
            return ClaudeOAuthCredentialRecord(
                credentials: cachedRecord.credentials,
                owner: cachedRecord.owner,
                source: .memoryCache)
        }

        // (c) keychain cache
        if self.enableSystemKeychain,
           let record = self.loadFromCacheKeychain(), !record.credentials.isExpired
        {
            self.storeInMemory(record)
            return record
        }

        // (d) credentials file
        if let record = try self.loadFromFile() {
            self.storeInMemory(record)
            if self.enableSystemKeychain { self.saveToCacheKeychain(record) }
            return record
        }

        // (e) system keychain "Claude Code-credentials"
        if self.enableSystemKeychain {
            let allowPrompt = self.promptPolicy == .onUserAction && phase == .userInitiated
            if let record = try self.loadFromClaudeKeychain(allowPrompt: allowPrompt) {
                self.storeInMemory(record)
                self.saveToCacheKeychain(record)
                return record
            }
        }

        throw ClaudeOAuthCredentialsError.notFound
    }

    /// Drops in-memory and keychain caches (used after a successful delegated refresh).
    public func invalidateCaches() {
        self.cachedRecord = nil
        self.cacheTimestamp = nil
        self.clearCacheKeychain()
    }

    // MARK: (a) Environment

    private func loadFromEnvironment() -> ClaudeOAuthCredentials? {
        guard let token = self.environment[Self.environmentTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return nil }
        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil,
            subscriptionType: nil)
    }

    // MARK: (d) File

    private var credentialsFileURL: URL {
        self.homeDirectory.appendingPathComponent(Self.credentialsFileRelativePath)
    }

    private func loadFromFile() throws -> ClaudeOAuthCredentialRecord? {
        let url = self.credentialsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ClaudeOAuthCredentialsError.readFailed(error.localizedDescription)
        }
        let credentials = try ClaudeOAuthCredentials.parse(data: data)
        // Refresh the stored file fingerprint baseline on a successful read.
        self.persistFileFingerprint(self.currentFileFingerprint())
        return ClaudeOAuthCredentialRecord(
            credentials: credentials,
            owner: .claudeCLI,
            source: .credentialsFile)
    }

    // MARK: (c) Own keychain cache

    private func loadFromCacheKeychain() -> ClaudeOAuthCredentialRecord? {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheKeychainService,
            kSecAttrAccount as String: Self.cacheKeychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.memoryCacheTTL else { return nil }
        guard let credentials = try? ClaudeOAuthCredentials.parse(data: entry.credentialsData)
        else { return nil }
        return ClaudeOAuthCredentialRecord(
            credentials: credentials,
            owner: entry.owner,
            source: .cacheKeychain)
        #else
        return nil
        #endif
    }

    private func saveToCacheKeychain(_ record: ClaudeOAuthCredentialRecord) {
        #if os(macOS)
        guard let credentialsData = self.serializeCredentials(record.credentials) else { return }
        let entry = CacheEntry(
            credentialsData: credentialsData,
            storedAt: Date(),
            owner: record.owner)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheKeychainService,
            kSecAttrAccount as String: Self.cacheKeychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }

    private func clearCacheKeychain() {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheKeychainService,
            kSecAttrAccount as String: Self.cacheKeychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    private func serializeCredentials(_ credentials: ClaudeOAuthCredentials) -> Data? {
        // Re-emit in the `.credentials.json` shape so the cache round-trips through parse().
        var oauth: [String: Any] = ["accessToken": credentials.accessToken]
        if let refreshToken = credentials.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = credentials.expiresAt {
            oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000.0
        }
        oauth["scopes"] = credentials.scopes
        if let rateLimitTier = credentials.rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    private struct CacheEntry: Codable {
        let credentialsData: Data
        let storedAt: Date
        let owner: CredentialOwner
    }

    // MARK: (e) System keychain "Claude Code-credentials"

    private func loadFromClaudeKeychain(allowPrompt: Bool) throws -> ClaudeOAuthCredentialRecord? {
        #if os(macOS)
        guard let candidate = self.newestClaudeKeychainCandidate() else { return nil }

        // Persist the keychain fingerprint baseline (AC3).
        self.persistKeychainFingerprint(self.keychainFingerprint(for: candidate))

        guard let data = try self.readKeychainData(
            persistentRef: candidate.persistentRef,
            allowPrompt: allowPrompt)
        else { return nil }

        let credentials = try ClaudeOAuthCredentials.parse(data: data)
        return ClaudeOAuthCredentialRecord(
            credentials: credentials,
            owner: .claudeCLI,
            source: .claudeKeychain)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private struct KeychainCandidate {
        let persistentRef: Data
        let modifiedAt: Date?
        let createdAt: Date?
    }

    /// Probes the system keychain with `kSecMatchLimitAll` + `kSecReturnPersistentRef`
    /// under a no-UI policy, returning the most-recently-modified item (AC4).
    private func newestClaudeKeychainCandidate() -> KeychainCandidate? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed
            || status == errSecNoAccessForItem
        {
            ClaudeOAuthKeychainAccessGate.recordDenied()
        }
        guard status == errSecSuccess, let rows = result as? [[String: Any]], !rows.isEmpty
        else { return nil }

        let candidates: [KeychainCandidate] = rows.compactMap { row in
            guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return KeychainCandidate(
                persistentRef: persistentRef,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date)
        }
        return candidates.sorted { lhs, rhs in
            let l = lhs.modifiedAt ?? lhs.createdAt ?? .distantPast
            let r = rhs.modifiedAt ?? rhs.createdAt ?? .distantPast
            return l > r
        }.first
    }

    /// Reads the secret bytes for a candidate via its persistent ref. Background reads
    /// (`allowPrompt == false`) apply the no-UI policy; prompting reads do not.
    private func readKeychainData(persistentRef: Data, allowPrompt: Bool) throws -> Data? {
        // Honor the keychain prompt cooldown for prompting reads.
        if allowPrompt, !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt() {
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: persistentRef,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }

    private func keychainFingerprint(for candidate: KeychainCandidate) -> String {
        let modified = candidate.modifiedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        let created = candidate.createdAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        let refHash = Self.sha256Prefix(candidate.persistentRef)
        return "\(modified):\(created):\(refHash)"
    }
    #endif

    // MARK: Fingerprint polling (AC3)

    /// Throttled (≤ once / 60 s). On a change to the file or keychain fingerprint, drops
    /// the in-memory and keychain caches.
    private func pollFingerprintsAndInvalidateIfChanged() {
        let now = Date()
        if let last = self.lastFingerprintCheckAt,
           now.timeIntervalSince(last) < Self.fingerprintThrottle
        {
            return
        }
        self.lastFingerprintCheckAt = now

        var changed = false

        let currentFile = self.currentFileFingerprint()
        let storedFile = self.defaults.string(forKey: Self.fileFingerprintDefaultsKey)
        if currentFile != storedFile {
            changed = true
        }

        #if os(macOS)
        if self.enableSystemKeychain {
            let currentKeychain = self.newestClaudeKeychainCandidate()
                .map { self.keychainFingerprint(for: $0) }
            let storedKeychain = self.defaults.string(forKey: Self.keychainFingerprintDefaultsKey)
            if currentKeychain != storedKeychain {
                changed = true
            }
        }
        #endif

        if changed {
            self.log.debug("Credential fingerprint changed — invalidating caches")
            self.cachedRecord = nil
            self.cacheTimestamp = nil
            self.clearCacheKeychain()
        }
    }

    /// File fingerprint = (mtime ms, size), serialized as a string (AC3).
    private func currentFileFingerprint() -> String? {
        let url = self.credentialsFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtimeMs = (attrs[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return "\(mtimeMs):\(size)"
    }

    private func persistFileFingerprint(_ fingerprint: String?) {
        if let fingerprint {
            self.defaults.set(fingerprint, forKey: Self.fileFingerprintDefaultsKey)
        } else {
            self.defaults.removeObject(forKey: Self.fileFingerprintDefaultsKey)
        }
    }

    private func persistKeychainFingerprint(_ fingerprint: String?) {
        if let fingerprint {
            self.defaults.set(fingerprint, forKey: Self.keychainFingerprintDefaultsKey)
        } else {
            self.defaults.removeObject(forKey: Self.keychainFingerprintDefaultsKey)
        }
    }

    // MARK: Cache helpers

    private func storeInMemory(_ record: ClaudeOAuthCredentialRecord) {
        self.cachedRecord = record
        self.cacheTimestamp = Date()
    }

    // MARK: Hashing

    static func sha256Prefix(_ data: Data) -> String {
        // Lightweight, dependency-free SHA-256 prefix for fingerprinting.
        let hash = SHA256.hash(data: data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
