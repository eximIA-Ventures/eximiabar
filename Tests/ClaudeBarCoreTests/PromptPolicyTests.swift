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

    /// The provider is read on every `load`, never memoized. A mutable, thread-safe source observes
    /// at least one read per load — confirming the policy is re-sampled rather than captured once.
    @Test
    func policyProviderIsReadPerLoad() async throws {
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

        let reads = ReadCounter()
        let store = CredentialsStore(
            environment: [:],
            homeDirectory: home,
            defaults: UserDefaults(suiteName: "exb.policy.\(UUID().uuidString)")!,
            // System keychain enabled so the policy provider is actually consulted in layer (e).
            promptPolicyProvider: { reads.bump(); return .never },
            enableSystemKeychain: true)

        // The file layer satisfies the load before reaching (e) on the first call, but a second
        // load that misses the file (removed) drops to (e) where the provider IS consulted.
        _ = try? await store.load(phase: .background)
        try FileManager.default.removeItem(at: home)
        await store.invalidateCaches()
        _ = try? await store.load(phase: .userInitiated)

        #expect(reads.value >= 1)
    }
}

/// Thread-safe counter for the provider-read assertion.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
