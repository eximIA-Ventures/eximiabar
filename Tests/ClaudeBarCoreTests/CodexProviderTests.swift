import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-5.4 — the lean Codex provider (OAuth via `~/.codex/auth.json`).
///
/// Every test points the store at a throwaway HOME under `tmp`, so the real `~/.codex/auth.json`
/// is never read, and every network path goes through `RecordingTransport`, so no test can reach
/// the real `chatgpt.com`.
struct CodexProviderTests {
    // MARK: Fixtures

    /// A transport that records every request it is handed and answers from a canned script.
    /// The recording is the point: several ACs are about calls that must **not** happen.
    private actor RecordingTransport: HTTPTransport {
        private(set) var requests: [URLRequest] = []
        private let response: HTTPResponse?
        private let failure: Error?

        init(response: HTTPResponse? = nil, failure: Error? = nil) {
            self.response = response
            self.failure = failure
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            self.requests.append(request)
            if let failure { throw failure }
            guard let response else { throw URLError(.unknown) }
            return response
        }

        var requestCount: Int { self.requests.count }
        var urls: [String] { self.requests.compactMap { $0.url?.absoluteString } }
        var methods: [String] { self.requests.compactMap(\.httpMethod) }
    }

    /// Builds an unsigned JWT with the given payload — signature bytes are junk on purpose,
    /// because nothing in this module verifies them.
    private func makeJWT(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    /// The claim shape observed on a real `id_token`.
    private func idTokenPayload(
        email: String? = "hugo@example.com",
        expiresAt: Date = Date().addingTimeInterval(3600),
        plan: String? = "pro",
        accountID: String? = "acct-123",
        extra: [String: Any] = [:]) -> [String: Any]
    {
        var openAIAuth: [String: Any] = [:]
        if let plan { openAIAuth["chatgpt_plan_type"] = plan }
        if let accountID { openAIAuth["chatgpt_account_id"] = accountID }

        var payload: [String: Any] = [
            "exp": expiresAt.timeIntervalSince1970,
            "iat": expiresAt.addingTimeInterval(-3600).timeIntervalSince1970,
            CodexJWTClaims.openAIAuthClaimKey: openAIAuth,
        ]
        if let email { payload["email"] = email }
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    /// Writes a fake CODEX_HOME containing `auth.json`.
    @discardableResult
    private func writeAuthFile(
        at home: URL,
        accessToken: String,
        idToken: String?,
        accountID: String? = "acct-123") throws -> URL
    {
        var tokens: [String: Any] = ["access_token": accessToken]
        if let idToken { tokens["id_token"] = idToken }
        if let accountID { tokens["account_id"] = accountID }
        let payload: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
            // Present in the real file, deliberately unread by the store.
            "last_refresh": "2026-07-17T17:34:43.201041Z",
        ]
        let url = home.appendingPathComponent(CodexAuthStore.authFileName)
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeStore(codexHome: URL) -> CodexAuthStore {
        CodexAuthStore(
            environment: [CodexAuthStore.codexHomeEnvironmentKey: codexHome.path],
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home"))
    }

    /// A `wham/usage` body in the observed shape.
    private func usageJSON(
        planType: String = "pro",
        primaryUsed: Double = 42,
        primaryResetAt: Int = 1_784_313_283,
        primaryWindowSeconds: Int = 18000,
        secondaryUsed: Double = 7,
        secondaryResetAt: Int = 1_784_913_283,
        secondaryWindowSeconds: Int = 604_800) -> String
    {
        """
        {
          "plan_type": "\(planType)",
          "rate_limit": {
            "primary_window": {
              "used_percent": \(primaryUsed),
              "reset_at": \(primaryResetAt),
              "limit_window_seconds": \(primaryWindowSeconds)
            },
            "secondary_window": {
              "used_percent": \(secondaryUsed),
              "reset_at": \(secondaryResetAt),
              "limit_window_seconds": \(secondaryWindowSeconds)
            }
          },
          "credits": { "has_credits": false, "unlimited": false }
        }
        """
    }

    // MARK: AC2 — JWT claims

    @Test
    func jwtClaimsDecodeTolerantIgnoresUnknownFields() async throws {
        let expiry = Date(timeIntervalSince1970: 1_784_313_283)
        let token = try makeJWT(payload: idTokenPayload(
            email: "  Hugo.Capitelli@Example.COM ",
            expiresAt: expiry,
            extra: [
                // Fields this build has never heard of — must be ignored, not fatal.
                "jti": "abc",
                "at_hash": "def",
                "aud": ["client-id"],
                "organizations": [["id": "org_1", "is_default": true]],
                "some_future_field": ["deeply": ["nested": 1]],
            ]))

        let claims = try #require(CodexJWTClaims.decode(token))

        #expect(claims.email == "Hugo.Capitelli@Example.COM")
        #expect(claims.expiresAt == expiry)
        #expect(claims.plan == .pro)
        #expect(claims.chatGPTAccountID == "acct-123")
    }

    @Test
    func jwtDecodeNeverCrashesOnMalformedPayload() async throws {
        // Not a JWT at all.
        #expect(CodexJWTClaims.decode("") == nil)
        #expect(CodexJWTClaims.decode("only-one-segment") == nil)
        // Payload is not base64url.
        #expect(CodexJWTClaims.decode("header.!!!not-base64!!!.sig") == nil)
        // Payload is valid base64 but not JSON.
        let notJSON = Data("hello".utf8).base64EncodedString()
        #expect(CodexJWTClaims.decode("header.\(notJSON).sig") == nil)
        // Payload is JSON but not an object.
        let jsonArray = Data("[1,2,3]".utf8).base64EncodedString()
        #expect(CodexJWTClaims.decode("header.\(jsonArray).sig") == nil)

        // Payload is an object with every expected field missing — decodes to all-nil claims,
        // and an unknown expiry is explicitly NOT treated as expired.
        let empty = try makeJWT(payload: [:])
        let claims = try #require(CodexJWTClaims.decode(empty))
        #expect(claims.email == nil)
        #expect(claims.expiresAt == nil)
        #expect(claims.plan == nil)
        #expect(claims.isExpired(now: Date()) == false)
    }

    @Test
    func unknownPlanTypeIsKeptVerbatimInsteadOfBeingDropped() async throws {
        let token = try makeJWT(payload: idTokenPayload(plan: "quantum_max"))
        let claims = try #require(CodexJWTClaims.decode(token))
        #expect(claims.plan == .other("quantum_max"))
        #expect(claims.plan?.displayName == "ChatGPT Quantum_Max")
        // Never branded "Claude …" — that would be a lie on a ChatGPT account.
        #expect(CodexPlan.pro.displayName == "ChatGPT Pro")

        // Every known plan round-trips through its raw value, unknown ones included.
        for raw in ["free", "go", "plus", "pro", "team", "business", "enterprise", "edu", "quantum_max"] {
            #expect(CodexPlan(rawValue: raw)?.rawValue == raw)
        }
        #expect(CodexPlan(rawValue: "  PRO ") == .pro)
        #expect(CodexPlan(rawValue: "education") == .edu)
        #expect(CodexPlan(rawValue: "   ") == nil)
    }

    // MARK: AC4.12 — absence is silence

    @Test
    func missingAuthJsonMeansProviderSimplyAbsent() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Note: no auth.json is written.

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        let state = try await fetcher.fetch()

        #expect(state == .absent)
        // Absence must be silent AND free: no error thrown, and no request made.
        #expect(await transport.requestCount == 0)
    }

    // MARK: AC3 — never renew

    @Test
    func neverCallsRefreshEvenWhenTokenExpired() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let expired = Date(timeIntervalSince1970: 1_000_000)
        let accessToken = try makeJWT(payload: ["exp": expired.timeIntervalSince1970])
        let idToken = try makeJWT(payload: idTokenPayload(expiresAt: expired))
        try writeAuthFile(at: home, accessToken: accessToken, idToken: idToken)

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        _ = try await fetcher.fetch(now: Date(timeIntervalSince1970: 2_000_000))

        // The load-bearing assertion: with a dead token, the provider issues ZERO requests.
        // No renewal POST, and not even the usage GET — it stops before the network.
        #expect(await transport.requestCount == 0)
    }

    @Test
    func expiredTokenYieldsTerminalStateNotError() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let expired = Date(timeIntervalSince1970: 1_000_000)
        let accessToken = try makeJWT(payload: ["exp": expired.timeIntervalSince1970])
        try writeAuthFile(
            at: home,
            accessToken: accessToken,
            idToken: try makeJWT(payload: idTokenPayload(expiresAt: expired)))

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        // It returns a state; it does not throw. "Your token died" is an expected situation,
        // not an exceptional one.
        let state = try await fetcher.fetch(now: Date(timeIntervalSince1970: 2_000_000))

        #expect(state == .expired(CodexUsageFetcher.expiredMessage))
        #expect(CodexUsageFetcher.expiredMessage.contains("codex login"))
    }

    @Test
    func expiryGateReadsTheAccessTokenNotTheIdToken() async throws {
        // Measured on a real auth.json: id_token.exp is issued_at + 1 h while access_token.exp
        // is issued_at + 10 days. Gating on the id_token would report "expired" for anyone whose
        // CLI last ran over an hour ago, so the token we *use* is the token we check.
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let accessToken = try makeJWT(payload: ["exp": now.addingTimeInterval(86400).timeIntervalSince1970])
        let staleIDToken = try makeJWT(payload: idTokenPayload(
            expiresAt: now.addingTimeInterval(-3600)))
        try writeAuthFile(at: home, accessToken: accessToken, idToken: staleIDToken)

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        let state = try await fetcher.fetch(now: now)

        guard case let .available(usage) = state else {
            Issue.record("expected .available, got \(state)")
            return
        }
        // The stale id_token still supplies identity and plan — it is an identity assertion,
        // and its freshness says nothing about API access.
        #expect(usage.account.email == "hugo@example.com")
        #expect(await transport.requestCount == 1)
    }

    /// Structural proof of AC3 / AC7.18: no code path in the module can renew anything.
    ///
    /// A behavioural test only proves the paths it exercises. This one reads the module's own
    /// source and asserts the renewal machinery does not exist at all — no `POST`, no
    /// `refresh_token`, and no URL other than the read-only usage endpoint.
    @Test
    func noCodePathInTheCodexModuleCanRenewAToken() async throws {
        let moduleDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/ClaudeBarCore/Codex")

        let files = try FileManager.default
            .contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count == 4, "AC1: the module is exactly 4 files")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Comments are where the prohibition is *explained*, so they are excluded — what
            // must be absent is executable code.
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let name = file.lastPathComponent

            #expect(!code.contains("POST"), "\(name): no POST — renewal is a POST")
            #expect(
                !code.contains("refresh_token"),
                "\(name): the refresh token is never even decoded")
            #expect(
                !code.lowercased().contains("func refresh"),
                "\(name): no renewal entry point")

            // The only endpoint the module may name is the read-only usage URL. The OpenAI
            // claim namespace is allowed because it is a JWT *claim key*, never requested —
            // `https://api.openai.com/auth` is the name of a field, not an address.
            let allowedURLs = [CodexUsageFetcher.usageURL, CodexJWTClaims.openAIAuthClaimKey]
            for line in code.split(separator: "\n") where line.contains("https://") {
                #expect(
                    allowedURLs.contains(where: line.contains),
                    "\(name): unexpected URL literal — \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    // MARK: AC2.6 — window mapping

    @Test
    func rateLimitWindowsMapToSessionAndWeeklyLanes() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date(timeIntervalSince1970: 1_784_000_000)
        try writeAuthFile(
            at: home,
            accessToken: try makeJWT(payload: ["exp": now.addingTimeInterval(86400).timeIntervalSince1970]),
            idToken: try makeJWT(payload: idTokenPayload(expiresAt: now.addingTimeInterval(3600))))

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        let state = try await fetcher.fetch(now: now)
        guard case let .available(usage) = state else {
            Issue.record("expected .available, got \(state)")
            return
        }

        // primary_window → session lane
        #expect(usage.snapshot.session.utilization == 42)
        #expect(usage.snapshot.session.windowMinutes == 300)
        #expect(usage.snapshot.session.resetsAt == Date(timeIntervalSince1970: 1_784_313_283))
        // secondary_window → weekly lane
        #expect(usage.snapshot.weekly.utilization == 7)
        #expect(usage.snapshot.weekly.windowMinutes == 10080)
        #expect(usage.snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1_784_913_283))
        // `used_percent` is a percentage already — never multiplied by 100.
        #expect(usage.snapshot.session.remaining == 58)

        #expect(usage.snapshot.source == .oauth)
        #expect(usage.account.key == AccountKey(provider: .codex, identifier: "hugo@example.com"))
        #expect(usage.plan == .pro)

        // Exactly one GET, at the documented endpoint, with a bearer token.
        #expect(await transport.requestCount == 1)
        #expect(await transport.methods == ["GET"])
        #expect(await transport.urls == [CodexUsageFetcher.usageURL])
        let authorization = await transport.requests.first?
            .value(forHTTPHeaderField: "Authorization")
        #expect(authorization?.hasPrefix("Bearer ") == true)
    }

    @Test
    func missingOrMalformedWindowsDegradeToZeroInsteadOfFailing() async throws {
        // The endpoint is undocumented (R15): a schema change must degrade, never throw.
        let json = """
        { "plan_type": "plus", "rate_limit": { "primary_window": null }, "unknown_field": 1 }
        """
        let response = try CodexUsageFetcher.handle(
            response: .make(status: 200, json: json),
            now: Date())

        #expect(response.plan == .plus)
        #expect(response.rateLimit?.primaryWindow == nil)

        let usage = CodexUsageFetcher.usage(
            from: response,
            record: CodexAuthRecord(accessToken: "tok", idToken: nil, accountID: nil),
            claims: nil,
            now: Date())

        #expect(usage.snapshot.session.utilization == 0)
        #expect(usage.snapshot.weekly.utilization == 0)
        // No e-mail anywhere → opaque key (R12), still comparable and indexable.
        #expect(usage.account.key.provider == .codex)
        #expect(usage.account.hasResolvedEmail == false)
    }

    @Test
    func windowLengthFallsBackToTheLaneDefaultWhenTheApiOmitsIt() async throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1784313283 },
            "secondary_window": { "used_percent": 20, "reset_at": 1784913283 }
          }
        }
        """
        let response = try CodexUsageFetcher.handle(
            response: .make(status: 200, json: json),
            now: Date())
        let usage = CodexUsageFetcher.usage(
            from: response,
            record: CodexAuthRecord(accessToken: "tok", idToken: nil, accountID: nil),
            claims: nil,
            now: Date())

        #expect(usage.snapshot.session.windowMinutes == 300)
        #expect(usage.snapshot.weekly.windowMinutes == 10080)
    }

    @Test
    func httpErrorsMapToThisProvidersOwnUsageError() async throws {
        let now = Date()

        #expect(throws: UsageError.authRequired(CodexUsageFetcher.expiredMessage)) {
            _ = try CodexUsageFetcher.handle(response: .make(status: 401), now: now)
        }
        #expect(throws: UsageError.authRequired(CodexUsageFetcher.expiredMessage)) {
            _ = try CodexUsageFetcher.handle(response: .make(status: 403), now: now)
        }
        #expect(throws: UsageError.rateLimited(retryAfter: now.addingTimeInterval(120))) {
            _ = try CodexUsageFetcher.handle(
                response: .make(status: 429, headers: ["Retry-After": "120"]),
                now: now)
        }
        #expect(throws: (any Error).self) {
            _ = try CodexUsageFetcher.handle(response: .make(status: 500), now: now)
        }
        // A 200 with a body that is not JSON at all is a parse error, not a crash.
        #expect(throws: (any Error).self) {
            _ = try CodexUsageFetcher.handle(
                response: .make(status: 200, json: "<html>nope</html>"),
                now: now)
        }
    }

    // MARK: AC1 / AC2.3 — fingerprint gate

    @Test
    func fingerprintGatePreventsReparseWhenMtimeUnchanged() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let url = try writeAuthFile(
            at: home,
            accessToken: "access-1",
            idToken: try makeJWT(payload: idTokenPayload()))
        let store = makeStore(codexHome: home)

        let first = try await store.load()
        let second = try await store.load()
        let third = try await store.load()

        #expect(first?.accessToken == "access-1")
        #expect(second == first)
        #expect(third == first)
        // Three loads, one parse — a 60 s refresh cycle must not re-decode an unchanged file.
        #expect(await store.parseCount == 1)

        // Rewrite with different content AND a different mtime → the gate opens.
        try writeAuthFile(
            at: home,
            accessToken: "access-2",
            idToken: try makeJWT(payload: idTokenPayload()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: url.path)

        let fourth = try await store.load()
        #expect(fourth?.accessToken == "access-2")
        #expect(await store.parseCount == 2)
    }

    @Test
    func authStoreHonoursCodexHomeAndDefaultsToDotCodex() async throws {
        let codexHome = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let scoped = CodexAuthStore(
            environment: [CodexAuthStore.codexHomeEnvironmentKey: codexHome.path],
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home"))
        #expect(scoped.authFileURL.path == codexHome.appendingPathComponent("auth.json").path)

        // Empty CODEX_HOME must not win over the default.
        let home = URL(fileURLWithPath: "/fake-home")
        let defaulted = CodexAuthStore(
            environment: [CodexAuthStore.codexHomeEnvironmentKey: "  "],
            homeDirectory: home)
        #expect(defaulted.authFileURL.path == "/fake-home/.codex/auth.json")
    }

    @Test
    func corruptAuthJsonSurfacesAsThisProvidersErrorNotSilence() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{ not json at all".utf8)
            .write(to: home.appendingPathComponent(CodexAuthStore.authFileName))

        let transport = RecordingTransport(response: .make(status: 200, json: usageJSON()))
        let fetcher = CodexUsageFetcher(transport: transport, authStore: makeStore(codexHome: home))

        await #expect(throws: (any Error).self) {
            _ = try await fetcher.fetch()
        }
        #expect(await transport.requestCount == 0)
    }

    @Test
    func authJsonWithoutAccessTokenIsMalformedNotUsable() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let payload: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": "x.y.z"]]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: home.appendingPathComponent(CodexAuthStore.authFileName))

        await #expect(throws: CodexAuthError.malformed("tokens.access_token ausente")) {
            _ = try await self.makeStore(codexHome: home).load()
        }
    }

    // MARK: AC4.11 — failure isolation

    @Test
    func codexFailureNeverPropagatesToClaudeSnapshot() async throws {
        // A Codex outage at its worst: unreachable endpoint AND an unusable auth file.
        let codexHome = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try writeAuthFile(
            at: codexHome,
            accessToken: try makeJWT(payload: ["exp": Date().addingTimeInterval(86400).timeIntervalSince1970]),
            idToken: try makeJWT(payload: idTokenPayload()))

        let codexTransport = RecordingTransport(failure: URLError(.notConnectedToInternet))
        let codexFetcher = CodexUsageFetcher(
            transport: codexTransport,
            authStore: makeStore(codexHome: codexHome))

        // A healthy Claude fetch running alongside it.
        let claudeJSON = """
        {
          "five_hour": { "utilization": 33, "resets_at": "2026-07-31T12:00:00.000Z" },
          "seven_day": { "utilization": 11, "resets_at": "2026-08-05T12:00:00.000Z" }
        }
        """
        let claudeFetcher = UsageFetcher(
            transport: StubTransport(response: .make(status: 200, json: claudeJSON)),
            identityResolver: nil)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "claude-token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: "max",
            subscriptionType: nil)

        // A Codex 429 must not be able to block a Claude refresh, so start from a clean gate
        // and assert the Codex path leaves it clean.
        ClaudeOAuthUsageRateLimitGate.resetForTesting()

        // Fan out exactly as EXB-5.3 will: the Codex failure is caught in its own branch.
        async let codexResult: CodexProviderState? = {
            do { return try await codexFetcher.fetch() } catch { return nil }
        }()
        async let claudeSnapshot = claudeFetcher.fetchSnapshot(credentials: credentials)

        let codex = await codexResult
        let claude = try await claudeSnapshot

        // Codex failed…
        #expect(codex == nil, "expected the Codex branch to fail")
        // …and the Claude panel is untouched: no error, no stale marker, full data.
        #expect(claude.error == nil)
        #expect(claude.session.utilization == 33)
        #expect(claude.weekly.utilization == 11)
        #expect(claude.plan == .max)

        // And the reverse direction: the Codex provider owns no Claude state at all. It never
        // touches the Claude rate-limit gate, so its 429 cannot block a Claude refresh.
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: Date()) == nil)
    }
}
