import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches `GET /api/oauth/usage`, decodes the response, and maps it to a `UsageSnapshot`.
///
/// All network and decode work runs inside this actor (AC16). Headers are exact (AC5),
/// HTTP errors map to `UsageError` (AC11), and the 429 gate is honored (AC12).
public actor UsageFetcher {
    public static let baseURL = "https://api.anthropic.com"
    public static let usagePath = "/api/oauth/usage"
    public static let betaHeader = "oauth-2025-04-20"
    public static let fallbackUserAgentVersion = "2.1.0"
    private static let timeout: TimeInterval = 30

    private let transport: HTTPTransport
    private let userAgentVersion: String
    private let log = CoreLog.logger(CoreLog.Category.usage)

    public init(
        transport: HTTPTransport = HTTPClient(),
        userAgentVersion: String? = nil)
    {
        self.transport = transport
        self.userAgentVersion = Self.normalizedVersion(userAgentVersion)
            ?? Self.fallbackUserAgentVersion
    }

    /// Fetches and maps a snapshot for the given credentials.
    ///
    /// - Parameter mode: `.userInitiated` ignores the 429 gate; `.auto` short-circuits
    ///   while the gate is active.
    public func fetchSnapshot(
        credentials: ClaudeOAuthCredentials,
        mode: FetchMode = .auto,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        let response = try await self.fetchUsage(
            accessToken: credentials.accessToken,
            mode: mode,
            now: now)
        return UsageSnapshot.from(
            response,
            rateLimitTier: credentials.rateLimitTier,
            subscriptionType: credentials.subscriptionType,
            source: .oauth,
            now: now)
    }

    /// Fetches and decodes the raw usage response (no mapping).
    public func fetchUsage(
        accessToken: String,
        mode: FetchMode = .auto,
        now: Date = Date()) async throws -> OAuthUsageResponse
    {
        // 429 gate (AC12): background short-circuits; user-initiated ignores it.
        let phase: RefreshPhase = mode == .userInitiated ? .userInitiated : .background
        if let blockedUntil = ClaudeOAuthUsageRateLimitGate.blockedUntil(phase: phase, now: now) {
            throw UsageError.rateLimited(retryAfter: blockedUntil)
        }

        guard let url = URL(string: Self.baseURL + Self.usagePath) else {
            throw UsageError.networkError("Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(self.userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try await self.transport.send(request)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.networkError(error.localizedDescription)
        }

        return try self.handle(response: response, now: now)
    }

    // MARK: HTTP handling (AC11)

    private func handle(response: HTTPResponse, now: Date) throws -> OAuthUsageResponse {
        switch response.statusCode {
        case 200:
            let usage = try Self.decode(response.data)
            ClaudeOAuthUsageRateLimitGate.recordSuccess()
            return usage
        case 401:
            throw UsageError.authRequired("Run `claude` to re-authenticate")
        case 403:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            if body.contains("user:profile") || body.lowercased().contains("scope") {
                throw UsageError.scopeMissing("Run `claude setup-token`")
            }
            throw UsageError.scopeMissing("Run `claude setup-token`")
        case 429:
            let retryAfter = Self.retryAfterDate(from: response, now: now)
            ClaudeOAuthUsageRateLimitGate.recordRateLimit(retryAfter: retryAfter, now: now)
            let blocked = ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: now)
                ?? retryAfter
                ?? now.addingTimeInterval(300)
            throw UsageError.rateLimited(retryAfter: blocked)
        default:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.networkError("HTTP \(response.statusCode) \(body)")
        }
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> OAuthUsageResponse {
        do {
            return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        } catch {
            throw UsageError.parseError(error.localizedDescription)
        }
    }

    // MARK: Retry-After (AC11)

    /// Parses the `Retry-After` header: integer seconds, or an RFC date; fallback 300 s.
    static func retryAfterDate(from response: HTTPResponse, now: Date) -> Date? {
        guard let raw = response.headerValue("Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }

    // MARK: User-Agent version

    static func normalizedVersion(_ versionString: String?) -> String? {
        guard let raw = versionString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
