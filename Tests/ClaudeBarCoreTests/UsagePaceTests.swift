import Foundation
import Testing
@testable import ClaudeBarCore

/// Tests for `UsagePace.compute` (EXB-1.3 T2 / AC13). All deterministic via injected `now`.
struct UsagePaceTests {
    private let weeklyMinutes = 10_080

    /// A window with no reset date yields no pace.
    @Test
    func noResetYieldsNoPace() {
        let window = RateWindow(utilization: 50, resetsAt: nil, windowMinutes: weeklyMinutes)
        #expect(UsagePace.compute(window: window, now: Date()) == nil)
    }

    /// Less than 3% of the window elapsed → no pace (AC13: hidden until ≥3% elapsed).
    @Test
    func belowThreePercentElapsedIsHidden() {
        let now = Date()
        // 1% elapsed: reset is 99% of the window away.
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.99)
        let window = RateWindow(utilization: 10, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        #expect(UsagePace.compute(window: window, now: now) == nil)
    }

    /// Exactly at the burn line within the slightly threshold → onPace.
    @Test
    func onLineIsOnPace() {
        let now = Date()
        // 50% elapsed → expected 50%; actual 50% → delta 0.
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.5)
        let window = RateWindow(utilization: 50, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace != nil)
        #expect(pace?.status == .onPace)
        #expect(pace?.lastsUntilReset == true)
    }

    /// Burning well ahead of the line → deficit and a projected run-out before reset.
    @Test
    func aheadOfLineIsDeficitAndRunsOut() {
        let now = Date()
        // 25% elapsed → expected 25%; actual 80% → delta +55 (deficit).
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.75)
        let window = RateWindow(utilization: 80, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace != nil)
        #expect(pace!.deltaPercent > 6)
        #expect(pace!.deficit > 0)
        #expect(pace!.reserve == 0)
        // At this burn rate the window empties before reset.
        #expect(pace!.projectedRunOut != nil)
        #expect(pace!.lastsUntilReset == false)
        if case .deficit = pace!.status {} else {
            Issue.record("expected deficit status, got \(String(describing: pace!.status))")
        }
    }

    /// Burning well behind the line → reserve, lasts to reset.
    @Test
    func behindLineIsReserve() {
        let now = Date()
        // 75% elapsed → expected 75%; actual 30% → delta -45 (reserve).
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.25)
        let window = RateWindow(utilization: 30, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace != nil)
        #expect(pace!.deltaPercent < -6)
        #expect(pace!.reserve > 0)
        #expect(pace!.deficit == 0)
        #expect(pace!.lastsUntilReset == true)
        #expect(pace!.status == .reserve(pace!.reserve))
    }

    /// Within the `onTrack` band (|delta| ≤ 2) classifies as onPace ("On pace", no number).
    @Test
    func withinTrackBandIsOnPace() {
        let now = Date()
        // 50% elapsed → expected 50%; actual 52% → delta +2 (≤2 → onPace).
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.5)
        let window = RateWindow(utilization: 52, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace?.status == .onPace)
    }

    /// "Slightly" band (2 < |delta| ≤ 6) is NOT onPace — it carries the signed delta so the pace text
    /// shows the number, matching `_reference_codexbar` (`.slightlyAhead`/`.slightlyBehind` still
    /// render "N% in deficit"/"N% in reserve"). Regression guard for the S3 reference-parity fix.
    @Test
    func slightlyAheadShowsDeficitNotOnPace() {
        let now = Date()
        // 50% elapsed → expected 50%; actual 55% → delta +5 (2 < |Δ| ≤ 6 → slightly deficit).
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.5)
        let window = RateWindow(utilization: 55, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace?.status == .deficit(5))
        #expect(pace?.deficit == 5)
        #expect(pace?.reserve == 0)
    }

    /// "Slightly" band on the under-pace side renders reserve with a number (reference parity).
    @Test
    func slightlyBehindShowsReserveNotOnPace() {
        let now = Date()
        // 50% elapsed → expected 50%; actual 46% → delta -4 (2 < |Δ| ≤ 6 → slightly reserve).
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.5)
        let window = RateWindow(utilization: 46, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace?.status == .reserve(4))
        #expect(pace?.reserve == 4)
        #expect(pace?.deficit == 0)
    }

    /// A reset further out than the window length yields no pace (no meaningful elapsed).
    @Test
    func resetBeyondWindowYieldsNoPace() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 2)
        let window = RateWindow(utilization: 40, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        #expect(UsagePace.compute(window: window, now: now) == nil)
    }

    /// percentRemaining is 100 − utilization.
    @Test
    func percentRemainingComplementsUtilization() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(TimeInterval(weeklyMinutes) * 60 * 0.5)
        let window = RateWindow(utilization: 60, resetsAt: resetsAt, windowMinutes: weeklyMinutes)
        let pace = UsagePace.compute(window: window, now: now)
        #expect(pace?.percentRemaining == 40)
    }
}
