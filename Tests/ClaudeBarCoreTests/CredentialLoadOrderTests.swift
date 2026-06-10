import Foundation
import Testing
@testable import ClaudeBarCore

/// AC17e: credential load priority order (env > memory > keychain-cache > file > keychain-system).
///
/// Keychain layers require a live macOS keychain, so these tests exercise the
/// deterministic, injectable layers (environment, in-memory cache, file) and assert the
/// priority relationships between them. The keychain ordering is enforced structurally in
/// `CredentialsStore.load` and covered by AC4 contract.
struct CredentialLoadOrderTests {
    /// Writes a temporary `~/.claude/.credentials.json` and returns the fake HOME URL.
    private func makeTempHome(
        accessToken: String,
        subscriptionType: String? = nil,
        expiresAtMs: Double = 4_102_444_800_000) throws -> URL
    {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-test-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": "refresh",
            "expiresAt": expiresAtMs,
            "scopes": ["user:profile"],
        ]
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        let payload = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try payload.write(to: claudeDir.appendingPathComponent(".credentials.json"))
        return home
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "eximiabar.test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    @Test
    func environmentTokenWinsOverFile() async throws {
        let home = try makeTempHome(accessToken: "file-token")
        defer { try? FileManager.default.removeItem(at: home) }

        let store = CredentialsStore(
            environment: [CredentialsStore.environmentTokenKey: "env-token"],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: false)

        let record = try await store.load(phase: .background)
        #expect(record.credentials.accessToken == "env-token")
        #expect(record.owner == .environment)
        #expect(record.source == .environment)
    }

    @Test
    func fileUsedWhenNoEnvToken() async throws {
        let home = try makeTempHome(accessToken: "file-token", subscriptionType: "max")
        defer { try? FileManager.default.removeItem(at: home) }

        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: false)

        let record = try await store.load(phase: .background)
        #expect(record.credentials.accessToken == "file-token")
        #expect(record.owner == .claudeCLI)
        #expect(record.source == .credentialsFile)
        // Plan resolves from the file's subscriptionType.
        #expect(record.credentials.subscriptionType == "max")
    }

    @Test
    func inMemoryCacheServesSecondLoadWithoutFile() async throws {
        let home = try makeTempHome(accessToken: "file-token")

        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: false)

        // First load hydrates the in-memory cache from the file.
        let first = try await store.load(phase: .background)
        #expect(first.source == .credentialsFile)

        // Remove the file; the in-memory cache (priority above file) must still serve.
        try FileManager.default.removeItem(at: home)
        let second = try await store.load(phase: .background)
        #expect(second.credentials.accessToken == "file-token")
        #expect(second.source == .memoryCache)
    }

    @Test
    func notFoundWhenNoSourceAvailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: false)

        await #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try await store.load(phase: .background)
        }
    }

    @Test
    func emptyEnvTokenFallsThroughToFile() async throws {
        let home = try makeTempHome(accessToken: "file-token")
        defer { try? FileManager.default.removeItem(at: home) }

        let store = CredentialsStore(
            environment: [CredentialsStore.environmentTokenKey: "   "],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: false)

        let record = try await store.load(phase: .background)
        #expect(record.source == .credentialsFile)
    }
}
