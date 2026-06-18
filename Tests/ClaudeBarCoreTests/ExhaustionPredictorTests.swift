import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-4.3 — exhaustion predictor (AC1/AC2/AC3/AC6).
///
/// Every test injects a throwaway file URL so the predictor never reads or writes the real
/// `Application Support/ExímIABar/rate-samples.json`. The actor is exercised with `await`, so all
/// logic runs off the MainActor exactly as it does in production (AC2 §7).
struct ExhaustionPredictorTests {
    // MARK: - Helpers

    /// A predictor pointed at a unique temp file so each test is isolated and never touches the
    /// shared app-support history.
    private static func makePredictor() -> ExhaustionPredictor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-predict-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rate-samples.json")
        return ExhaustionPredictor(fileURL: url)
    }

    /// Feed `(timestamp, utilization)` pairs in order, where each timestamp is `base + offsetSeconds`.
    private static func feed(
        _ predictor: ExhaustionPredictor,
        windowId: String,
        base: Date,
        points: [(offset: Double, util: Double)]) async
    {
        for point in points {
            await predictor.addSample(
                windowId: windowId,
                timestamp: base.addingTimeInterval(point.offset),
                utilization: point.util)
        }
    }

    // MARK: - AC2 §6 — too few samples

    /// With fewer than `minSamples` (3) observations the predictor emits no forecast — no
    /// extrapolation from one or two noisy points (AC2 §6).
    @Test
    func noForecastWithLessThan3Samples() async {
        let predictor = Self.makePredictor()
        let base = Date()
        // Only two samples, even though the trend is clearly rising.
        await Self.feed(predictor, windowId: RateWindowID.session, base: base, points: [
            (0, 10), (60, 40),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 40,
            secondsUntilReset: .infinity)

        #expect(forecast.minutesRemaining == nil)
        #expect(forecast.confidenceLabel == ExhaustionPredictor.confidenceCalculating)
    }

    // MARK: - AC3 §9 — flat / declining rate (a reset)

    /// A declining utilization (a window reset, or usage backing off) yields a non-positive slope, so
    /// the predictor refuses to forecast exhaustion (AC3 §9) — "doesn't run out before reset".
    @Test
    func noForecastIfRateNegative() async {
        let predictor = Self.makePredictor()
        let base = Date()
        // Utilization falls 80 → 60 → 40 → 20: the regression slope is negative.
        await Self.feed(predictor, windowId: RateWindowID.weekly, base: base, points: [
            (0, 80), (60, 60), (120, 40), (180, 20),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.weekly,
            currentUtilization: 20,
            secondsUntilReset: .infinity)

        #expect(forecast.minutesRemaining == nil)
        #expect(forecast.confidenceLabel == ExhaustionPredictor.confidenceStable)
    }

    /// A perfectly flat history (slope == 0) is also treated as "no exhaustion" (AC3 §9): steady
    /// usage at a fixed level never reaches 100.
    @Test
    func noForecastIfRateFlat() async {
        let predictor = Self.makePredictor()
        let base = Date()
        await Self.feed(predictor, windowId: RateWindowID.session, base: base, points: [
            (0, 50), (60, 50), (120, 50), (180, 50),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 50,
            secondsUntilReset: .infinity)

        #expect(forecast.minutesRemaining == nil)
    }

    // MARK: - AC2 §5 / AC3 §8 — linear-slope forecast

    /// A clean linear ramp of +10 util every 60 s (slope = 1/6 util·s⁻¹). From 50 % the remaining
    /// 50 points take 50 / (1/6) = 300 s = 5 min to exhaust (AC2 §5 + AC3 §8).
    @Test
    func forecastCalculationLinearSlope() async throws {
        let predictor = Self.makePredictor()
        let base = Date()
        await Self.feed(predictor, windowId: RateWindowID.session, base: base, points: [
            (0, 10), (60, 20), (120, 30), (180, 40), (240, 50),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 50,
            // Reset comfortably after the predicted exhaustion so the §10 guard does not trip.
            secondsUntilReset: 3_600)

        let minutes = try #require(forecast.minutesRemaining)
        // 300 s / 60 = 5 min, allow a hair of floating-point slack.
        #expect(abs(minutes - 5.0) < 0.01)
        // Five samples (≥ minSamples + 2) → the "high" confidence tier.
        #expect(forecast.confidenceLabel == ExhaustionPredictor.confidenceHigh)
    }

    // MARK: - AC3 §10 — exhaustion after the window resets

    /// When the window will reset before the projected exhaustion, the forecast is irrelevant and is
    /// suppressed (AC3 §10). Same rising ramp as above (run-out ≈ 300 s), but the reset is only 60 s
    /// away.
    @Test
    func forecastNilIfExhaustionAfterReset() async {
        let predictor = Self.makePredictor()
        let base = Date()
        await Self.feed(predictor, windowId: RateWindowID.session, base: base, points: [
            (0, 10), (60, 20), (120, 30), (180, 40), (240, 50),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 50,
            // Resets in 60 s, well before the ~300 s exhaustion → no forecast.
            secondsUntilReset: 60)

        #expect(forecast.minutesRemaining == nil)
    }

    /// Mirror of the above: with the reset moved past the run-out the same data DOES forecast, proving
    /// the §10 guard is the only thing suppressing the sibling case (not the data itself).
    @Test
    func forecastEmittedWhenExhaustionBeforeReset() async {
        let predictor = Self.makePredictor()
        let base = Date()
        await Self.feed(predictor, windowId: RateWindowID.session, base: base, points: [
            (0, 10), (60, 20), (120, 30), (180, 40), (240, 50),
        ])

        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 50,
            secondsUntilReset: 600) // run-out ≈ 300 s < 600 s reset → forecast stands.

        #expect(forecast.minutesRemaining != nil)
    }

    // MARK: - AC1 §1 — circular buffer cap

    /// Adding more than `maxSamples` (20) observations keeps only the most recent 20 (AC1 §1).
    @Test
    func samplesCircularBufferMax20() async {
        let predictor = Self.makePredictor()
        let base = Date()
        // Push 30 samples — 10 over the cap.
        for index in 0..<30 {
            await predictor.addSample(
                windowId: RateWindowID.weekly,
                timestamp: base.addingTimeInterval(Double(index) * 60),
                utilization: Double(index))
        }

        let count = await predictor.sampleCount(windowId: RateWindowID.weekly)
        #expect(count == ExhaustionPredictor.maxSamples)
        #expect(count == 20)
    }

    // MARK: - AC1 §2 — persistence round-trip

    /// History written by one predictor instance is read back by a second instance pointed at the
    /// same file — samples survive a relaunch (AC1 §2).
    @Test
    func samplesPersistAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-predict-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rate-samples.json")

        let writer = ExhaustionPredictor(fileURL: url)
        let base = Date()
        await Self.feed(writer, windowId: RateWindowID.opus, base: base, points: [
            (0, 5), (60, 15), (120, 25),
        ])

        // A fresh instance loads the persisted history lazily on first access.
        let reader = ExhaustionPredictor(fileURL: url)
        let count = await reader.sampleCount(windowId: RateWindowID.opus)
        #expect(count == 3)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A missing or unreadable history file is treated as an empty history — never a crash (AC1 §2).
    @Test
    func missingFileStartsEmptyWithoutCrash() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-predict-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rate-samples.json")
        let predictor = ExhaustionPredictor(fileURL: url)

        let count = await predictor.sampleCount(windowId: RateWindowID.session)
        #expect(count == 0)

        // And a forecast on empty history is the honest "no estimate" case.
        let forecast = await predictor.forecast(
            windowId: RateWindowID.session,
            currentUtilization: 50,
            secondsUntilReset: .infinity)
        #expect(forecast.minutesRemaining == nil)
    }

    // MARK: - Regression slope unit (AC2 §5)

    /// The pure `ratePerSecond` helper returns the expected slope for a known ramp and `nil` for a
    /// single point (a vertical/undefined fit).
    @Test
    func ratePerSecondMatchesKnownSlope() {
        let base = Date()
        let samples = [
            RateSample(timestamp: base, utilization: 0),
            RateSample(timestamp: base.addingTimeInterval(60), utilization: 10),
            RateSample(timestamp: base.addingTimeInterval(120), utilization: 20),
        ]
        let rate = ExhaustionPredictor.ratePerSecond(samples: samples)
        let unwrapped = try? #require(rate)
        if let unwrapped {
            #expect(abs(unwrapped - (10.0 / 60.0)) < 1e-9)
        }

        #expect(ExhaustionPredictor.ratePerSecond(samples: [samples[0]]) == nil)
    }
}
