import ClaudeBarCore
import Foundation
import os

/// Wires the `ClaudeBarCore` fetch pipeline into the `AppState.Fetch` closure (AC1: all fetch
/// logic stays in Core; `AppState` only consumes the resulting `DisplaySnapshot`).
///
/// One `LiveUsageProvider` owns the long-lived Core actors (`CredentialsStore`, `UsageFetcher`,
/// `FetchPipeline`). The pipeline's actor provides the coalescing guarantee (AC5); `AppState`'s
/// own coalescing sits on top as the UI-facing layer.
///
/// `Sendable` so its `fetch` closure can cross actor boundaries into `AppState`.
struct LiveUsageProvider: Sendable {
    private let credentials: CredentialsStore
    private let fetcher: UsageFetcher
    private let pipeline: FetchPipeline
    private let log = Logger(subsystem: CoreLog.subsystem, category: "provider")

    init(
        credentials: CredentialsStore = CredentialsStore(),
        fetcher: UsageFetcher = UsageFetcher())
    {
        self.credentials = credentials
        self.fetcher = fetcher
        // The pipeline's OAuth fetch: load credentials (honouring the active phase for keychain
        // prompts), then fetch + map a snapshot. NEVER consumes the CLI refresh token — the fetch
        // path only reads usage; token refresh is delegated by `RefreshCoordinator` in Core.
        self.pipeline = FetchPipeline(oauthFetch: { [credentials, fetcher] mode in
            let phase: RefreshPhase = mode == .userInitiated ? .userInitiated : RefreshContext.phase
            let record = try await credentials.load(phase: phase)
            return try await fetcher.fetchSnapshot(credentials: record.credentials, mode: mode)
        })
    }

    /// The `AppState.Fetch` closure. Runs entirely off-MainActor.
    func makeFetch() -> AppState.Fetch {
        let pipeline = self.pipeline
        let credentials = self.credentials
        let log = self.log
        return { phase in
            // Plan against what is plausibly available. In S4 only OAuth is wired; CLI lands in S6.
            let hasOAuth = (try? await credentials.load(phase: .background)) != nil
            let plan = SourcePlanner.plan(input: SourcePlanningInput(
                selectedSource: nil,
                hasOAuthCredentials: hasOAuth,
                hasCLI: false,
                hasWebSession: false))

            let result = await pipeline.run(plan: plan, mode: phase.fetchMode)
            switch result {
            case let .success(usage):
                return DisplaySnapshot.from(usage, cost: nil, isRefreshing: false)
            case let .failure(error):
                log.error("fetch failed: \(error.message, privacy: .public)")
                // Attach the error to a placeholder so the icon can render the error state (AC8).
                let errored = UsageSnapshot(
                    session: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 300),
                    weekly: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 10080),
                    sonnet: nil,
                    dailyRoutines: nil,
                    extraUsage: nil,
                    plan: nil,
                    identity: nil,
                    updatedAt: Date(),
                    source: .oauth,
                    error: error)
                return DisplaySnapshot.from(errored, cost: nil, isRefreshing: false)
            }
        }
    }
}
