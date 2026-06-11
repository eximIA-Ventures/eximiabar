import Foundation

/// Pace analysis for a rate-limit window: how actual consumption compares to the linear-burn
/// expectation at this point in the window, plus a projection of when the window would run out.
///
/// Ported and adapted from `_reference_codexbar/Sources/CodexBarCore/UsagePace.swift`. The reference
/// keyed off `RateWindow.usedPercent` / `remainingPercent` / `windowMinutes: Int?`; exímIABar's
/// `RateWindow` exposes `utilization` (0–100, used verbatim from the API) and a non-optional
/// `windowMinutes`, so the computation is re-expressed against that shape.
///
/// Pure computation — no UI, no AppKit. Safe to call off the main actor.
public struct UsagePace: Sendable, Equatable {
    /// Where consumption stands relative to the linear-burn line. This is the **delta**
    /// classification only (it drives the primary pace label and the stripe colour); the run-out
    /// projection is carried separately in `projectedRunOut` / `lastsUntilReset`, mirroring the
    /// reference where `stage` and `eta` are independent.
    public enum PaceStatus: Sendable, Equatable {
        /// On the expected burn line within the `onTrack` band (|delta| ≤ 2). Beyond ±2 the status
        /// carries the signed delta so the pace text shows the number (reference parity — see `status`).
        case onPace
        /// Ahead of the expected burn by `delta` percentage points (burning too fast).
        case deficit(Double)
        /// Behind the expected burn by `delta` percentage points (burning slowly — reserve).
        case reserve(Double)
    }

    /// Percentage of the window still remaining, 0–100.
    public let percentRemaining: Double
    /// Percentage points consumed beyond the linear-burn expectation (positive == over-pace).
    public let deficit: Double
    /// Percentage points under the linear-burn expectation (positive == under-pace / reserve).
    public let reserve: Double
    /// Linear-burn expected used percent at `now` given the elapsed fraction of the window.
    public let expectedUsedPercent: Double
    /// Actual used percent at `now` (`RateWindow.utilization`, clamped 0–100).
    public let actualUsedPercent: Double
    /// The reset date the projection is measured against.
    public let resetsAt: Date
    /// Projected exhaustion date if the current burn rate would empty the window before reset.
    public let projectedRunOut: Date?
    /// `true` when the current burn rate would last until the reset.
    public let lastsUntilReset: Bool
    /// The classified status used to drive the pace text and stripe direction.
    public let status: PaceStatus

    public init(
        percentRemaining: Double,
        deficit: Double,
        reserve: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        resetsAt: Date,
        projectedRunOut: Date?,
        lastsUntilReset: Bool,
        status: PaceStatus)
    {
        self.percentRemaining = percentRemaining
        self.deficit = deficit
        self.reserve = reserve
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.resetsAt = resetsAt
        self.projectedRunOut = projectedRunOut
        self.lastsUntilReset = lastsUntilReset
        self.status = status
    }

    /// The signed delta between actual and expected used percent (positive == over-pace).
    public var deltaPercent: Double { self.actualUsedPercent - self.expectedUsedPercent }

    /// Compute pace for a window at `now`.
    ///
    /// Returns `nil` when pace cannot or should not be shown:
    /// - the window has no `resetsAt`,
    /// - the reset is in the past or further out than the window length (no meaningful elapsed),
    /// - **less than 3% of the window duration has elapsed** (AC13 — too early to project).
    ///
    /// - Parameters:
    ///   - window: the rate window to analyse (`utilization` 0–100, `windowMinutes` length).
    ///   - now: the reference instant (injected for deterministic tests).
    public static func compute(window: RateWindow, now: Date = .init()) -> UsagePace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }

        let elapsed = min(max(duration - timeUntilReset, 0), duration)
        let expected = min(max((elapsed / duration) * 100, 0), 100)
        let actual = min(max(window.utilization, 0), 100)

        // AC13: hide the pace line until at least 3% of the window has elapsed.
        guard expected >= 3 else { return nil }

        let delta = actual - expected

        // Project the run-out from the observed burn rate.
        var projectedRunOut: Date?
        var lastsUntilReset = false
        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed // used-percent per second
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let secondsToEmpty = remaining / rate
                if secondsToEmpty >= timeUntilReset {
                    lastsUntilReset = true
                } else {
                    projectedRunOut = now.addingTimeInterval(secondsToEmpty)
                }
            } else {
                lastsUntilReset = true
            }
        } else {
            // No consumption yet — by definition it lasts to reset.
            lastsUntilReset = true
        }

        let status = Self.status(delta: delta)

        return UsagePace(
            percentRemaining: 100 - actual,
            deficit: max(0, delta),
            reserve: max(0, -delta),
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            resetsAt: resetsAt,
            projectedRunOut: projectedRunOut,
            lastsUntilReset: lastsUntilReset,
            status: status)
    }

    /// Classify the pace status by delta only.
    ///
    /// Reference parity (`_reference_codexbar/.../UsagePace.swift:110-116` +
    /// `UsagePaceText.swift:36-42`): only the `onTrack` band (|delta| ≤ 2) suppresses the number and
    /// renders "On pace". The reference's "slightly" band (2 < |delta| ≤ 6) is a bar-stripe
    /// distinction, **not** a string one — it still shows "N% in deficit"/"N% in reserve". So `onPace`
    /// is the ≤2 band; everything beyond it carries the signed delta. The stripe direction is driven
    /// independently by the `reserve`/`deficit` fields, so the slightly band keeps its green/red stripe.
    private static func status(delta: Double) -> PaceStatus {
        if abs(delta) <= 2 { return .onPace }
        return delta >= 0 ? .deficit(delta) : .reserve(-delta)
    }
}
