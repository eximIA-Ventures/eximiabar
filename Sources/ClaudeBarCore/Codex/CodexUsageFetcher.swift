import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the Codex provider has to say right now.
///
/// Three states, and only one of them is an error-adjacent one — deliberately: "no Codex here"
/// and "your token died" are both normal, expected situations that deserve their own shape
/// instead of being smuggled through `throw`.
public enum CodexProviderState: Sendable, Equatable {
    /// No `auth.json` — the user does not use Codex. The provider simply does not appear:
    /// no error, no red line, no visual noise (AC4.12).
    case absent
    /// The access token is past its expiry. Terminal, by design: this app will **never** renew
    /// it (AC3). The message tells the user the one command that fixes it.
    case expired(String)
    /// A live reading.
    case available(CodexUsage)
}

/// A resolved Codex reading: who, which plan, and the windows.
public struct CodexUsage: Sendable, Equatable {
    /// Roster identity, keyed `provider: .codex` (EXB-5.1 AC1) — what `EXB-5.3` switches on.
    public let account: AccountIdentity
    /// The Codex plan. Lives here, not in `snapshot.plan`, because `UsageSnapshot.plan` is a
    /// `ClaudePlan` and would render "Claude Pro" over a ChatGPT account.
    public let plan: CodexPlan?
    /// The windows, in the same value type every other panel consumes.
    public let snapshot: UsageSnapshot

    public init(account: AccountIdentity, plan: CodexPlan?, snapshot: UsageSnapshot) {
        self.account = account
        self.plan = plan
        self.snapshot = snapshot
    }
}

/// Fetches Codex usage over OAuth only — no WebView, no `codex app-server` RPC, no cost scan.
///
/// The whole provider is four files because of one discovery: `tokens.id_token` in
/// `~/.codex/auth.json` is a JWT whose payload already carries `email`, `exp` and
/// `chatgpt_plan_type`. Identity and plan therefore cost **zero** extra network calls — one
/// `GET` for the windows and nothing else.
///
/// ## Why this is not a `SourcePlanner` source
///
/// `SourcePlanner`/`FetchPipeline` model several sources of the *same* provider with fallback
/// semantics (`oauth → cli → web`). Codex here has exactly one source, so wiring it into that
/// machinery would buy nothing and would couple two providers' failure modes. It is a plain,
/// independent actor (AC5.13); the fan-out with the Claude fetch is `EXB-5.3`'s job.
///
/// ## Never renews (AC3)
///
/// There is no refresh path in this type, and there is no `POST` anywhere in this module. When
/// the access token is expired the fetcher stops *before* the network call and returns
/// `.expired`. `~/.codex/auth.json` belongs to the `codex` CLI; renewing it behind the CLI's
/// back is its owner's job, not a menu-bar app's.
public actor CodexUsageFetcher {
    public static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    /// The one terminal message for a dead token (AC3.9).
    public static let expiredMessage = "expirado — rode `codex login`"
    public static let defaultUserAgent = "eximiabar"

    private static let timeout: TimeInterval = 30
    private static let sessionWindowMinutes = 300
    private static let weeklyWindowMinutes = 10080

    private let transport: HTTPTransport
    private let authStore: CodexAuthStore
    private let userAgent: String
    private let log = CoreLog.logger(CoreLog.Category.usage)

    public init(
        transport: HTTPTransport = HTTPClient(),
        authStore: CodexAuthStore = CodexAuthStore(),
        userAgent: String = CodexUsageFetcher.defaultUserAgent)
    {
        self.transport = transport
        self.authStore = authStore
        self.userAgent = userAgent
    }

    // MARK: Public API

    /// Reads `auth.json`, decodes the claims, and (only if the token is alive) fetches the
    /// windows.
    ///
    /// - Throws: `UsageError` — and only ever this provider's own. Nothing here touches the
    ///   Claude gates (`ClaudeOAuthUsageRateLimitGate`, `ClaudeOAuthRefreshFailureGate`) or any
    ///   Claude snapshot, so a Codex failure cannot mark the Claude panel stale (AC4.11).
    public func fetch(now: Date = Date()) async throws -> CodexProviderState {
        guard let record = try await self.loadAuthRecord() else { return .absent }

        // Identity and plan come from the id_token's claims — no network call (AC2.4).
        let identityClaims = record.idToken.flatMap(CodexJWTClaims.decode)

        // VALIDITY GATE — read the *access* token, not the id_token.
        //
        // Measured on a real `~/.codex/auth.json`: both tokens are issued at the same instant,
        // but `id_token.exp` is issued_at + 1 h while `access_token.exp` is issued_at + 10 days.
        // The id_token is an identity assertion whose freshness says nothing about API access;
        // the access token is the one actually sent as `Authorization: Bearer`. Gating on the
        // id_token would declare "expired" for anyone whose CLI last ran over an hour ago —
        // i.e. almost always. So the token we are about to *use* is the token we check.
        let accessClaims = CodexJWTClaims.decode(record.accessToken)
        if accessClaims?.isExpired(now: now) == true {
            self.log.debug("Codex access token expired — terminal state, no renewal attempted")
            return .expired(Self.expiredMessage)
        }

        let response = try await self.fetchUsage(
            accessToken: record.accessToken,
            accountID: record.accountID ?? identityClaims?.chatGPTAccountID,
            now: now)

        return .available(Self.usage(
            from: response,
            record: record,
            claims: identityClaims,
            now: now))
    }

    /// Fetches and decodes the raw usage payload (no mapping).
    public func fetchUsage(
        accessToken: String,
        accountID: String?,
        now: Date = Date()) async throws -> CodexUsageResponse
    {
        guard let url = URL(string: Self.usageURL) else {
            throw UsageError.networkError("URL de uso do Codex inválida")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let response: HTTPResponse
        do {
            response = try await self.transport.send(request)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.networkError(error.localizedDescription)
        }

        return try Self.handle(response: response, now: now)
    }

    // MARK: HTTP handling

    static func handle(response: HTTPResponse, now: Date) throws -> CodexUsageResponse {
        switch response.statusCode {
        case 200 ... 299:
            do {
                return try JSONDecoder().decode(CodexUsageResponse.self, from: response.data)
            } catch {
                throw UsageError.parseError(error.localizedDescription)
            }
        case 401, 403:
            // Still no renewal: the fix is the user running `codex login` (AC3).
            throw UsageError.authRequired(Self.expiredMessage)
        case 429:
            let retryAfter = UsageFetcher.retryAfterDate(from: response, now: now)
                ?? now.addingTimeInterval(300)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.networkError("HTTP \(response.statusCode) \(body)")
        }
    }

    // MARK: Mapping

    static func usage(
        from response: CodexUsageResponse,
        record: CodexAuthRecord,
        claims: CodexJWTClaims?,
        now: Date) -> CodexUsage
    {
        // primary → session, secondary → weekly (AC2.6). A missing window renders 0 %, which is
        // what the panel already does for every other provider.
        let session = response.rateLimit?.primaryWindow?
            .rateWindow(fallbackWindowMinutes: Self.sessionWindowMinutes)
            ?? RateWindow(utilization: 0, resetsAt: nil, windowMinutes: Self.sessionWindowMinutes)
        let weekly = response.rateLimit?.secondaryWindow?
            .rateWindow(fallbackWindowMinutes: Self.weeklyWindowMinutes)
            ?? RateWindow(utilization: 0, resetsAt: nil, windowMinutes: Self.weeklyWindowMinutes)

        let account = Self.identity(claims: claims, record: record)
        // The API's `plan_type` wins over the token claim: one says "now", the other says
        // "when this token was issued".
        let plan = response.plan ?? claims?.plan

        let snapshot = UsageSnapshot(
            session: session,
            weekly: weekly,
            sonnet: nil,
            opus: nil,
            dailyRoutines: nil,
            extraUsage: nil,
            // Left nil on purpose: `plan` here is a `ClaudePlan`, whose labels all read
            // "Claude …". The Codex plan is carried by `CodexUsage.plan` instead.
            plan: nil,
            identity: UsageSnapshot.Identity(
                name: account.displayName ?? account.email,
                email: account.email),
            updatedAt: now,
            source: .oauth,
            error: nil)

        return CodexUsage(account: account, plan: plan, snapshot: snapshot)
    }

    /// Builds the roster identity. With no e-mail in the claims, falls back to an opaque digest
    /// of the access token — the same R12 contract `ClaudeIdentityResolver` uses, so the account
    /// stays comparable and indexable even when it cannot be named.
    static func identity(claims: CodexJWTClaims?, record: CodexAuthRecord) -> AccountIdentity {
        let email = claims?.email.map(AccountKey.normalize) ?? ""
        let accountUUID = record.accountID ?? claims?.chatGPTAccountID

        guard !email.isEmpty else {
            let digest = CredentialsStore.sha256Prefix(Data(record.accessToken.utf8))
            return AccountIdentity(
                key: AccountKey(provider: .codex, identifier: digest),
                email: "",
                displayName: "Codex",
                organizationName: nil,
                accountUUID: accountUUID)
        }

        return AccountIdentity(
            key: AccountKey(provider: .codex, identifier: email),
            email: email,
            displayName: nil,
            organizationName: nil,
            accountUUID: accountUUID)
    }

    // MARK: Auth

    private func loadAuthRecord() async throws -> CodexAuthRecord? {
        do {
            return try await self.authStore.load()
        } catch let error as CodexAuthError {
            // A corrupt auth.json is this provider's problem alone — it surfaces as this
            // provider's own `UsageError` and never reaches the Claude panel (AC4.11).
            throw UsageError.parseError(error.localizedDescription)
        }
    }
}
