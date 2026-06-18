import Foundation
import os

/// Stable string identifiers for the rate windows the predictor tracks (AC1 §1). Plain strings keep
/// the persisted JSON forward-compatible and let `ExhaustionForecast.windowId` be matched in the UI.
public enum RateWindowID {
    public static let session = "session"
    public static let weekly = "weekly"
    public static let sonnet = "sonnet"
    public static let opus = "opus"
    public static let dailyRoutines = "dailyRoutines"
}

/// One persisted observation of a rate window's utilization at a moment in time (AC1).
///
/// Pure value type: `Codable` for JSON persistence, `Sendable` so it crosses the actor boundary.
public struct RateSample: Codable, Sendable, Equatable {
    /// When the sample was taken.
    public let timestamp: Date
    /// The window's utilization at that moment — the API value verbatim (0–100).
    public let utilization: Double

    public init(timestamp: Date, utilization: Double) {
        self.timestamp = timestamp
        self.utilization = utilization
    }
}

/// The forecast for a single rate window (AC3). `Sendable` so it rides inside `DisplaySnapshot`.
///
/// `minutesRemaining == nil` is the honest "no useful prediction" state — too few samples, a flat
/// or declining rate (a reset), or an exhaustion time that lands after the window already resets.
/// The UI renders nothing in that case (AC4 §13): better silence than false precision.
public struct ExhaustionForecast: Sendable, Equatable {
    /// Stable identifier of the window this forecast belongs to (e.g. `"session"`, `"weekly"`).
    public let windowId: String
    /// Estimated minutes until `utilization == 100`, or `nil` when no honest forecast exists.
    public let minutesRemaining: Double?
    /// A short human label describing confidence in the estimate.
    public let confidenceLabel: String

    public init(windowId: String, minutesRemaining: Double?, confidenceLabel: String) {
        self.windowId = windowId
        self.minutesRemaining = minutesRemaining
        self.confidenceLabel = confidenceLabel
    }
}

/// Estimates how long until each rate window is exhausted, from a short rolling history of samples.
///
/// **Design — honesty over precision (story directive):** with only a handful of noisy samples it is
/// easy to extrapolate nonsense. So the predictor refuses to forecast below `minSamples` (AC2 §6),
/// refuses to forecast a flat/declining rate (which signals a reset, AC3 §9), and refuses to forecast
/// an exhaustion that lands after the window already resets (AC3 §10). In all those cases
/// `minutesRemaining` is `nil` and the UI shows nothing.
///
/// **Anti-freeze (AC2 §7):** every method — including JSON disk I/O — runs on the actor's own
/// executor. `AppState` calls these with `await` from off the MainActor; nothing here ever touches
/// `@MainActor`. The `actor` itself is the thread-safety boundary for the sample buffers.
public actor ExhaustionPredictor {
    /// Process-wide shared predictor so the rolling history survives across refresh cycles.
    public static let shared = ExhaustionPredictor()

    /// Hard cap on samples retained per window — a circular buffer (AC1 §1).
    static let maxSamples = 20
    /// Minimum samples required before any forecast is emitted (AC2 §6).
    static let minSamples = 3
    /// Number of most-recent samples the linear regression runs over (AC2 §5).
    static let regressionWindow = 10

    /// Per-window rolling sample buffers, keyed by stable window id. Actor-isolated.
    private var samples: [String: [RateSample]] = [:]

    private let fileURL: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: CoreLog.subsystem, category: "prediction")
    /// `true` once `loadFromDisk()` has run, so the first `addSample` doesn't re-read.
    private var didLoad = false

    /// - Parameters:
    ///   - fileURL: where the JSON history lives. Defaults to
    ///     `Application Support/ExímIABar/rate-samples.json` (AC1 §2). Injected for tests so they
    ///     never touch the real app-support file.
    ///   - fileManager: injected for deterministic, isolated tests (mirrors `CostScanner`).
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    /// `Application Support/ExímIABar/rate-samples.json` (AC1 §2).
    static func defaultFileURL(fileManager: FileManager) -> URL {
        let support = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("ExímIABar", isDirectory: true)
            .appendingPathComponent("rate-samples.json")
    }

    // MARK: - Public API

    /// Append a sample for `windowId` to the circular buffer (max 20, AC1 §1) and persist the whole
    /// history to disk (AC1 §2). Loads from disk lazily on first call so a relaunch resumes history.
    public func addSample(windowId: String, timestamp: Date, utilization: Double) {
        self.loadIfNeeded()
        var buffer = self.samples[windowId, default: []]
        buffer.append(RateSample(timestamp: timestamp, utilization: utilization))
        if buffer.count > Self.maxSamples {
            buffer.removeFirst(buffer.count - Self.maxSamples)
        }
        self.samples[windowId] = buffer
        self.saveToDisk()
    }

    /// Compute the exhaustion forecast for `windowId` (AC2/AC3).
    ///
    /// - Parameters:
    ///   - windowId: which window's history to read.
    ///   - currentUtilization: the latest utilization (0–100) for that window.
    ///   - secondsUntilReset: seconds until the window resets; pass `.infinity` when unknown so the
    ///     reset-before-exhaust guard (AC3 §10) never trips on missing reset data.
    /// - Returns: a forecast. `minutesRemaining` is `nil` in every honest-no-forecast case.
    public func forecast(
        windowId: String,
        currentUtilization: Double,
        secondsUntilReset: Double) -> ExhaustionForecast
    {
        self.loadIfNeeded()
        let history = self.samples[windowId, default: []]

        // AC2 §6 — too few samples: no extrapolation. "Calculating" tells the UI to stay silent.
        guard history.count >= Self.minSamples else {
            return ExhaustionForecast(
                windowId: windowId,
                minutesRemaining: nil,
                confidenceLabel: Self.confidenceCalculating)
        }

        // AC2 §5 — regression over the last min(N, 10) samples.
        let recent = Array(history.suffix(Self.regressionWindow))
        guard let rate = Self.ratePerSecond(samples: recent) else {
            return ExhaustionForecast(
                windowId: windowId,
                minutesRemaining: nil,
                confidenceLabel: Self.confidenceCalculating)
        }

        // AC3 §9 — flat or declining usage (a reset, or steady state): never predict exhaustion.
        guard rate > 0 else {
            return ExhaustionForecast(
                windowId: windowId,
                minutesRemaining: nil,
                confidenceLabel: Self.confidenceStable)
        }

        // AC3 §8 — seconds until utilization reaches 100 at the current rate.
        let clampedUtil = min(100, max(0, currentUtilization))
        let secondsToExhaustion = (100.0 - clampedUtil) / rate

        // Already at/over 100 → exhaustion is now/past; surface as imminent rather than nil so the
        // alert path (≤30 min) can still fire on a window that just topped out.
        guard secondsToExhaustion.isFinite, secondsToExhaustion >= 0 else {
            return ExhaustionForecast(
                windowId: windowId,
                minutesRemaining: nil,
                confidenceLabel: Self.confidenceStable)
        }

        // AC3 §10 — the window resets before it would exhaust: not relevant, no forecast.
        guard secondsToExhaustion <= secondsUntilReset else {
            return ExhaustionForecast(
                windowId: windowId,
                minutesRemaining: nil,
                confidenceLabel: Self.confidenceLow)
        }

        let minutes = secondsToExhaustion / 60.0
        // More samples → more confidence. A simple, honest two-tier label.
        let confidence = recent.count >= Self.minSamples + 2
            ? Self.confidenceHigh
            : Self.confidenceLow
        return ExhaustionForecast(
            windowId: windowId,
            minutesRemaining: minutes,
            confidenceLabel: confidence)
    }

    // MARK: - Regression (AC2 §5)

    /// Slope of a simple linear regression of utilization over elapsed seconds, in utilization/sec.
    ///
    /// `x` is seconds since the first sample (a stable, well-conditioned origin), `y` is utilization.
    /// Returns `nil` when there are fewer than two distinct `x` values (a vertical fit is undefined),
    /// which the caller treats as "no forecast".
    static func ratePerSecond(samples: [RateSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let t0 = samples[0].timestamp
        let points: [(x: Double, y: Double)] = samples.map {
            (x: $0.timestamp.timeIntervalSince(t0), y: $0.utilization)
        }
        let n = Double(points.count)
        let sumX = points.map(\.x).reduce(0, +)
        let sumY = points.map(\.y).reduce(0, +)
        let sumXY = points.map { $0.x * $0.y }.reduce(0, +)
        let sumX2 = points.map { $0.x * $0.x }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-9 else { return nil }
        return (n * sumXY - sumX * sumY) / denom
    }

    // MARK: - Confidence labels

    static let confidenceHigh = "high"
    static let confidenceLow = "low"
    static let confidenceStable = "stable"
    static let confidenceCalculating = "calculating"

    // MARK: - Persistence (AC1 §2)

    /// Load the persisted history from disk into the in-memory buffers. A missing or corrupt file is
    /// treated as an empty history — never a crash (AC1 §2).
    public func loadFromDisk() {
        self.didLoad = true
        guard let data = try? Data(contentsOf: self.fileURL) else {
            self.samples = [:]
            return
        }
        do {
            let decoded = try JSONDecoder().decode([String: [RateSample]].self, from: data)
            // Defensively re-cap each buffer in case an older file held more than the current max.
            self.samples = decoded.mapValues { buffer in
                buffer.count > Self.maxSamples
                    ? Array(buffer.suffix(Self.maxSamples))
                    : buffer
            }
        } catch {
            self.log.debug("rate-samples.json invalid; starting empty")
            self.samples = [:]
        }
    }

    /// Persist the whole history as JSON, creating the parent directory if needed. Best-effort: a
    /// write failure is logged, never thrown to the caller (this runs on the actor, off-main).
    public func saveToDisk() {
        let dir = self.fileURL.deletingLastPathComponent()
        do {
            try self.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self.samples)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            self.log.error("failed to persist rate samples: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadIfNeeded() {
        guard !self.didLoad else { return }
        self.loadFromDisk()
    }

    /// The most-recent `limit` utilization values (0–100) for `windowId`, oldest-first (EXB-4.4 AC2).
    ///
    /// The menu-bar sparkline reads this off the MainActor (inside the actor) to draw recent session
    /// usage without keeping its own buffer — the predictor's rolling history is the single source of
    /// utilization truth. Returns `[]` when the window has no samples yet (the renderer then draws its
    /// neutral flat line, AC2 §6). `limit` is clamped to ≥ 0.
    public func recentUtilizations(windowId: String, limit: Int) -> [Double] {
        self.loadIfNeeded()
        guard limit > 0 else { return [] }
        let buffer = self.samples[windowId, default: []]
        return buffer.suffix(limit).map(\.utilization)
    }

    // MARK: - Test support

    /// Sample count for a window — used by tests to assert the circular-buffer cap.
    func sampleCount(windowId: String) -> Int {
        self.loadIfNeeded()
        return self.samples[windowId, default: []].count
    }
}
