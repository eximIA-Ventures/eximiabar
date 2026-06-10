import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Routes token refresh based on credential ownership (AC13). This is the most
/// safety-critical component in the story.
///
/// CRITICAL CONTRACT:
///  - `owner == .claudeCLI`  → NEVER POST to the refresh endpoint. Refresh is delegated:
///    run `claude /status` in a PTY under the watchdog, poll the keychain fingerprint at
///    0.2 / 0.5 / 0.8 s, then re-read without prompt. Consuming the CLI's refresh token
///    breaks the user's Claude Code login (regression #1161). Cooldown: 5 min on success,
///    20 s on failure.
///  - `owner == .claudebar` → direct refresh: POST
///    `https://platform.claude.com/v1/oauth/token`.
///  - `owner == .environment` → no refresh.
public actor RefreshCoordinator {
    public static let tokenRefreshEndpoint = "https://platform.claude.com/v1/oauth/token"
    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let delegatedSuccessCooldown: TimeInterval = 60 * 5 // 5 min
    private static let delegatedFailureCooldown: TimeInterval = 20 // 20 s
    private static let pollDelays: [TimeInterval] = [0.2, 0.5, 0.8]

    public enum Outcome: Sendable, Equatable {
        /// Delegated refresh observed a fingerprint change — credentials should be re-read.
        case delegatedRefreshed
        /// Direct refresh succeeded; new credentials are attached.
        case directRefreshed(ClaudeOAuthCredentials)
        /// No refresh is performed for this owner.
        case noRefresh
        /// Refresh was skipped due to an active cooldown / gate.
        case skipped(String)
        /// Refresh failed.
        case failed(String)
    }

    /// Result of a delegated (`claude /status`) attempt — abstracted so it can be tested
    /// without spawning a subprocess.
    public typealias DelegatedProbe = @Sendable (_ timeout: TimeInterval) async -> Bool

    private let transport: HTTPTransport
    private let clientID: String
    /// Injected fingerprint provider — used to detect keychain change after delegation.
    private let fingerprintProvider: @Sendable () -> String?
    /// Injected delegated probe (default: spawn `claude /status` in a PTY).
    private let delegatedProbe: DelegatedProbe
    private let log = CoreLog.logger(CoreLog.Category.refresh)

    private var lastDelegatedAttemptAt: Date?
    private var lastDelegatedCooldown: TimeInterval?

    public init(
        transport: HTTPTransport = HTTPClient(),
        clientID: String = RefreshCoordinator.defaultClientID,
        fingerprintProvider: @escaping @Sendable () -> String? = { nil },
        delegatedProbe: DelegatedProbe? = nil)
    {
        self.transport = transport
        self.clientID = clientID
        self.fingerprintProvider = fingerprintProvider
        // Default delegated probe (AC4): run `claude /status` through the full `CLISession` PTY +
        // watchdog flow. This NEVER POSTs to the refresh endpoint — it only nudges the CLI to
        // rotate its own token; success is detected by the keychain fingerprint change below.
        self.delegatedProbe = delegatedProbe ?? { timeout in
            guard let claudePath = CLISession.resolveBinaryPath("claude") else { return false }
            let session = CLISession()
            do {
                _ = try await session.fetchStatus(claudePath: claudePath, timeout: timeout)
                return true
            } catch {
                return false
            }
        }
    }

    /// Refreshes the token for the given record, honoring the ownership contract (AC13).
    public func refresh(
        record: ClaudeOAuthCredentialRecord,
        now: Date = Date()) async -> Outcome
    {
        switch record.owner {
        case .environment:
            return .noRefresh

        case .claudeCLI:
            return await self.delegatedRefresh(now: now)

        case .claudebar:
            return await self.directRefresh(credentials: record.credentials, now: now)
        }
    }

    // MARK: Delegated refresh (.claudeCLI) — NEVER POSTs

    private func delegatedRefresh(now: Date) async -> Outcome {
        if let last = self.lastDelegatedAttemptAt,
           let cooldown = self.lastDelegatedCooldown,
           now.timeIntervalSince(last) < cooldown
        {
            return .skipped("Delegated refresh cooldown active")
        }

        let fingerprintBefore = self.fingerprintProvider()

        // Spawn `claude /status` (PTY under watchdog). This NEVER touches the refresh
        // endpoint — it nudges the CLI to refresh its own token.
        let probeSucceeded = await self.delegatedProbe(8)

        // Poll the keychain fingerprint at 0.2 / 0.5 / 0.8 s for a change.
        var observedChange = false
        for delay in Self.pollDelays {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let current = self.fingerprintProvider()
            if let current, current != fingerprintBefore {
                observedChange = true
                break
            }
        }

        self.lastDelegatedAttemptAt = now
        if observedChange {
            self.lastDelegatedCooldown = Self.delegatedSuccessCooldown
            return .delegatedRefreshed
        } else {
            self.lastDelegatedCooldown = Self.delegatedFailureCooldown
            return probeSucceeded
                ? .failed("Delegated probe ran but no fingerprint change observed")
                : .failed("Delegated probe failed to run")
        }
    }

    // MARK: Direct refresh (.claudebar) — POSTs to the OAuth endpoint

    private func directRefresh(
        credentials: ClaudeOAuthCredentials,
        now: Date) async -> Outcome
    {
        guard ClaudeOAuthRefreshFailureGate.shouldAttempt(now: now) else {
            return .skipped("Refresh-failure gate active")
        }
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failed("No refresh token")
        }

        guard let url = URL(string: Self.tokenRefreshEndpoint) else {
            return .failed("Invalid refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "grant_type=refresh_token"
            + "&refresh_token=\(Self.formEncode(refreshToken))"
            + "&client_id=\(Self.formEncode(self.clientID))"
        request.httpBody = Data(body.utf8)

        let response: HTTPResponse
        do {
            response = try await self.transport.send(request)
        } catch {
            ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: now)
            return .failed(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            guard let refreshed = Self.parseRefreshResponse(response.data, fallback: credentials)
            else {
                ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: now)
                return .failed("Could not decode refresh response")
            }
            ClaudeOAuthRefreshFailureGate.recordSuccess()
            return .directRefreshed(refreshed)
        case 400, 401:
            // invalid_grant → terminal block (AC14).
            ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: now)
            return .failed("invalid_grant")
        default:
            ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: now)
            return .failed("HTTP \(response.statusCode)")
        }
    }

    // MARK: Helpers

    private static func parseRefreshResponse(
        _ data: Data,
        fallback: ClaudeOAuthCredentials) -> ClaudeOAuthCredentials?
    {
        struct RefreshResponse: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              let accessToken = decoded.access_token, !accessToken.isEmpty
        else { return nil }
        let expiresAt = decoded.expires_in.map { Date().addingTimeInterval($0) }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: decoded.refresh_token ?? fallback.refreshToken,
            expiresAt: expiresAt ?? fallback.expiresAt,
            scopes: fallback.scopes,
            rateLimitTier: fallback.rateLimitTier,
            subscriptionType: fallback.subscriptionType)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
