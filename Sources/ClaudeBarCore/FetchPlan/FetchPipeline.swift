import Foundation

/// Iterates the source plan, fetching from each plausibly-available source in order and
/// falling through on auth/scope errors (AC11, AC15). Includes a coalescing guard: while
/// a fetch is in flight, at most one additional fetch is queued to run after — fetches are
/// never stacked.
///
/// In P0/P1 scope only the OAuth source is wired here; `.cli` lands in EXB-1.6 and `.web`
/// is explicitly out of scope. The pipeline guards against executing `.web`.
public actor FetchPipeline {
    /// Fetches a snapshot for one OAuth source — supplied by the caller (the credentials
    /// store + usage fetcher). Returns a snapshot or throws a `UsageError`.
    public typealias OAuthFetch = @Sendable (_ mode: FetchMode) async throws -> UsageSnapshot

    private let oauthFetch: OAuthFetch
    private let log = CoreLog.logger(CoreLog.Category.planner)

    private var inFlight: Task<Result<UsageSnapshot, UsageError>, Never>?
    private var pending = false

    public init(oauthFetch: @escaping OAuthFetch) {
        self.oauthFetch = oauthFetch
    }

    /// Runs the pipeline for the given plan. Coalesces concurrent calls: a second call
    /// while a fetch is in flight is marked pending and re-runs once, after the current
    /// fetch finishes.
    public func run(
        plan: [FetchStrategy],
        mode: FetchMode = .auto) async -> Result<UsageSnapshot, UsageError>
    {
        if let inFlight {
            // Coalesce: mark a single pending re-run, then await the in-flight result.
            self.pending = true
            _ = await inFlight.value
            // If we were the one to set pending, run a fresh pass now.
            if self.pending {
                self.pending = false
                return await self.run(plan: plan, mode: mode)
            }
            return await inFlight.value
        }

        let oauthFetch = self.oauthFetch
        let task = Task<Result<UsageSnapshot, UsageError>, Never> {
            await Self.execute(plan: plan, mode: mode, oauthFetch: oauthFetch)
        }
        self.inFlight = task
        let result = await task.value
        self.inFlight = nil
        return result
    }

    private static func execute(
        plan: [FetchStrategy],
        mode: FetchMode,
        oauthFetch: OAuthFetch) async -> Result<UsageSnapshot, UsageError>
    {
        var lastError: UsageError = .networkError("No source available")
        for strategy in plan where strategy.isPlausiblyAvailable {
            switch strategy.dataSource {
            case .oauth:
                do {
                    let snapshot = try await oauthFetch(mode)
                    return .success(snapshot)
                } catch let error as UsageError {
                    lastError = error
                    // Fall through to the next source only on auth/scope errors (auto mode).
                    if mode == .auto, SourcePlanner.shouldFallback(error: error) {
                        continue
                    }
                    return .failure(error)
                } catch {
                    lastError = .networkError(error.localizedDescription)
                    continue
                }
            case .cli:
                // CLI source wires in EXB-1.6; skip in P0/P1 OAuth-only scope.
                continue
            case .web:
                // Web is out of scope (P2). Planner may return it; pipeline never runs it.
                continue
            }
        }
        return .failure(lastError)
    }
}
