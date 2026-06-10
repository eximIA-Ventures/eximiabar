import Foundation
import Testing
@testable import ClaudeBarCore

/// AC17f: SourcePlanner order and `shouldFallback` logic.
struct SourcePlannerTests {
    // MARK: Order

    @Test
    func autoModeOrdersOAuthThenCLIThenWeb() {
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: nil,
            hasOAuthCredentials: true,
            hasCLI: true,
            hasWebSession: true))
        #expect(plan.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.map(\.isPlausiblyAvailable) == [true, true, true])
    }

    @Test
    func autoModeMarksUnavailableSources() {
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: nil,
            hasOAuthCredentials: true,
            hasCLI: false,
            hasWebSession: false))
        #expect(plan.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan[0].isPlausiblyAvailable == true)  // oauth
        #expect(plan[1].isPlausiblyAvailable == false) // cli
        #expect(plan[2].isPlausiblyAvailable == false) // web
    }

    @Test
    func explicitOAuthSelectionReturnsSingleStep() {
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: .oauth,
            hasOAuthCredentials: true,
            hasCLI: true,
            hasWebSession: true))
        #expect(plan.count == 1)
        #expect(plan.first?.dataSource == .oauth)
        #expect(plan.first?.isPlausiblyAvailable == true)
    }

    @Test
    func explicitCLISelectionReflectsAvailability() {
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: .cli,
            hasOAuthCredentials: true,
            hasCLI: false,
            hasWebSession: true))
        #expect(plan.count == 1)
        #expect(plan.first?.dataSource == .cli)
        #expect(plan.first?.isPlausiblyAvailable == false)
    }

    // MARK: shouldFallback

    @Test
    func shouldFallbackTrueForAuthAndScopeErrors() {
        #expect(SourcePlanner.shouldFallback(error: .authRequired("x")) == true)
        #expect(SourcePlanner.shouldFallback(error: .scopeMissing("x")) == true)
    }

    @Test
    func shouldFallbackFalseForRateLimitNetworkParseBlocked() {
        #expect(SourcePlanner.shouldFallback(
            error: .rateLimited(retryAfter: Date())) == false)
        #expect(SourcePlanner.shouldFallback(error: .networkError("x")) == false)
        #expect(SourcePlanner.shouldFallback(error: .parseError("x")) == false)
        #expect(SourcePlanner.shouldFallback(error: .blocked("x")) == false)
    }

    // MARK: Pipeline integration

    @Test
    func pipelineReturnsOAuthSnapshotOnSuccess() async {
        let snapshot = UsageSnapshot.placeholder
        let pipeline = FetchPipeline(oauthFetch: { _ in snapshot })
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: nil,
            hasOAuthCredentials: true,
            hasCLI: false,
            hasWebSession: false))
        let result = await pipeline.run(plan: plan, mode: .auto)
        switch result {
        case let .success(value):
            #expect(value.source == .oauth)
        case let .failure(error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test
    func pipelineFailsWhenOAuthAuthErrorAndNoOtherSource() async {
        let pipeline = FetchPipeline(oauthFetch: { _ in
            throw UsageError.authRequired("re-auth")
        })
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: nil,
            hasOAuthCredentials: true,
            hasCLI: false, // no CLI to fall to in P0/P1
            hasWebSession: false))
        let result = await pipeline.run(plan: plan, mode: .auto)
        switch result {
        case .success:
            Issue.record("expected failure")
        case let .failure(error):
            guard case .authRequired = error else {
                Issue.record("expected .authRequired, got \(error)")
                return
            }
        }
    }

    @Test
    func pipelineNeverRunsWebSource() async {
        // Even if web is marked available, the pipeline must not execute it (P2 out of scope).
        let pipeline = FetchPipeline(oauthFetch: { _ in
            throw UsageError.authRequired("re-auth")
        })
        let plan = SourcePlanner.plan(input: SourcePlanningInput(
            selectedSource: nil,
            hasOAuthCredentials: true,
            hasCLI: false,
            hasWebSession: true)) // web available, must be ignored
        let result = await pipeline.run(plan: plan, mode: .auto)
        switch result {
        case .success:
            Issue.record("expected failure — web must not be executed")
        case .failure:
            break // correct: fell through OAuth, skipped cli + web
        }
    }
}
