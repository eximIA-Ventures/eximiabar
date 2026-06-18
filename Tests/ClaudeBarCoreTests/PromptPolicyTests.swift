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

    /// The read-strategy provider is read on **every** `load` that reaches the keychain layer (e),
    /// never memoized.
    ///
    /// Layer (e) no longer raises keychain prompts (the `/usr/bin/security` CLI reader supplies the
    /// secret prompt-free), so the prompt policy is no longer consulted there. The live, non-memoized
    /// provider that (e) now samples on every load is the **read strategy** — this test guards that
    /// same no-memoization contract on it.
    ///
    /// With no env token, no cache, and no credentials file, every `load` falls through layers (a)–(d)
    /// straight into (e) where the strategy is consulted — exactly once per call. Each load throws
    /// `.notFound` (no system keychain item under test), so nothing is memoized and the next load
    /// reaches (e) again. Asserting an exact read-count == number of (e)-reaching loads is a tight
    /// regression guard — strictly stronger than "≥ 1".
    @Test
    func readStrategyProviderIsReadOnEveryLoadReachingKeychain() async throws {
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
            promptPolicyProvider: { .never },
            // System keychain enabled so the strategy provider is consulted in layer (e). Use the
            // legacy strategy so the (DEBUG) CLI override is never consulted and the load reliably
            // reaches the no-UI fallback → `.notFound` under test.
            enableSystemKeychain: true,
            readStrategyProvider: { reads.bump(); return .securityFramework },
            // Isolated, per-test cache service: layer (c)'s save/load/clear must never touch the real
            // `com.eximia.eximiabar.cache` item (that write+re-read is what prompts the keychain).
            cacheKeychainService: "com.eximia.eximiabar.cache.test.\(UUID().uuidString)")

        let loadCount = 3
        for _ in 0 ..< loadCount {
            // Each load misses (a)–(d) and consults the provider in (e). `invalidateCaches()` drops
            // any record a host `"Claude Code-credentials"` item might have produced, so the *next*
            // load can't short-circuit at the in-memory layer (b) — every iteration reaches (e),
            // making the read-count deterministic regardless of the host keychain state.
            _ = try? await store.load(phase: .userInitiated)
            await store.invalidateCaches()
        }

        // Exactly one provider read per load that reached (e) — proves the strategy is re-sampled on
        // every load, never captured once at init. Tight `== loadCount` regression guard.
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
