import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-5.1 — identity resolution from `~/.claude.json`.
///
/// Every test points the resolver at a throwaway HOME under `tmp`, so the real
/// `~/.claude.json` is never read and no keychain is ever touched.
struct ClaudeIdentityResolverTests {
    // MARK: Fixtures

    /// Writes a fake HOME containing `.claude.json` with the given top-level JSON object.
    private func makeTempHome(config: [String: Any]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: home.appendingPathComponent(ClaudeIdentityResolver.configFileRelativePath))
        return home
    }

    /// The `oauthAccount` shape observed on a real machine.
    private func oauthAccount(
        email: String = "hugo@example.com",
        displayName: String? = "Hugo",
        organizationName: String? = "Acme Org",
        accountUuid: String? = "293205eb-08a4-4aca-93d6-7c515865dbff") -> [String: Any]
    {
        var account: [String: Any] = ["emailAddress": email]
        if let displayName { account["displayName"] = displayName }
        if let organizationName { account["organizationName"] = organizationName }
        if let accountUuid { account["accountUuid"] = accountUuid }
        return account
    }

    // MARK: AC1 / AC2 — normalization

    @Test
    func emailIsNormalizedLowercaseAndTrimmed() async throws {
        let home = try makeTempHome(config: [
            "oauthAccount": oauthAccount(email: "  Hugo.Capitelli@Example.COM \n"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve(accessToken: "tok"))

        #expect(identity.email == "hugo.capitelli@example.com")
        #expect(identity.key.identifier == "hugo.capitelli@example.com")
        #expect(identity.key.provider == .claude)
        #expect(identity.hasResolvedEmail)
    }

    @Test
    func identityCarriesDisplayNameOrganizationAndUUID() async throws {
        let home = try makeTempHome(config: ["oauthAccount": oauthAccount()])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve())

        #expect(identity.displayName == "Hugo")
        #expect(identity.organizationName == "Acme Org")
        #expect(identity.accountUUID == "293205eb-08a4-4aca-93d6-7c515865dbff")
    }

    // MARK: AC3 — opaque fallback (R12)

    @Test
    func fallbackOpaqueKeyWhenOauthAccountMissing() async throws {
        // A config file that exists but has no `oauthAccount` at all.
        let home = try makeTempHome(config: ["numStartups": 42, "installMethod": "npm"])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve(accessToken: "sk-ant-oat01-secret"))

        #expect(identity.email.isEmpty)
        #expect(!identity.hasResolvedEmail)
        #expect(identity.displayName == "Conta 1")
        #expect(identity.key.provider == .claude)
        // The opaque key is sha256(accessToken) truncated to 8 bytes → 16 hex chars.
        #expect(identity.key.identifier
            == CredentialsStore.sha256Prefix(Data("sk-ant-oat01-secret".utf8)))
        #expect(identity.key.identifier.count == 16)
    }

    @Test
    func malformedOauthAccountDegradesToFallbackInsteadOfFailing() async throws {
        // `oauthAccount` present but the wrong shape entirely.
        let home = try makeTempHome(config: ["oauthAccount": "not-an-object"])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve(accessToken: "tok"))
        #expect(identity.email.isEmpty)
        #expect(identity.displayName == "Conta 1")
    }

    @Test
    func opaqueOrdinalIsStablePerTokenAndIncrementsPerNewAccount() async throws {
        let home = try makeTempHome(config: [:])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let first = try #require(await resolver.resolve(accessToken: "token-a"))
        let second = try #require(await resolver.resolve(accessToken: "token-b"))
        let firstAgain = try #require(await resolver.resolve(accessToken: "token-a"))

        #expect(first.displayName == "Conta 1")
        #expect(second.displayName == "Conta 2")
        #expect(firstAgain.displayName == "Conta 1")
    }

    @Test
    func noEmailAndNoTokenResolvesToNil() async throws {
        let home = try makeTempHome(config: [:])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        #expect(await resolver.resolve(accessToken: nil) == nil)
    }

    // MARK: AC2.4 — fingerprint gate

    @Test
    func fingerprintGatePreventsReparseWhenMtimeUnchanged() async throws {
        let home = try makeTempHome(config: ["oauthAccount": oauthAccount()])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)

        _ = await resolver.resolve()
        _ = await resolver.resolve()
        _ = await resolver.resolve()
        // Three resolves, one parse: the 45 KB file is not re-read while mtime is unchanged.
        #expect(await resolver.parseCount == 1)

        // Rewrite with a different account AND a moved mtime → the gate must open.
        let configURL = home.appendingPathComponent(ClaudeIdentityResolver.configFileRelativePath)
        let rewritten = try JSONSerialization.data(
            withJSONObject: ["oauthAccount": oauthAccount(email: "second@example.com")])
        try rewritten.write(to: configURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: configURL.path)

        let refreshed = try #require(await resolver.resolve())
        #expect(await resolver.parseCount == 2)
        #expect(refreshed.email == "second@example.com")
    }

    // MARK: AC2.5 — tolerant decoder

    @Test
    func tolerantDecoderIgnoresUnknownTopLevelFields() async throws {
        // Mirrors the real file: dozens of unrelated top-level keys of mixed types, plus
        // unknown keys *inside* `oauthAccount`.
        var account = oauthAccount()
        account["billingType"] = "stripe_subscription"
        account["hasExtraUsageEnabled"] = false
        account["profileFetchedAt"] = 1_785_476_734_249
        account["seatTier"] = NSNull()

        let home = try makeTempHome(config: [
            "oauthAccount": account,
            "numStartups": 91,
            "tipsHistory": ["ide-hotkey": 3, "shift-enter": 12],
            "projects": ["/some/path": ["allowedTools": [], "history": []]],
            "cachedChangelog": String(repeating: "x", count: 4096),
            "fallbackAvailableWarningThreshold": 0.5,
            "isQualifiedForDataSharing": NSNull(),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve())

        #expect(identity.email == "hugo@example.com")
        #expect(identity.displayName == "Hugo")
    }

    @Test
    func missingConfigFileIsNotAnError() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-identity-absent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeIdentityResolver(homeDirectory: home)
        let identity = try #require(await resolver.resolve(accessToken: "tok"))
        #expect(identity.email.isEmpty)
        #expect(await resolver.parseCount == 0)
    }

    // MARK: AC4 — the snapshot is finally populated (closes D1)

    @Test
    func identityPopulatesUsageSnapshotNotNil() async throws {
        let home = try makeTempHome(config: ["oauthAccount": oauthAccount()])
        defer { try? FileManager.default.removeItem(at: home) }

        let json = """
        {"five_hour":{"utilization":12.5,"resets_at":"2026-07-31T12:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":"2026-08-04T12:00:00Z"}}
        """
        let fetcher = UsageFetcher(
            transport: StubTransport(response: .make(status: 200, json: json)),
            identityResolver: ClaudeIdentityResolver(homeDirectory: home))

        let credentials = ClaudeOAuthCredentials(
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["user:profile"],
            rateLimitTier: nil,
            subscriptionType: "max")

        let snapshot = try await fetcher.fetchSnapshot(credentials: credentials)
        let identity = try #require(snapshot.identity) // D1: was unconditionally nil before EXB-5.1
        #expect(identity.email == "hugo@example.com")
        #expect(identity.name == "Hugo")
    }

    @Test
    func snapshotIdentityFallsBackToOpaqueLabelWithoutEmail() async throws {
        let home = try makeTempHome(config: ["numStartups": 3])
        defer { try? FileManager.default.removeItem(at: home) }

        let fetcher = UsageFetcher(
            transport: StubTransport(response: .make(status: 200, json: "{}")),
            identityResolver: ClaudeIdentityResolver(homeDirectory: home))

        let credentials = ClaudeOAuthCredentials(
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: nil)

        let snapshot = try await fetcher.fetchSnapshot(credentials: credentials)
        let identity = try #require(snapshot.identity)
        #expect(identity.name == "Conta 1")
        // Empty e-mail keeps the popover header from rendering a blank slot (UsageCardView:92).
        #expect(identity.email.isEmpty)
    }

    @Test
    func nilResolverLeavesSnapshotIdentityNil() async throws {
        let fetcher = UsageFetcher(
            transport: StubTransport(response: .make(status: 200, json: "{}")),
            identityResolver: nil)

        let credentials = ClaudeOAuthCredentials(
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: nil)

        let snapshot = try await fetcher.fetchSnapshot(credentials: credentials)
        #expect(snapshot.identity == nil)
    }
}
