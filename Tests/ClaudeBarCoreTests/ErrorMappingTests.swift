import Foundation
import Testing
@testable import ClaudeBarCore

/// AC17d: HTTP error mapping for 401 / 403 / 429.
///
/// Serialized because the 429 rate-limit gate is backed by `UserDefaults.standard`
/// (process-global). Running these in parallel would race on the shared gate state.
@Suite(.serialized)
struct ErrorMappingTests {
    private func makeCredentials() -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: Date.distantFuture,
            scopes: ["user:profile"],
            rateLimitTier: "claude_pro")
    }

    @Test
    func unauthorizedMapsToAuthRequired() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let fetcher = UsageFetcher(transport: StubTransport(response: .make(status: 401)))
        await #expect(throws: UsageError.self) {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .userInitiated)
        }
        do {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .userInitiated)
            Issue.record("expected throw")
        } catch let error as UsageError {
            guard case let .authRequired(message) = error else {
                Issue.record("expected .authRequired, got \(error)")
                return
            }
            #expect(message.contains("claude"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func forbiddenScopeMapsToScopeMissing() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let body = #"{"error":{"message":"missing scope user:profile"}}"#
        let fetcher = UsageFetcher(transport: StubTransport(response: .make(status: 403, json: body)))
        do {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .userInitiated)
            Issue.record("expected throw")
        } catch let error as UsageError {
            guard case let .scopeMissing(message) = error else {
                Issue.record("expected .scopeMissing, got \(error)")
                return
            }
            #expect(message.contains("claude setup-token"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func rateLimitedParsesRetryAfterSeconds() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fetcher = UsageFetcher(transport: StubTransport(
            response: .make(status: 429, headers: ["Retry-After": "120"])))
        do {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .userInitiated, now: now)
            Issue.record("expected throw")
        } catch let error as UsageError {
            guard case let .rateLimited(retryAfter) = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == now.addingTimeInterval(120))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
    }

    @Test
    func rateLimitedFallsBackTo300sWithoutHeader() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fetcher = UsageFetcher(transport: StubTransport(response: .make(status: 429)))
        do {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .userInitiated, now: now)
            Issue.record("expected throw")
        } catch let error as UsageError {
            guard case let .rateLimited(retryAfter) = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == now.addingTimeInterval(300))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
    }

    @Test
    func retryAfterParsesIntegerSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        let response = HTTPResponse.make(status: 429, headers: ["Retry-After": "60"])
        let parsed = UsageFetcher.retryAfterDate(from: response, now: now)
        #expect(parsed == now.addingTimeInterval(60))
    }

    @Test
    func retryAfterParsesRFCDate() {
        let now = Date(timeIntervalSince1970: 0)
        let response = HTTPResponse.make(
            status: 429,
            headers: ["Retry-After": "Wed, 21 Oct 2025 07:28:00 GMT"])
        let parsed = UsageFetcher.retryAfterDate(from: response, now: now)
        #expect(parsed != nil)
    }

    // MARK: AC12 — 429 gate: background short-circuits, user-initiated ignores

    @Test
    func backgroundRefreshShortCircuitsWhileGateActive() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let now = Date(timeIntervalSince1970: 3_000_000)
        // Prime the gate with a future retry-after.
        ClaudeOAuthUsageRateLimitGate.recordRateLimit(
            retryAfter: now.addingTimeInterval(600),
            now: now)

        // A background fetch should short-circuit with .rateLimited even though the
        // transport would otherwise return 200.
        let fetcher = UsageFetcher(transport: StubTransport(
            response: .make(status: 200, json: #"{"five_hour":{"utilization":1}}"#)))
        do {
            _ = try await fetcher.fetchUsage(accessToken: "tok", mode: .auto, now: now)
            Issue.record("expected throw")
        } catch let error as UsageError {
            guard case .rateLimited = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
    }

    @Test
    func userInitiatedRefreshIgnoresGate() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        let now = Date(timeIntervalSince1970: 4_000_000)
        ClaudeOAuthUsageRateLimitGate.recordRateLimit(
            retryAfter: now.addingTimeInterval(600),
            now: now)

        let fetcher = UsageFetcher(transport: StubTransport(
            response: .make(status: 200, json: #"{"five_hour":{"utilization":7}}"#)))
        // User-initiated must bypass the gate and succeed.
        let response = try await fetcher.fetchUsage(
            accessToken: "tok",
            mode: .userInitiated,
            now: now)
        #expect(response.fiveHour?.utilization == 7)
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
    }
}
