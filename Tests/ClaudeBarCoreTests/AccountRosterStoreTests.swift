import Foundation
import Testing
@testable import ClaudeBarCore

#if os(macOS)
import Security
#endif

/// EXB-5.2 — account roster: capture on login, read-only persistence.
///
/// Every test writes its index into a throwaway `tmp` directory and pins its own keychain
/// service (`com.eximia.eximiabar.accounts.test.<uuid>`), so neither the real
/// `~/Library/Application Support/exímIABar/accounts.json` nor the production keychain service
/// is ever touched — the seam `CredentialsStore.swift:36-40` documents, inherited here from the
/// first commit.
struct AccountRosterStoreTests {
    // MARK: Fixtures

    /// A store on a fresh temp directory and a fresh keychain service.
    private func makeStore() -> (store: AccountRosterStore, directory: URL, service: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-roster-\(UUID().uuidString)")
        let service = "com.eximia.eximiabar.accounts.test.\(UUID().uuidString)"
        return (AccountRosterStore(supportDirectory: directory, keychainService: service),
                directory,
                service)
    }

    private func cleanUp(directory: URL, service: String) {
        try? FileManager.default.removeItem(at: directory)
        #if os(macOS)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        #endif
    }

    private func identity(_ email: String) -> AccountIdentity {
        AccountIdentity(
            key: AccountKey(provider: .claude, identifier: email),
            email: email,
            displayName: email,
            organizationName: "Acme",
            accountUUID: UUID().uuidString)
    }

    private func credentials(
        accessToken: String,
        expiresAt: Date? = Date(timeIntervalSince1970: 4_102_444_800),
        plan: String? = "max") -> ClaudeOAuthCredentials
    {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: "renewal-secret-that-must-never-be-archived",
            expiresAt: expiresAt,
            scopes: ["user:profile"],
            rateLimitTier: nil,
            subscriptionType: plan)
    }

    /// The repository root, derived from this file's own path.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    // MARK: AC1 / AC2 — index shape and persistence

    @Test
    func firstCaptureRecordsTheAccountAsLive() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        let outcome = await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))

        #expect(outcome == .captured(archived: nil, live: AccountKey(provider: .claude, identifier: "a@example.com")))
        let roster = await store.roster()
        #expect(roster.count == 1)
        #expect(roster[0].lifecycle == .live)
        #expect(roster[0].plan == "max")
        // A live account's token belongs to the CLI — we keep no copy of it.
        #expect(await store.archivedToken(for: roster[0].key) == nil)
    }

    @Test
    func indexRoundTripsThroughDiskAcrossStoreInstances() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "token-a"))

        // A brand-new instance over the same directory must see the same roster.
        let reopened = AccountRosterStore(supportDirectory: directory, keychainService: service)
        let roster = await reopened.roster()
        #expect(roster.count == 2)
        #expect(roster.first { $0.key.identifier == "b@example.com" }?.lifecycle == .live)
        #expect(roster.first { $0.key.identifier == "a@example.com" }?.lifecycle == .archived)
    }

    @Test
    func indexFileIsMode0600() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))

        let path = store.indexURL.path
        #expect(path.hasSuffix("/accounts.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }

    @Test
    func indexFileNeverContainsSecrets() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "sk-ant-oat01-SECRET-A"))
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "sk-ant-oat01-SECRET-A"))

        let contents = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(!contents.contains("sk-ant-oat01-SECRET-A"))
        #expect(!contents.contains("renewal-secret-that-must-never-be-archived"))
        #expect(!contents.lowercased().contains("accesstoken"))
        #expect(!contents.lowercased().contains("bearer"))
        // What it *does* contain is metadata only.
        #expect(contents.contains("a@example.com"))
        #expect(contents.contains("archived"))
    }

    // MARK: AC2.7 — keychain seam

    @Test
    func keychainServiceIsInjectableInTests() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        #expect(store.activeKeychainService == service)
        #expect(store.activeKeychainService != AccountRosterStore.keychainService)
        #expect(AccountRosterStore.keychainService == "com.eximia.eximiabar.accounts")
        // The production index location is never the one this test writes to.
        #expect(!store.indexURL.path.contains("Application Support"))

        // And the injected service is the one actually used by the keychain item.
        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "token-a"))

        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: AccountRosterStore
                .keychainAccount(for: AccountKey(provider: .claude, identifier: "a@example.com")),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        #endif
    }

    // MARK: AC2.5 — decision D-A

    @Test
    func archivedSecretNeverContainsRefreshToken() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "token-a"))

        let archived = try #require(
            await store.archivedToken(for: AccountKey(provider: .claude, identifier: "a@example.com")))
        #expect(archived.accessToken == "token-a")

        // Structural proof of D-A: the archived payload has exactly two fields, and the renewal
        // credential is not one of them — there is no field to put it in.
        let fields = Mirror(reflecting: archived).children.compactMap(\.label)
        #expect(fields.sorted() == ["accessToken", "expiresAt"])

        // Nothing that was serialized carries the renewal credential either.
        let encoded = try JSONEncoder().encode(archived)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("renewal-secret-that-must-never-be-archived"))
    }

    /// AC8.20 — the same proof, mechanized over the source tree: the whole `Accounts/` module
    /// cannot name the renewal credential, so it cannot archive it even by accident.
    @Test
    func accountsModuleNeverNamesTheRenewalCredential() throws {
        let accountsDirectory = repositoryRoot
            .appendingPathComponent("Sources/ClaudeBarCore/Accounts")
        let files = try FileManager.default
            .contentsOfDirectory(at: accountsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 2)

        let forbidden = ["refresh" + "Token", "refresh" + "_token"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                #expect(!source.contains(needle), "\(file.lastPathComponent) names \(needle)")
            }
        }
    }

    // MARK: AC3 — decision D-B (ceiling of 8, LRU)

    @Test
    func rosterEvictsOldestByLastSeenAtAt9thEntry() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        // Nine distinct identities, captured in order: each capture archives the previous one and
        // stamps `lastSeenAt = now`, so insertion order is also LRU order.
        for index in 1 ... 9 {
            await store.captureIfIdentityChanged(
                current: identity("account\(index)@example.com"),
                credentials: credentials(accessToken: "token-\(index)"))
            // Keep `lastSeenAt` strictly increasing — the timestamps are sub-millisecond apart.
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        let roster = await store.roster()
        #expect(roster.count == AccountRosterStore.maxEntries)
        #expect(roster.count == 8)
        // The very first account is the least recently seen, so it is the one that was evicted.
        #expect(!roster.contains { $0.key.identifier == "account1@example.com" })
        #expect(roster.contains { $0.key.identifier == "account2@example.com" })
        #expect(roster.first { $0.lifecycle == .live }?.key.identifier == "account9@example.com")

        // Eviction takes the secret with it — no orphan keychain item survives.
        #expect(await store.archivedToken(
            for: AccountKey(provider: .claude, identifier: "account1@example.com")) == nil)

        // And the ceiling holds on disk too, not just in memory (AC8.23).
        let data = try Data(contentsOf: store.indexURL)
        let persisted = try JSONDecoder.rosterDecoder.decode([AccountRosterEntry].self, from: data)
        #expect(persisted.count == 8)
    }

    // MARK: AC4.12 — R11, partial reads are a no-op

    @Test
    func partialCredentialParseIsNoOpAndNeverOverwritesAnExistingEntry() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a", plan: "max"))
        let before = await store.roster()

        // A `.credentials.json` read mid-write yields an empty access token.
        let outcome = await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "   ", plan: nil))

        guard case .skipped = outcome else {
            Issue.record("expected a skipped outcome, got \(outcome)")
            return
        }
        let after = await store.roster()
        #expect(after.count == 1)
        #expect(after == before)
        #expect(after[0].plan == "max")
        #expect(after[0].lifecycle == .live)
        #expect(!after.contains { $0.key.identifier == "b@example.com" })
    }

    // MARK: Upsert semantics

    @Test
    func duplicateIdentityDoesNotDuplicateRosterEntry() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        let sameIdentity = identity("a@example.com")
        for _ in 1 ... 5 {
            await store.captureIfIdentityChanged(
                current: sameIdentity,
                credentials: credentials(accessToken: "token-a"))
        }

        let roster = await store.roster()
        #expect(roster.count == 1)
        #expect(roster[0].lifecycle == .live)

        // Switching away and back reuses the same row, and the archived secret is dropped when
        // the account goes live again (its token belongs to the CLI once more).
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "token-a"))
        #expect(await store.roster().count == 2)

        await store.captureIfIdentityChanged(
            current: sameIdentity,
            credentials: credentials(accessToken: "token-b"))
        let final = await store.roster()
        #expect(final.count == 2)
        #expect(final.first { $0.key.identifier == "a@example.com" }?.lifecycle == .live)
        #expect(await store.archivedToken(for: sameIdentity.key) == nil)
    }

    @Test
    func removeDropsBothTheEntryAndItsSecret() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        await store.captureIfIdentityChanged(
            current: identity("a@example.com"),
            credentials: credentials(accessToken: "token-a"))
        await store.captureIfIdentityChanged(
            current: identity("b@example.com"),
            credentials: credentials(accessToken: "token-a"))

        let archivedKey = AccountKey(provider: .claude, identifier: "a@example.com")
        #expect(await store.archivedToken(for: archivedKey) != nil)

        await store.remove(archivedKey)

        #expect(await store.roster().count == 1)
        #expect(await store.archivedToken(for: archivedKey) == nil)
        let contents = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(!contents.contains("a@example.com"))
    }

    // MARK: AC6 — T-R10, actor isolation

    @Test
    func rosterStoreIsAPlainActorAndIsNeverReadFromTheUI() throws {
        let storeSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift"),
            encoding: .utf8)
        // AC8.24 — a `@MainActor` here would put file and keychain I/O on the main thread.
        #expect(!storeSource.contains("@MainActor"))
        #expect(storeSource.contains("public actor AccountRosterStore"))

        // The UI never talks to the store: it consumes the snapshot (EXB-5.3). The only app-side
        // reference is `LiveUsageProvider`, which builds it off-MainActor.
        let appDirectory = repositoryRoot.appendingPathComponent("Sources/ClaudeBar")
        let swiftFiles = FileManager.default
            .enumerator(at: appDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!swiftFiles.isEmpty)

        var referencing: [String] = []
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("AccountRosterStore") { referencing.append(file.lastPathComponent) }
        }
        #expect(referencing == ["LiveUsageProvider.swift"])
    }

    // MARK: AC5 — T-R9, archived accounts are strictly read-only

    @Test
    func archivedAccountsNeverTriggerRefreshOrFetch() async throws {
        let (store, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        // Populate the roster with three archived accounts, each with its own token.
        for index in 1 ... 4 {
            await store.captureIfIdentityChanged(
                current: identity("archived\(index)@example.com"),
                credentials: credentials(accessToken: "ARCHIVED-TOKEN-\(index)"))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let archivedTokens = (1 ... 3).map { "ARCHIVED-TOKEN-\($0)" }
        #expect(await store.roster().filter { $0.lifecycle == .archived }.count == 3)

        // Run a full refresh + fetch cycle for the LIVE account only — which is the only path
        // that exists: both `RefreshCoordinator` and `UsageFetcher` take a credential, and the
        // roster hands out none.
        let spy = RecordingTransport(response: .make(
            status: 200,
            json: #"{"access_token":"fresh","expires_in":3600}"#))
        let coordinator = RefreshCoordinator(transport: spy, delegatedProbe: { _ in false })
        let liveRecord = ClaudeOAuthCredentialRecord(
            credentials: credentials(accessToken: "LIVE-TOKEN"),
            owner: .claudebar,
            source: .credentialsFile)
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        _ = await coordinator.refresh(record: liveRecord)

        let fetchSpy = RecordingTransport(response: .make(status: 200, json: "{}"))
        let fetcher = UsageFetcher(transport: fetchSpy, identityResolver: nil)
        _ = try await fetcher.fetchSnapshot(credentials: liveRecord.credentials)

        // Zero network calls carry an archived account's token, in either direction.
        let sentBodies = await spy.bodies + fetchSpy.bodies
        let sentHeaders = await spy.authorizationHeaders + fetchSpy.authorizationHeaders
        for token in archivedTokens {
            #expect(!sentBodies.contains { $0.contains(token) })
            #expect(!sentHeaders.contains { $0.contains(token) })
        }
        // One refresh POST and one usage GET, both for the live account. Nothing per archived
        // account — the count does not scale with the roster.
        #expect(await spy.requestCount == 1)
        #expect(await fetchSpy.requestCount == 1)
        // The only bearer token that ever leaves the process is the live one. (The refresh POST
        // carries no `Authorization` header at all — its credential travels in the form body,
        // already checked above.)
        #expect(await fetchSpy.authorizationHeaders == ["Bearer LIVE-TOKEN"])
    }

    // MARK: AC4.11 — capture happens BEFORE cache invalidation

    @Test
    func capturesPreviousCredentialBeforeCacheInvalidation() async throws {
        let (roster, directory, service) = makeStore()
        defer { cleanUp(directory: directory, service: service) }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        func writeLogin(accessToken: String, email: String, mtimeOffset: TimeInterval) throws {
            let credentialsURL = home.appendingPathComponent(".claude/.credentials.json")
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": "cli-renewal-secret",
                "expiresAt": 4_102_444_800_000 as Double,
                "scopes": ["user:profile"],
                "subscriptionType": "max",
            ]]).write(to: credentialsURL)
            let configURL = home.appendingPathComponent(ClaudeIdentityResolver.configFileRelativePath)
            try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": email]])
                .write(to: configURL)
            for url in [credentialsURL, configURL] {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(mtimeOffset)],
                    ofItemAtPath: url.path)
            }
        }

        try writeLogin(accessToken: "TOKEN-A", email: "a@example.com", mtimeOffset: 0)

        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: UserDefaults(suiteName: "eximiabar.test.\(UUID().uuidString)") ?? .standard,
            promptPolicy: .never,
            enableSystemKeychain: false,
            accountRoster: roster,
            identityResolver: ClaudeIdentityResolver(homeDirectory: home))

        // Cycle 1 primes the in-memory cache; cycle 2 registers account A as live.
        #expect(try await store.load().credentials.accessToken == "TOKEN-A")
        await store.expireFingerprintThrottleForTesting()
        _ = try await store.load()
        #expect(await roster.roster().first?.key.identifier == "a@example.com")

        // `claude login` swaps the account: new token on disk, new e-mail in the config.
        try writeLogin(accessToken: "TOKEN-B", email: "b@example.com", mtimeOffset: 120)
        await store.expireFingerprintThrottleForTesting()
        #expect(try await store.load().credentials.accessToken == "TOKEN-B")

        let entries = await roster.roster()
        #expect(entries.count == 2)
        #expect(entries.first { $0.key.identifier == "b@example.com" }?.lifecycle == .live)
        #expect(entries.first { $0.key.identifier == "a@example.com" }?.lifecycle == .archived)

        // THE POINT: the archived secret is the token of the account we left — captured before
        // the poll dropped the caches. After the invalidation it exists nowhere, so a capture
        // ordered the other way round would silently store `nil`.
        let archived = try #require(
            await roster.archivedToken(for: AccountKey(provider: .claude, identifier: "a@example.com")))
        #expect(archived.accessToken == "TOKEN-A")
        #expect(archived.accessToken != "TOKEN-B")
    }
}

// MARK: - Helpers

/// An `HTTPTransport` that records every request it is handed.
private actor RecordingTransport: HTTPTransport {
    private let response: HTTPResponse
    private(set) var requestCount = 0
    private(set) var bodies: [String] = []
    private(set) var authorizationHeaders: [String] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        self.requestCount += 1
        self.bodies.append(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        self.authorizationHeaders
            .append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        return self.response
    }
}

extension JSONDecoder {
    /// Matches the roster's on-disk date strategy.
    static var rosterDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
