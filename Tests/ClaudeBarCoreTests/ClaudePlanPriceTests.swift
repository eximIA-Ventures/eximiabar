import Testing
@testable import ClaudeBarCore

/// EXB redesign #2 — the per-plan monthly price that frames the cost estimate as a value multiplier.
/// Known plans (Max / Pro) have a price; per-seat / custom plans return `nil` so no ROI is shown.
struct ClaudePlanPriceTests {
    @Test
    func knownPlansHaveAPrice() {
        #expect(ClaudePlan.max.approxMonthlyPriceUSD == 200)
        #expect(ClaudePlan.pro.approxMonthlyPriceUSD == 20)
    }

    @Test
    func variableOrCustomPlansHaveNoPrice() {
        #expect(ClaudePlan.team.approxMonthlyPriceUSD == nil)
        #expect(ClaudePlan.enterprise.approxMonthlyPriceUSD == nil)
        #expect(ClaudePlan.ultra.approxMonthlyPriceUSD == nil)
    }
}
