import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-1.5 AC11: keychain prompt policy semantics and the runtime (non-memoized) policy provider
/// on `CredentialsStore`.
struct PromptPolicyTests {
    // MARK: - Policy → phase semantics

    @Test
    func neverAllowsNoPrompt() {
        #expect(PromptPolicy.never.allowsPrompt(phase: .startup) == false)
        #expect(PromptPolicy.never.allowsPrompt(phase: .background) == false)
        #expect(PromptPolicy.never.allowsPrompt(phase: .userInitiated) == false)
    }

    @Test
    func onUserActionAllowsOnlyUserInitiated() {
        #expect(PromptPolicy.onUserAction.allowsPrompt(phase: .startup) == false)
        #expect(PromptPolicy.onUserAction.allowsPrompt(phase: .background) == false)
        #expect(PromptPolicy.onUserAction.allowsPrompt(phase: .userInitiated) == true)
    }

    @Test
    func alwaysAllowsEveryPhase() {
        #expect(PromptPolicy.always.allowsPrompt(phase: .startup) == true)
        #expect(PromptPolicy.always.allowsPrompt(phase: .background) == true)
        #expect(PromptPolicy.always.allowsPrompt(phase: .userInitiated) == true)
    }

    // MARK: - Runtime provider (AC11 — no memoization)

    /// The provider-based initializer wires the load chain correctly: a store built with a live
    /// policy closure still resolves the file layer.
    @Test
    func providerInitializerLoadsFromFile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-policy-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let oauth: [String: Any] = [
            "accessToken": "file-token",
            "refreshToken": "refresh",
            "expiresAt": 4_102_444_800_000,
            "scopes": ["user:profile"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try payload.write(to: claudeDir.appendingPathComponent(".credentials.json"))

        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: UserDefaults(suiteName: "exb.policy.\(UUID().uuidString)")!,
            promptPolicyProvider: { .always },
            enableSystemKeychain: false)

        let record = try await store.load(phase: .background)
        #expect(record.source == .credentialsFile)
    }

    /// The provider is read on **every** `load` that reaches the keychain layer (e), never memoized.
    ///
    /// With no env token, no cache, and no credentials file, every `load` falls through layers (a)–(d)
    /// straight into (e) where the policy is consulted (`CredentialsStore.load`, line 129) — exactly
    /// once per call, before `loadFromClaudeKeychain`. Each load throws `.notFound` (no system keychain
    /// item under test), so nothing is memoized and the next load reaches (e) again. Asserting an exact
    /// read-count == number of (e)-reaching loads is a tight regression guard on the no-memoization
    /// guarantee (AC11) — strictly stronger than "≥ 1".
    @Test
    func policyProviderIsReadOnEveryLoadReachingKeychain() async throws {
        // An empty home dir: no `~/.claude/.credentials.json`, so layer (d) always misses and every
        // load reaches (e).
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let reads = ReadCounter()
        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: UserDefaults(suiteName: "exb.policy.\(UUID().uuidString)")!,
            // System keychain enabled so the policy provider is consulted in layer (e).
            promptPolicyProvider: { reads.bump(); return .never },
            enableSystemKeychain: true)

        let loadCount = 3
        for _ in 0 ..< loadCount {
            // Each load misses (a)–(d) and consults the provider in (e). `invalidateCaches()` drops
            // any record a host `"Claude Code-credentials"` item might have produced, so the *next*
            // load can't short-circuit at the in-memory layer (b) — every iteration reaches (e),
            // making the read-count deterministic regardless of the host keychain state.
            _ = try? await store.load(phase: .userInitiated)
            await store.invalidateCaches()
        }

        // Exactly one provider read per load that reached (e) — proves the policy is re-sampled on
        // every load, never captured once at init. Tight `== loadCount` regression guard on AC11.
        #expect(reads.value == loadCount)
    }
}

/// Thread-safe counter for the provider-read assertion.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
