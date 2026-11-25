import Foundation
import Testing
@testable import ClaudeBarCore

/// The keychain-prompt fix: the app's own secrets live in `0600` files, the Claude item is only
/// ever read through `/usr/bin/security`, and no test can reach the real keychain.
struct KeychainFreeStorageTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func tempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCredentialsFile(home: URL, token: String) throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["claudeAiOauth": [
            "accessToken": token,
            "expiresAt": 4_102_444_800_000.0,
            "scopes": ["user:profile"],
        ]]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: dir.appendingPathComponent(".credentials.json"))
    }

    private func store(home: URL, cache: URL, strategy: KeychainReadStrategy = .securityFramework)
        -> CredentialsStore
    {
        CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: UserDefaults(suiteName: "exb.kcfree.\(UUID().uuidString)")!,
            promptPolicy: .never,
            enableSystemKeychain: true,
            readStrategy: strategy,
            cacheDirectory: cache)
    }

    // MARK: Verifier is armed

    /// `Scripts/run-tests.sh` exports the tripwire. If this fails the suite is not being run the
    /// supported way, and nothing guarantees the keychain stays untouched.
    @Test
    func realKeychainTripwireIsArmedUnderTheTestScript() {
        #expect(RealKeychainTripwire.isArmed)
    }

    // MARK: Layer (c) is a 0600 file

    @Test
    func cacheLayerWritesOwnerOnlyFileAndReadsItBack() async throws {
        let home = try tempDirectory("home")
        let cache = home.appendingPathComponent("support")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCredentialsFile(home: home, token: "FILE-TOKEN")

        let first = store(home: home, cache: cache)
        #expect(try await first.load().source == .credentialsFile)

        let cacheFile = cache.appendingPathComponent(CredentialsStore.cacheFileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: cache.path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.int16Value == 0o700)

        // Next launch, the CLI file is gone: the token comes back from our cache file alone.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
        let second = store(home: home, cache: cache)
        let record = try await second.load()
        #expect(record.source == .cacheKeychain)
        #expect(record.credentials.accessToken == "FILE-TOKEN")

        // Invalidation removes the file, not a keychain item.
        await second.invalidateCaches()
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test
    func privateFileWriteIsOwnerOnlyAndAtomic() throws {
        let dir = try tempDirectory("pf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/secret.json")
        try PrivateFile.write(Data("one".utf8), to: url)
        try PrivateFile.write(Data("two".utf8), to: url)
        #expect(PrivateFile.read(url) == Data("two".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["secret.json"])
    }

    // MARK: Layer (e) — CLI only

    @Test
    func securityFrameworkStrategyNeverReachesTheKeychain() async throws {
        let home = try tempDirectory("home")
        defer { try? FileManager.default.removeItem(at: home) }
        // No override set: with the tripwire armed, any subprocess or SecItem read would crash.
        let store = store(home: home, cache: home.appendingPathComponent("support"))
        await #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try await store.load(phase: .userInitiated)
        }
    }

    @Test
    func fingerprintUsesOnlyAccountAndDateAttributes() {
        let a = Data("""
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="x"
            "cdat"<timedate>=0x3230323631313235  "20261125180628Z\\000"
            "mdat"<timedate>=0x3230323631313235  "20261125180628Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """.utf8)
        let sameButOtherNoise = Data(String(decoding: a, as: UTF8.self)
            .replacingOccurrences(of: "login.keychain-db", with: "other.keychain-db").utf8)
        let renewed = Data(String(decoding: a, as: UTF8.self)
            .replacingOccurrences(of: "\"mdat\"<timedate>=0x3230323631313235  \"20261125180628Z",
                                  with: "\"mdat\"<timedate>=0x3230323631313236  \"20261125190000Z").utf8)

        let base = CredentialsStore.fingerprint(fromAttributesOutput: a)
        #expect(base != nil)
        #expect(CredentialsStore.fingerprint(fromAttributesOutput: sameButOtherNoise) == base)
        #expect(CredentialsStore.fingerprint(fromAttributesOutput: renewed) != base)
        #expect(CredentialsStore.fingerprint(fromAttributesOutput: Data()) == nil)
    }

    @Test
    func attributesProbeOverrideDrivesChangeDetection() async throws {
        let home = try tempDirectory("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = store(home: home, cache: home.appendingPathComponent("support"), strategy: .securityCLIPrimary)
        await store.setSecurityCLIAttributesOverrideForTesting(Data("\"mdat\"<timedate>=0x01".utf8))
        // The attributes-only seam is set and the read seam is not: the reader must not fall
        // through to the real binary (the tripwire would crash) and layer (e) yields nothing.
        await #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try await store.load(phase: .background)
        }
    }

    // MARK: Static guard — no SecItem on third-party items

    /// The only `SecItem*` call sites allowed in `Sources/` are the roster's no-UI migration read
    /// of the app's OWN legacy item. Any other one (in particular on `Claude Code-credentials` or a
    /// Codex item) reintroduces the prompt.
    @Test
    func noSecItemCallOutsideTheLegacyMigrationRead() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for call in ["SecItemCopyMatching(", "SecItemAdd(", "SecItemUpdate(", "SecItemDelete(", "SecKeychain"]
                    where code.contains(call)
                {
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(call)")
                }
            }
        }
        #expect(offenders == ["AccountRosterStore.swift:\(Self.legacyReadLine()): SecItemCopyMatching("])
    }

    private static func legacyReadLine() -> Int {
        let url = repositoryRoot.appendingPathComponent("Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift")
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        return (lines.firstIndex { $0.contains("SecItemCopyMatching(") } ?? -1) + 1
    }
}
