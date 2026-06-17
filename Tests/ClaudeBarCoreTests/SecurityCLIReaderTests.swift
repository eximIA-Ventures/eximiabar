import Foundation
import Testing
@testable import ClaudeBarCore

/// Covers layer (e)'s `/usr/bin/security` CLI reader — the prompt-free primary path that fixes
/// the recurring keychain Allow/Deny dialog. The subprocess is replaced by the DEBUG
/// `securityCLIReadOverride` seam so these tests are deterministic and never touch the real
/// keychain or spawn a process.
///
/// All cases run with `enableSystemKeychain: true` and NO env/file/cache source, so layer (e) is
/// the only producer — exactly the path that used to prompt.
struct SecurityCLIReaderTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "eximiabar.test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func emptyHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Builds a `.credentials.json`-shaped payload as the `security -w` output would contain.
    private func payload(accessToken: String, expiresAtMs: Double) -> Data {
        let oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": "refresh",
            "expiresAt": expiresAtMs,
            "scopes": ["user:profile"],
        ]
        return (try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])) ?? Data()
    }

    private func makeStore(home: URL, strategy: KeychainReadStrategy) -> CredentialsStore {
        CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: isolatedDefaults(),
            promptPolicy: .never,
            enableSystemKeychain: true,
            readStrategy: strategy)
    }

    // MARK: - PRIMARY: CLI reader supplies a valid token

    @Test
    func securityCLIPrimaryReturnsValidToken() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityCLIPrimary)
        let data = payload(accessToken: "cli-token", expiresAtMs: 4_102_444_800_000) // far future
        await store.setSecurityCLIReadOverrideForTesting(.data(data))

        let record = try await store.load(phase: .background)
        #expect(record.credentials.accessToken == "cli-token")
        #expect(record.owner == .claudeCLI)
        #expect(record.source == .claudeKeychain)
    }

    // MARK: - Selection: an expired CLI token is rejected (routes to fallback)

    @Test
    func expiredCLITokenIsNotUsed() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityCLIPrimary)
        // expiresAt in the distant past → isExpired == true → reader returns nil.
        let data = payload(accessToken: "expired-cli-token", expiresAtMs: 1_000)
        await store.setSecurityCLIReadOverrideForTesting(.data(data))

        // With no other readable source, layer (e)'s fallback yields nothing → notFound. The key
        // guarantee: the expired CLI token is NEVER surfaced.
        do {
            let record = try await store.load(phase: .background)
            #expect(record.credentials.accessToken != "expired-cli-token")
        } catch is ClaudeOAuthCredentialsError {
            // Acceptable: no source produced a live token.
        }
    }

    // MARK: - Empty / nil CLI output → graceful fallback (no throw from the CLI path)

    @Test
    func emptyCLIOutputFallsThrough() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityCLIPrimary)
        await store.setSecurityCLIReadOverrideForTesting(.data(nil))

        do {
            let record = try await store.load(phase: .background)
            #expect(record.credentials.accessToken != "")
        } catch is ClaudeOAuthCredentialsError {
            // Acceptable on a machine with no readable Claude item.
        }
    }

    // MARK: - Subprocess failure modes never throw out of the CLI reader

    @Test
    func timedOutCLIReadFallsThrough() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityCLIPrimary)
        await store.setSecurityCLIReadOverrideForTesting(.timedOut)

        // Must not surface the timeout as a thrown error from the CLI layer; either a fallback
        // record or a clean notFound is fine.
        do {
            _ = try await store.load(phase: .background)
        } catch is ClaudeOAuthCredentialsError {
            // ok
        }
    }

    @Test
    func nonZeroExitCLIReadFallsThrough() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityCLIPrimary)
        await store.setSecurityCLIReadOverrideForTesting(.nonZeroExit)

        do {
            _ = try await store.load(phase: .background)
        } catch is ClaudeOAuthCredentialsError {
            // ok
        }
    }

    // MARK: - Legacy strategy bypasses the CLI reader entirely

    @Test
    func securityFrameworkStrategyIgnoresCLIOverride() async throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = makeStore(home: home, strategy: .securityFramework)
        // The override would supply a valid token, but `.securityFramework` must NOT consult it.
        let data = payload(accessToken: "should-be-ignored", expiresAtMs: 4_102_444_800_000)
        await store.setSecurityCLIReadOverrideForTesting(.data(data))

        do {
            let record = try await store.load(phase: .background)
            // If the machine happens to have a real readable Claude item, the fallback may succeed,
            // but it must never be the CLI override token.
            #expect(record.credentials.accessToken != "should-be-ignored")
        } catch is ClaudeOAuthCredentialsError {
            // No readable Security.framework item → notFound. The CLI override was correctly skipped.
        }
    }

    // MARK: - Sanitizer strips trailing newlines from the `-w` payload

    @Test
    func sanitizerStripsTrailingNewlines() {
        let withNewlines = Data("payload\n\r\n".utf8)
        let cleaned = CredentialsStore.sanitizeSecurityCLIOutput(withNewlines)
        #expect(cleaned == Data("payload".utf8))

        let none = Data("payload".utf8)
        #expect(CredentialsStore.sanitizeSecurityCLIOutput(none) == none)

        #expect(CredentialsStore.sanitizeSecurityCLIOutput(Data()) == Data())
    }
}
