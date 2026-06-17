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
    /// The cost-scan settings read fresh per fetch (EXB-1.7 AC9/AC11), off-MainActor.
    struct CostSettings: Sendable {
        let enabled: Bool
        let days: Int
    }

    private let credentials: CredentialsStore
    private let fetcher: UsageFetcher
    private let pipeline: FetchPipeline
    /// Resolves the configured `claude` binary path (Settings override → PATH). Read per fetch so a
    /// settings change is honoured immediately.
    private let claudeBinaryProvider: @Sendable () -> String?
    /// Resolves the live cost-scan settings (`costEnabled` / `costDays`). Read per fetch so a
    /// settings change is honoured immediately (EXB-1.7 AC9/AC11).
    private let costSettingsProvider: @Sendable () -> CostSettings
    /// The local JSONL cost scanner (EXB-1.7). Invoked off-MainActor after each successful fetch.
    private let costScanner: CostScanner
    private let log = Logger(subsystem: CoreLog.subsystem, category: "provider")

    init(
        credentials: CredentialsStore = CredentialsStore(),
        fetcher: UsageFetcher = UsageFetcher(),
        claudeBinaryProvider: @escaping @Sendable () -> String? = { nil },
        costSettingsProvider: @escaping @Sendable () -> CostSettings = { CostSettings(enabled: false, days: 30) },
        costScanner: CostScanner = .shared)
    {
        self.credentials = credentials
        self.fetcher = fetcher
        self.claudeBinaryProvider = claudeBinaryProvider
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.pipeline = Self.makePipeline(
            credentials: credentials,
            fetcher: fetcher,
            claudeBinaryProvider: claudeBinaryProvider)
    }

    /// EXB-1.5 AC11: build the provider with a live keychain-prompt-policy source. The
    /// `promptPolicyProvider` is read off-MainActor inside `CredentialsStore` on every fetch, so a
    /// settings change is honoured immediately with no memoization.
    init(
        promptPolicyProvider: @escaping @Sendable () -> PromptPolicy,
        readStrategyProvider: @escaping @Sendable () -> KeychainReadStrategy = { .securityCLIPrimary },
        fetcher: UsageFetcher = UsageFetcher(),
        claudeBinaryProvider: @escaping @Sendable () -> String? = { nil },
        costSettingsProvider: @escaping @Sendable () -> CostSettings = { CostSettings(enabled: false, days: 30) },
        costScanner: CostScanner = .shared)
    {
        let credentials = CredentialsStore(
            promptPolicyProvider: promptPolicyProvider,
            readStrategyProvider: readStrategyProvider)
        self.credentials = credentials
        self.fetcher = fetcher
        self.claudeBinaryProvider = claudeBinaryProvider
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.pipeline = Self.makePipeline(
            credentials: credentials,
            fetcher: fetcher,
            claudeBinaryProvider: claudeBinaryProvider)
    }

    private static func makePipeline(
        credentials: CredentialsStore,
        fetcher: UsageFetcher,
        claudeBinaryProvider: @escaping @Sendable () -> String?) -> FetchPipeline
    {
        // One long-lived CLI session (the actor serializing `claude` processes — at most one alive).
        let cliSession = CLISession()
        // The pipeline's OAuth fetch: load credentials (honouring the active phase for keychain
        // prompts), then fetch + map a snapshot. NEVER consumes the CLI refresh token — the fetch
        // path only reads usage; token refresh is delegated by `RefreshCoordinator` in Core.
        return FetchPipeline(
            oauthFetch: { mode in
                let phase: RefreshPhase = mode == .userInitiated
                    ? .userInitiated : RefreshContext.phase
                let record = try await credentials.load(phase: phase)
                return try await fetcher.fetchSnapshot(credentials: record.credentials, mode: mode)
            },
            cliFetch: { mode in
                // CLI fallback (EXB-1.6). Resolve the binary fresh each call; if absent, surface
                // `cliNotFound` so the pipeline records it and the app stays on OAuth.
                guard let claudePath = claudeBinaryProvider() else {
                    throw UsageError.networkError("cliNotFound: no claude binary configured")
                }
                let phase: RefreshPhase = mode == .userInitiated
                    ? .userInitiated : RefreshContext.phase
                let strategy = CLIFetchStrategy(claudePath: claudePath, session: cliSession)
                return try await strategy.fetch(phase: phase)
            })
    }

    /// The `AppState.Fetch` closure. Runs entirely off-MainActor.
    func makeFetch() -> AppState.Fetch {
        let pipeline = self.pipeline
        let credentials = self.credentials
        let claudeBinaryProvider = self.claudeBinaryProvider
        let costSettingsProvider = self.costSettingsProvider
        let costScanner = self.costScanner
        let log = self.log

        // EXB-1.7: scan local JSONL logs for an estimated cost, gated by `costEnabled` (AC11). Runs
        // on the `CostScanner` actor's executor, called from `AppState`'s detached fetch task — so
        // no file I/O ever touches the MainActor (AC10/AC13). Returns `nil` when disabled (AC11).
        @Sendable func scanCost() async -> ProviderCost? {
            let settings = costSettingsProvider()
            guard settings.enabled else { return nil }
            return await costScanner.scan(costDays: settings.days)
        }

        return { phase in
            // Plan against what is plausibly available: OAuth from a credential probe, CLI from a
            // resolvable `claude` binary (Settings override → PATH). The planner orders
            // OAuth → CLI → Web; the pipeline falls through to CLI on an OAuth auth/scope failure.
            let hasOAuth = (try? await credentials.load(phase: .background)) != nil
            let hasCLI = claudeBinaryProvider() != nil
            let plan = SourcePlanner.plan(input: SourcePlanningInput(
                selectedSource: nil,
                hasOAuthCredentials: hasOAuth,
                hasCLI: hasCLI,
                hasWebSession: false))

            let result = await pipeline.run(plan: plan, mode: phase.fetchMode)
            // EXB-1.7: fold the local cost scan into the snapshot. The scan is independent of the
            // usage fetch — even on a usage failure we still surface a local cost estimate (AC10).
            let cost = await scanCost()
            switch result {
            case let .success(usage):
                return DisplaySnapshot.from(usage, cost: cost, isRefreshing: false)
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
                return DisplaySnapshot.from(errored, cost: cost, isRefreshing: false)
            }
        }
    }
}
