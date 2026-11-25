import CryptoKit
import Foundation

/// Loads Claude OAuth credentials from five sources in strict priority order, with
/// fingerprint-based change detection, and no `SecItem` call anywhere (AC2, AC3, AC4).
///
/// All work runs inside this actor — callers `await`. There are no `@MainActor`
/// annotations and no synchronous I/O on the main thread.
///
/// Priority (AC2):
///   1. env `CLAUDEBAR_OAUTH_TOKEN`            → owner `.environment`
///   2. in-memory cache (TTL 30 min)          → owner from cache
///   3. own cache file (`oauth-cache.json`, 0600) → owner from cache
///   4. file `~/.claude/.credentials.json`    → owner `.claudeCLI`
///   5. keychain `"Claude Code-credentials"`  → owner `.claudeCLI`
///
/// Layer (5/e) reads the Claude keychain item **only** through the trusted `/usr/bin/security`
/// CLI (`.securityCLIPrimary`, the default), which is prompt-free because the Claude CLI's item
/// trusts that binary. The change-detection fingerprint comes from the same CLI without `-w`
/// (attributes only, never the secret). This store never calls `SecItem*` on a third-party item:
/// that path depended on our code signature being in the item's ACL, which it never is.
/// `.securityFramework` is kept as a setting value only and now means "skip layer (e)".
///
/// Layer (3/c) is the app's own cache. It used to be a keychain item that the app deleted and
/// re-added on every fetch; with an ad-hoc signature (a new `cdhash` per build) that write made
/// macOS ask for the login password after every reinstall. It is now a `0600` file
/// (`PrivateFile`). The legacy item is never read, written or deleted again — its 30-minute TTL
/// made it worthless, and touching it is what prompted.
public actor CredentialsStore {
    // MARK: Constants (exact contract strings)

    public static let environmentTokenKey = "CLAUDEBAR_OAUTH_TOKEN"
    public static let credentialsFileRelativePath = ".claude/.credentials.json"
    public static let claudeKeychainService = "Claude Code-credentials"
    /// Service of the pre-file keychain cache. Kept only as a documented constant: nothing reads,
    /// writes or deletes that item any more.
    public static let legacyCacheKeychainService = "com.eximia.eximiabar.cache"
    public static let cacheFileName = "oauth-cache.json"

    /// `~/Library/Application Support/exímIABar` — the same directory as the account roster.
    public static var defaultCacheDirectory: URL { AccountRosterStore.defaultSupportDirectory }

    /// Where layer (c) keeps its cache file. Injectable so tests use a throwaway directory.
    private let cacheFileURL: URL

    private static let memoryCacheTTL: TimeInterval = 1800 // 30 min
    private static let fingerprintThrottle: TimeInterval = 60 // at most once per 60 s
    private static let fileFingerprintDefaultsKey = "ClaudeBarCredentialsFileFingerprintV1"
    private static let keychainFingerprintDefaultsKey = "ClaudeBarClaudeKeychainFingerprintV1"

    /// Internal (not `private`) so the `+SecurityCLI` extension in a sibling file can log.
    let log = CoreLog.logger(CoreLog.Category.credentials)
    private let environment: [String: String]
    private let homeDirectory: URL
    private let defaults: UserDefaults
    /// Reads the *current* keychain prompt policy on every `load` (EXB-1.5 AC11). Never memoized —
    /// a settings change is honoured on the next fetch without rebuilding the store.
    private let promptPolicyProvider: @Sendable () -> PromptPolicy
    /// Whether the system `"Claude Code-credentials"` keychain layer (e) participates.
    /// Defaults to `true`; tests disable it to isolate the deterministic env/file/cache layers.
    private let enableSystemKeychain: Bool
    /// How layer (e) reads the Claude keychain item. Read live on every `load`, like the prompt
    /// policy, so a settings change is honoured on the next fetch without rebuilding the store.
    private let readStrategyProvider: @Sendable () -> KeychainReadStrategy
    /// Where account switches are captured (EXB-5.2 AC4). `nil` disables capture entirely, which
    /// is the default so every existing construction site keeps its exact previous behaviour.
    private let accountRoster: AccountRosterStore?
    /// Resolves who is logged in right now (EXB-5.1). Capture needs both this and the roster;
    /// with either missing it is a no-op.
    private let identityResolver: ClaudeIdentityResolver?

    // MARK: In-memory cache

    private var cachedRecord: ClaudeOAuthCredentialRecord?
    private var cacheTimestamp: Date?
    private var lastFingerprintCheckAt: Date?

    #if DEBUG
    /// Test seam: when set, the `/usr/bin/security` subprocess is not launched and this value
    /// drives the CLI reader's result instead. Mirrors the reference's `securityCLIReadOverride`.
    var securityCLIReadOverride: SecurityCLIReadOverride?

    /// Test seam for the attributes probe (fingerprint). When any CLI override is set and this one
    /// is not, the probe yields "no item" instead of launching the real subprocess.
    var securityCLIAttributesOverride: Data?

    func setSecurityCLIAttributesOverrideForTesting(_ output: Data?) {
        self.securityCLIAttributesOverride = output
    }

    /// Sets the CLI-read override from tests (the property is actor-isolated).
    func setSecurityCLIReadOverrideForTesting(_ override: SecurityCLIReadOverride?) {
        self.securityCLIReadOverride = override
    }

    /// Test seam: lets the next `load` poll instead of waiting out the 60 s throttle. A test that
    /// simulates `claude login` needs two consecutive polls; sleeping a minute for each is not an
    /// option.
    func expireFingerprintThrottleForTesting() {
        self.lastFingerprintCheckAt = nil
    }
    #endif

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        promptPolicy: PromptPolicy = .onUserAction,
        enableSystemKeychain: Bool = true,
        readStrategy: KeychainReadStrategy = .securityCLIPrimary,
        cacheDirectory: URL = CredentialsStore.defaultCacheDirectory,
        accountRoster: AccountRosterStore? = nil,
        identityResolver: ClaudeIdentityResolver? = nil)
    {
        self.init(
            environment: environment,
            homeDirectory: homeDirectory,
            defaults: defaults,
            promptPolicyProvider: { promptPolicy },
            enableSystemKeychain: enableSystemKeychain,
            readStrategyProvider: { readStrategy },
            cacheDirectory: cacheDirectory,
            accountRoster: accountRoster,
            identityResolver: identityResolver)
    }

    /// Designated initializer (EXB-1.5 AC11). The `promptPolicyProvider` and `readStrategyProvider`
    /// are read on every `load`, so a live `SettingsStore` change takes effect on the next fetch
    /// with no memoization.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        promptPolicyProvider: @escaping @Sendable () -> PromptPolicy,
        enableSystemKeychain: Bool = true,
        readStrategyProvider: @escaping @Sendable () -> KeychainReadStrategy = { .securityCLIPrimary },
        cacheDirectory: URL = CredentialsStore.defaultCacheDirectory,
        accountRoster: AccountRosterStore? = nil,
        identityResolver: ClaudeIdentityResolver? = nil)
    {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.defaults = defaults
        self.promptPolicyProvider = promptPolicyProvider
        self.enableSystemKeychain = enableSystemKeychain
        self.readStrategyProvider = readStrategyProvider
        self.cacheFileURL = cacheDirectory.appendingPathComponent(Self.cacheFileName)
        self.accountRoster = accountRoster
        self.identityResolver = identityResolver
    }

    // MARK: Public API

    /// Loads the best available credential record. No phase ever raises a keychain prompt: layer
    /// (e) reads the Claude keychain only via the trusted `/usr/bin/security` CLI (prompt-free), and
    /// layer (c) is a plain `0600` file. `phase` is retained
    /// for call-site provenance (and 429-gate / notification decisions upstream).
    public func load(phase: RefreshPhase = .background) async throws -> ClaudeOAuthCredentialRecord {
        // Throttled fingerprint poll → capture the account switch, then invalidate caches (AC3,
        // EXB-5.2 AC4.11 — that order is load-bearing).
        // Sample the live strategy once per load (never memoized, AC11): the fingerprint probe and
        // layer (e) must agree on it, and `.securityFramework` keeps both off the keychain.
        let strategy = self.enableSystemKeychain ? self.readStrategyProvider() : nil
        await self.pollFingerprintsAndInvalidateIfChanged(strategy: strategy)

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

        // (c) own cache file
        if self.enableSystemKeychain,
           let record = self.loadFromCacheFile(), !record.credentials.isExpired
        {
            self.storeInMemory(record)
            return record
        }

        // (d) credentials file
        if let record = try self.loadFromFile() {
            self.storeInMemory(record)
            if self.enableSystemKeychain { self.saveToCacheFile(record) }
            return record
        }

        // (e) system keychain "Claude Code-credentials"
        if let strategy {
            if let record = try self.loadFromClaudeKeychain(strategy: strategy) {
                self.storeInMemory(record)
                self.saveToCacheFile(record)
                return record
            }
        }

        throw ClaudeOAuthCredentialsError.notFound
    }

    /// Drops the in-memory and file caches (used after a successful delegated refresh).
    public func invalidateCaches() {
        self.cachedRecord = nil
        self.cacheTimestamp = nil
        self.clearCacheFile()
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

    // MARK: (c) Own cache file

    private func loadFromCacheFile() -> ClaudeOAuthCredentialRecord? {
        guard let data = PrivateFile.read(self.cacheFileURL) else { return nil }
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.memoryCacheTTL else { return nil }
        guard let credentials = try? ClaudeOAuthCredentials.parse(data: entry.credentialsData)
        else { return nil }
        return ClaudeOAuthCredentialRecord(
            credentials: credentials,
            owner: entry.owner,
            source: .cacheKeychain)
    }

    private func saveToCacheFile(_ record: ClaudeOAuthCredentialRecord) {
        guard let credentialsData = self.serializeCredentials(record.credentials) else { return }
        let entry = CacheEntry(
            credentialsData: credentialsData,
            storedAt: Date(),
            owner: record.owner)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try PrivateFile.write(data, to: self.cacheFileURL)
        } catch {
            self.log.warning("Could not write the OAuth cache file")
        }
    }

    private func clearCacheFile() {
        PrivateFile.remove(self.cacheFileURL)
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

    /// Reads the Claude item **only** via `/usr/bin/security`. There is deliberately no
    /// `SecItem` fallback: the item belongs to the Claude CLI and its ACL never lists us, so a
    /// framework read could at best fail and at worst prompt. `.securityFramework` skips the layer.
    private func loadFromClaudeKeychain(strategy: KeychainReadStrategy) throws -> ClaudeOAuthCredentialRecord? {
        #if os(macOS)
        guard strategy == .securityCLIPrimary else { return nil }
        // Refresh the fingerprint baseline from the attribute-only CLI probe (AC3).
        self.persistKeychainFingerprint(self.claudeKeychainFingerprint())
        guard let credentials = self.loadFromClaudeKeychainViaSecurityCLI() else { return nil }
        return ClaudeOAuthCredentialRecord(
            credentials: credentials,
            owner: .claudeCLI,
            source: .claudeKeychain)
        #else
        return nil
        #endif
    }

    // MARK: Fingerprint polling (AC3)

    /// Throttled (≤ once / 60 s). Captures the current account into the roster and, on a change
    /// to the file or keychain fingerprint, drops the in-memory and keychain caches.
    private func pollFingerprintsAndInvalidateIfChanged(strategy: KeychainReadStrategy?) async {
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
        if strategy == .securityCLIPrimary {
            let currentKeychain = self.claudeKeychainFingerprint()
            let storedKeychain = self.defaults.string(forKey: Self.keychainFingerprintDefaultsKey)
            if currentKeychain != storedKeychain {
                changed = true
            }
        }
        #endif

        // EXB-5.2 AC4.11 — ORDER IS LOAD-BEARING. The credentials of the account we are leaving
        // live only in the caches this method is about to drop. Capture first, invalidate after;
        // the other way round the archive would silently record nothing.
        await self.captureAccountIntoRoster()

        if changed {
            self.log.debug("Credential fingerprint changed — invalidating caches")
            self.cachedRecord = nil
            self.cacheTimestamp = nil
            self.clearCacheFile()
        }
    }

    /// Feeds the account roster (EXB-5.2 AC4). Runs on every poll, not only on a change, so the
    /// live account is already on record before the switch that archives it happens.
    ///
    /// R11 (AC4.12): archiving garbage is worse than missing one cycle. Nothing is written
    /// unless the previous credentials **and** the identity resolution both succeeded — a
    /// half-written `.credentials.json` simply waits for the next poll, 60 s later.
    private func captureAccountIntoRoster() async {
        guard let accountRoster = self.accountRoster,
              let identityResolver = self.identityResolver
        else { return }
        guard let previous = self.cachedRecord?.credentials else { return }
        guard let identity = await identityResolver
            .resolve(accessToken: previous.accessToken)
        else { return }

        await accountRoster.captureIfIdentityChanged(
            current: identity,
            credentials: previous)
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
