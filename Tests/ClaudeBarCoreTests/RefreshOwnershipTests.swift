import Foundation
import os.lock
import Testing
@testable import ClaudeBarCore

/// AC13 + DoD: the refresh-token ownership contract.
///
/// CRITICAL: when `owner == .claudeCLI`, the refresh endpoint MUST NOT be called.
/// We assert this with a transport that records every request — for the CLI path it must
/// stay empty.
///
/// Serialized because `ClaudeOAuthRefreshFailureGate` is backed by `UserDefaults.standard`.
@Suite(.serialized)
struct RefreshOwnershipTests {
    /// Records every request it sees; never reaches the network.
    final class RecordingTransport: HTTPTransport, Sendable {
        private let urls = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let cannedResponse: HTTPResponse

        init(cannedResponse: HTTPResponse) {
            self.cannedResponse = cannedResponse
        }

        var requestedURLs: [URL] {
            self.urls.withLock { $0 }
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            if let url = request.url {
                self.urls.withLock { $0.append(url) }
            }
            return self.cannedResponse
        }
    }

    private func cliRecord() -> ClaudeOAuthCredentialRecord {
        ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "cli-token",
                refreshToken: "cli-refresh",
                expiresAt: Date(),
                scopes: [],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .credentialsFile)
    }

    @Test
    func claudeCLIOwnerNeverCallsRefreshEndpoint() async {
        let transport = RecordingTransport(cannedResponse: .make(status: 200))
        // A delegated probe that does nothing (no real PTY in tests).
        let coordinator = RefreshCoordinator(
            transport: transport,
            fingerprintProvider: { "static-fingerprint" }, // never changes → no success
            delegatedProbe: { _ in true })

        let outcome = await coordinator.refresh(record: cliRecord())

        // The HARD assertion: zero network requests for the CLI owner.
        #expect(transport.requestedURLs.isEmpty)
        // Fingerprint never changed, so the delegated attempt reports failure (not a POST).
        switch outcome {
        case .failed, .delegatedRefreshed, .skipped:
            break // any of these is acceptable; what matters is no POST happened
        case .directRefreshed, .noRefresh:
            Issue.record("CLI owner must take the delegated path, got \(outcome)")
        }
    }

    @Test
    func claudeCLIDelegatedRefreshSucceedsOnFingerprintChange() async {
        let transport = RecordingTransport(cannedResponse: .make(status: 200))
        // Fingerprint flips after the first read → observed change.
        let counter = Counter()
        let coordinator = RefreshCoordinator(
            transport: transport,
            fingerprintProvider: { counter.next() > 0 ? "after" : "before" },
            delegatedProbe: { _ in true })

        let outcome = await coordinator.refresh(record: cliRecord())
        #expect(transport.requestedURLs.isEmpty)
        #expect(outcome == .delegatedRefreshed)
    }

    @Test
    func environmentOwnerDoesNoRefresh() async {
        let transport = RecordingTransport(cannedResponse: .make(status: 200))
        let coordinator = RefreshCoordinator(transport: transport)
        let record = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "env",
                refreshToken: nil,
                expiresAt: nil,
                scopes: [],
                rateLimitTier: nil),
            owner: .environment,
            source: .environment)
        let outcome = await coordinator.refresh(record: record)
        #expect(outcome == .noRefresh)
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test
    func claudebarOwnerCallsRefreshEndpointDirectly() async {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        let json = #"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#
        let transport = RecordingTransport(cannedResponse: .make(status: 200, json: json))
        let coordinator = RefreshCoordinator(transport: transport)
        let record = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "old",
                refreshToken: "old-refresh",
                expiresAt: Date(),
                scopes: [],
                rateLimitTier: "claude_pro"),
            owner: .claudebar,
            source: .cacheKeychain)
        let outcome = await coordinator.refresh(record: record)

        // The direct path MUST hit the platform OAuth token endpoint.
        #expect(transport.requestedURLs.count == 1)
        #expect(transport.requestedURLs.first?.absoluteString
            == RefreshCoordinator.tokenRefreshEndpoint)
        guard case let .directRefreshed(credentials) = outcome else {
            Issue.record("expected .directRefreshed, got \(outcome)")
            ClaudeOAuthRefreshFailureGate.resetForTesting()
            return
        }
        #expect(credentials.accessToken == "new-token")
        ClaudeOAuthRefreshFailureGate.resetForTesting()
    }

    @Test
    func claudebarInvalidGrantTriggersTerminalBlock() async {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        let transport = RecordingTransport(cannedResponse: .make(status: 400))
        let coordinator = RefreshCoordinator(transport: transport)
        let record = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "old",
                refreshToken: "old-refresh",
                expiresAt: Date(),
                scopes: [],
                rateLimitTier: nil),
            owner: .claudebar,
            source: .cacheKeychain)
        let outcome = await coordinator.refresh(record: record)
        guard case let .failed(reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            ClaudeOAuthRefreshFailureGate.resetForTesting()
            return
        }
        #expect(reason == "invalid_grant")
        // The gate must now be terminally blocked.
        if case .terminal = ClaudeOAuthRefreshFailureGate.currentBlockStatus() {
            // ok
        } else {
            Issue.record("expected terminal block after invalid_grant")
        }
        ClaudeOAuthRefreshFailureGate.resetForTesting()
    }
}

/// Tiny thread-safe counter for fingerprint-flip simulation.
private final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock<Int>(initialState: 0)
    func next() -> Int {
        self.value.withLock { current in
            let result = current
            current += 1
            return result
        }
    }
}
