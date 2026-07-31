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
    /// The account roster (EXB-5.2). Read once per cycle for the archived panes and the live
    /// account's identity — **index file only, no keychain, no fetch**. `nil` outside the app's real
    /// construction path, which yields a single-account workspace exactly as before.
    private let accountRoster: AccountRosterStore?
    /// The Codex provider (EXB-5.4). `nil` when not wired; a user without `~/.codex/auth.json`
    /// simply produces no Codex pane.
    private let codexFetcher: CodexUsageFetcher?
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
        costScanner: CostScanner = .shared,
        accountRoster: AccountRosterStore? = nil,
        codexFetcher: CodexUsageFetcher? = nil)
    {
        self.credentials = credentials
        self.fetcher = fetcher
        self.claudeBinaryProvider = claudeBinaryProvider
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.accountRoster = accountRoster
        self.codexFetcher = codexFetcher
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
        // EXB-5.2 AC4: the roster and the identity resolver are wired only here, on the app's
        // real construction path. Every other `CredentialsStore` (tests, previews) keeps the
        // `nil` defaults and captures nothing.
        let roster = AccountRosterStore()
        let credentials = CredentialsStore(
            promptPolicyProvider: promptPolicyProvider,
            readStrategyProvider: readStrategyProvider,
            accountRoster: roster,
            identityResolver: ClaudeIdentityResolver())
        self.credentials = credentials
        // The very same roster instance the capture path writes to — one actor, one index file.
        self.accountRoster = roster
        self.codexFetcher = CodexUsageFetcher()
        self.fetcher = fetcher
        self.claudeBinaryProvider = claudeBinaryProvider
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.pipeline = Self.makePipeline(
            credentials: credentials,
            fetcher: fetcher,
            claudeBinaryProvider: claudeBinaryProvider)
    }

    /// The read/remove port Settings uses to manage the roster (EXB-5.5 AC5).
    ///
    /// Built here because this is the app's single owner of the roster actor (EXB-5.2 AC4) — Settings
    /// gets two `Sendable` closures instead of the actor, so the store keeps exactly one reference in
    /// the app target and no view can reach its file/keychain I/O synchronously (R10).
    var rosterAccess: AccountRosterAccess {
        guard let roster = self.accountRoster else { return .empty }
        return AccountRosterAccess(
            load: { await roster.roster() },
            remove: { key in await roster.remove(key) })
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

    /// The `AppState.Fetch` closure — **the single composition point of the fan-out** (EXB-5.3
    /// AC6.17). Runs entirely off-MainActor and returns the whole assembled `WorkspaceSnapshot`, so
    /// `AppState` performs exactly one assignment per cycle no matter how many accounts exist.
    func makeFetch() -> AppState.Fetch {
        let pipeline = self.pipeline
        let credentials = self.credentials
        let claudeBinaryProvider = self.claudeBinaryProvider
        let costSettingsProvider = self.costSettingsProvider
        let costScanner = self.costScanner
        let accountRoster = self.accountRoster
        let codexFetcher = self.codexFetcher
        let log = self.log

        // EXB-1.7: scan local JSONL logs for an estimated cost, gated by `costEnabled` (AC11). Runs
        // on the `CostScanner` actor's executor, called from `AppState`'s detached fetch task — so
        // no file I/O ever touches the MainActor (AC10/AC13). Returns `nil` when disabled (AC11).
        @Sendable func scanCost() async -> ProviderCost? {
            let settings = costSettingsProvider()
            guard settings.enabled else { return nil }
            return await costScanner.scan(costDays: settings.days)
        }

        /// The Claude reading — the pipeline exactly as before, now one branch of the fan-out.
        @Sendable func fetchClaude(_ phase: RefreshPhase) async -> DisplaySnapshot {
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
                // Return the error-only sentinel — NEVER fabricate `0%` windows here. `AppState`
                // merges this error onto the last good snapshot, preserving Session/Weekly and just
                // appending the error line + marking the data stale (EXB rate-limit fix). Folding the
                // fresh local cost in keeps the cost estimate live even on a usage failure (AC10).
                return DisplaySnapshot.errorOnly(error).mergingCost(cost)
            }
        }

        /// The Codex pane, or `nil` when the provider is absent or not wired.
        ///
        /// Every failure mode is contained here: a Codex error becomes a Codex pane carrying that
        /// message and nothing else. It cannot reach the Claude pane, cannot throw out of this
        /// closure, and cannot make the cycle fail (EXB-5.4 AC4.11).
        @Sendable func fetchCodexPane(now: Date) async -> WorkspaceSnapshot.AccountPane? {
            guard let codexFetcher else { return nil }
            do {
                return WorkspaceSnapshot.codexPane(from: try await codexFetcher.fetch(), now: now)
            } catch {
                let message = (error as? UsageError)?.message ?? error.localizedDescription
                log.error("codex fetch failed: \(message, privacy: .public)")
                return WorkspaceSnapshot.codexUnavailablePane(message: message, now: now)
            }
        }

        return { phase in
            let now = Date()
            // AC3.5: the two providers are fetched CONCURRENTLY and independently — neither waits
            // for the other, and neither can fail the other.
            async let claude = fetchClaude(phase)
            async let codex = fetchCodexPane(now: now)
            // Zero fetch, zero keychain: archived panes come from the roster index alone (AC3.5).
            let roster = await accountRoster?.roster() ?? []
            let liveClaudeEntry = roster.first {
                $0.lifecycle == .live && $0.key.provider == .claude
            }

            return WorkspaceSnapshot.assemble(
                claude: WorkspaceSnapshot.claudePane(
                    display: await claude,
                    rosterLive: liveClaudeEntry),
                codex: await codex,
                archived: roster,
                now: now)
        }
    }
}
