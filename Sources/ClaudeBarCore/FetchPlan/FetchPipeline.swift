import Foundation

/// Iterates the source plan, fetching from each plausibly-available source in order and
/// falling through on auth/scope errors (AC11, AC15). Includes a coalescing guard: while
/// a fetch is in flight, at most one additional fetch is queued to run after — fetches are
/// never stacked.
///
/// OAuth is always wired; `.cli` is wired when the caller supplies a `cliFetch` closure (EXB-1.6).
/// `.web` is explicitly out of scope (P2) — the pipeline guards against executing it.
public actor FetchPipeline {
    /// Fetches a snapshot for one OAuth source — supplied by the caller (the credentials
    /// store + usage fetcher). Returns a snapshot or throws a `UsageError`.
    public typealias OAuthFetch = @Sendable (_ mode: FetchMode) async throws -> UsageSnapshot
    /// Fetches a snapshot from the `claude` CLI (EXB-1.6). `nil` → CLI source is skipped.
    public typealias CLIFetch = @Sendable (_ mode: FetchMode) async throws -> UsageSnapshot

    private let oauthFetch: OAuthFetch
    private let cliFetch: CLIFetch?
    private let log = CoreLog.logger(CoreLog.Category.planner)

    private var inFlight: Task<Result<UsageSnapshot, UsageError>, Never>?
    private var pending = false

    public init(oauthFetch: @escaping OAuthFetch, cliFetch: CLIFetch? = nil) {
        self.oauthFetch = oauthFetch
        self.cliFetch = cliFetch
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
        let cliFetch = self.cliFetch
        let task = Task<Result<UsageSnapshot, UsageError>, Never> {
            await Self.execute(plan: plan, mode: mode, oauthFetch: oauthFetch, cliFetch: cliFetch)
        }
        self.inFlight = task
        let result = await task.value
        self.inFlight = nil
        return result
    }

    private static func execute(
        plan: [FetchStrategy],
        mode: FetchMode,
        oauthFetch: OAuthFetch,
        cliFetch: CLIFetch?) async -> Result<UsageSnapshot, UsageError>
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
                // CLI fallback (EXB-1.6). Only runs when the caller wired a `cliFetch` closure;
                // otherwise the source is skipped (e.g. OAuth-only builds / tests).
                guard let cliFetch else { continue }
                do {
                    let snapshot = try await cliFetch(mode)
                    return .success(snapshot)
                } catch let error as UsageError {
                    lastError = error
                    continue
                } catch {
                    lastError = .networkError(error.localizedDescription)
                    continue
                }
            case .web:
                // Web is out of scope (P2). Planner may return it; pipeline never runs it.
                continue
            }
        }
        return .failure(lastError)
    }
}
