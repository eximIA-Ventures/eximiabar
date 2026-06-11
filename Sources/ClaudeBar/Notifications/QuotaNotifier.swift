import AppKit
import ClaudeBarCore
import Foundation
@preconcurrency import UserNotifications

/// The two rate windows quota notifications fire for.
enum WindowKind: String, Sendable, Equatable, CaseIterable {
    case session
    case weekly

    /// Human label used in notification bodies ("Session" / "Weekly").
    var label: String {
        switch self {
        case .session: L("notification.window.session")
        case .weekly: L("notification.window.weekly")
        }
    }
}

/// A `(window, threshold)` pair already fired, for anti-spam tracking (AC9c).
struct ThresholdKey: Hashable, Sendable {
    let window: WindowKind
    let threshold: Int
}

/// Notification preferences (AC9/AC10). In S4 these come from a stub on `SettingsStore`;
/// the full settings surface lands in S5.
struct NotificationSettings: Sendable, Equatable {
    /// Quota-remaining thresholds (percent). Default `[50, 20]`.
    let thresholds: [Int]
    /// Whether the optional `NSSound("Glass")` plays on a notification.
    let soundEnabled: Bool
    /// Master switch — when `false`, no notifications are posted.
    let enabled: Bool

    init(thresholds: [Int] = [50, 20], soundEnabled: Bool = false, enabled: Bool = true) {
        self.thresholds = thresholds
        self.soundEnabled = soundEnabled
        self.enabled = enabled
    }
}

/// Pure threshold / transition logic — no AppKit, no UserNotifications — so it is fully
/// unit-testable (AC15c, AC15d). Ported from
/// `_reference_codexbar/Sources/CodexBar/SessionQuotaNotifications.swift`.
enum QuotaNotificationLogic {
    /// A window is "depleted" once `remaining` is at (or below) zero.
    static let depletedThreshold: Double = 0.0001

    static func isDepleted(_ remaining: Double?) -> Bool {
        guard let remaining else { return false }
        return remaining <= Self.depletedThreshold
    }

    /// Active thresholds: positive, ≤ 100, de-duplicated, sorted descending (50 before 20).
    static func activeThresholds(_ thresholds: [Int]) -> [Int] {
        Array(Set(thresholds.filter { $0 > 0 && $0 <= 100 })).sorted(by: >)
    }

    /// The single threshold crossed *downward* on this tick (AC9c). Fires once: returns the
    /// **most severe** (smallest %) not-yet-fired threshold at or above current remaining that the
    /// previous value was strictly above. `nil` if nothing newly crossed.
    ///
    /// When usage plunges past several thresholds in a single tick (e.g. `80 → 15` with `[50, 20]`),
    /// we fire the most urgent warning (20%) and `firedAfter` marks every higher threshold as fired
    /// — matching `_reference_codexbar/Sources/CodexBar/SessionQuotaNotifications.swift`
    /// `crossedThreshold` (returns `crossed.min()` / `eligible.min()`). Returning `.max()` here
    /// would fire only the 50% warning and leave the critical 20% warning permanently undelivered.
    static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        thresholds: [Int],
        alreadyFired: Set<Int>) -> Int?
    {
        let eligible = Self.activeThresholds(thresholds).filter { threshold in
            currentRemaining <= Double(threshold) && !alreadyFired.contains(threshold)
        }
        guard !eligible.isEmpty else { return nil }

        if let previousRemaining {
            // Only fire for thresholds the previous value had NOT already breached.
            let crossed = eligible.filter { previousRemaining > Double($0) }
            return crossed.min()
        }
        // No prior reading (cold start): fire the most-severe eligible threshold.
        return eligible.min()
    }

    /// After firing `threshold`, mark every higher-or-equal threshold as fired too, so we don't
    /// double-post when remaining drops past several thresholds between ticks.
    static func firedAfter(threshold: Int, thresholds: [Int], alreadyFired: Set<Int>) -> Set<Int> {
        alreadyFired.union(Self.activeThresholds(thresholds).filter { $0 >= threshold })
    }

    /// Thresholds to clear because usage has receded above them (allows re-firing next time
    /// it crosses down — e.g. after a window reset).
    static func thresholdsToClear(currentRemaining: Double, alreadyFired: Set<Int>) -> Set<Int> {
        Set(alreadyFired.filter { currentRemaining > Double($0) })
    }
}

/// Abstraction over the system notification center so tests can run headless (AC15) without
/// touching `UNUserNotificationCenter` (which crashes outside an app bundle).
@MainActor
protocol QuotaNotificationPosting: AnyObject {
    func post(idPrefix: String, title: String, body: String, soundEnabled: Bool)
}

/// Diffs successive `DisplaySnapshot`s and posts quota notifications (F10 / AC9–AC11).
///
/// Holds the only mutable notification state: the set of `(window, threshold)` pairs already
/// fired and the set of currently-depleted windows. `evaluate` is the single entry point —
/// `AppState` calls it once per published snapshot.
@MainActor
final class QuotaNotifier {
    private let poster: QuotaNotificationPosting

    /// `(window, threshold)` pairs already warned about (AC9c anti-spam).
    private(set) var firedThresholds: Set<ThresholdKey> = []
    /// Windows currently flagged depleted (AC9a/AC9b).
    private(set) var depletedWindows: Set<WindowKind> = []

    init(poster: QuotaNotificationPosting? = nil) {
        self.poster = poster ?? SystemNotificationPoster()
    }

    /// Diff `old` → `new` and post any depleted / restored / threshold notifications.
    ///
    /// - Parameters:
    ///   - old: the previously published snapshot (`nil` on the first evaluation).
    ///   - new: the snapshot just published.
    ///   - settings: notification preferences.
    func evaluate(old: DisplaySnapshot?, new: DisplaySnapshot, settings: NotificationSettings) {
        guard settings.enabled else { return }
        for window in WindowKind.allCases {
            let oldWindow = Self.window(window, in: old)
            let newWindow = Self.window(window, in: new)
            guard let newWindow else { continue }
            self.evaluateWindow(
                window,
                oldRemaining: oldWindow?.remaining,
                newRemaining: newWindow.remaining,
                settings: settings)
        }
    }

    // MARK: - Per-window evaluation

    private func evaluateWindow(
        _ window: WindowKind,
        oldRemaining: Double?,
        newRemaining: Double,
        settings: NotificationSettings)
    {
        // 1. Depleted / restored (AC9a / AC9b).
        let wasDepleted = self.depletedWindows.contains(window)
        let isDepleted = QuotaNotificationLogic.isDepleted(newRemaining)

        if isDepleted, !wasDepleted {
            self.depletedWindows.insert(window)
            self.postDepleted(window, settings: settings)
        } else if !isDepleted, wasDepleted {
            self.depletedWindows.remove(window)
            self.postRestored(window, settings: settings)
        }

        // 2. Threshold warnings (AC9c). Clear any thresholds usage has receded above first.
        let firedForWindow = Set(
            self.firedThresholds.filter { $0.window == window }.map(\.threshold))
        let toClear = QuotaNotificationLogic.thresholdsToClear(
            currentRemaining: newRemaining,
            alreadyFired: firedForWindow)
        for threshold in toClear {
            self.firedThresholds.remove(ThresholdKey(window: window, threshold: threshold))
        }

        let stillFired = firedForWindow.subtracting(toClear)
        if let crossed = QuotaNotificationLogic.crossedThreshold(
            previousRemaining: oldRemaining,
            currentRemaining: newRemaining,
            thresholds: settings.thresholds,
            alreadyFired: stillFired)
        {
            let newlyFired = QuotaNotificationLogic.firedAfter(
                threshold: crossed,
                thresholds: settings.thresholds,
                alreadyFired: stillFired)
            for threshold in newlyFired {
                self.firedThresholds.insert(ThresholdKey(window: window, threshold: threshold))
            }
            self.postThreshold(window, remaining: newRemaining, threshold: crossed, settings: settings)
        }
    }

    // MARK: - Posting

    private func postDepleted(_ window: WindowKind, settings: NotificationSettings) {
        self.playSoundIfEnabled(settings)
        self.poster.post(
            idPrefix: "depleted-\(window.rawValue)",
            title: L("popover.provider_name"),
            body: L("notification.quota_exhausted", window.label),
            soundEnabled: false)
    }

    private func postRestored(_ window: WindowKind, settings: NotificationSettings) {
        self.playSoundIfEnabled(settings)
        self.poster.post(
            idPrefix: "restored-\(window.rawValue)",
            title: L("popover.provider_name"),
            body: L("notification.quota_restored", window.label),
            soundEnabled: false)
    }

    private func postThreshold(
        _ window: WindowKind,
        remaining: Double,
        threshold: Int,
        settings: NotificationSettings)
    {
        let percent = Int(min(100, max(0, remaining)).rounded())
        self.playSoundIfEnabled(settings)
        self.poster.post(
            idPrefix: "threshold-\(window.rawValue)-\(threshold)",
            title: L("popover.provider_name"),
            body: L("notification.quota_remaining", window.label, percent),
            soundEnabled: false)
    }

    /// AC10: play `NSSound("Glass")` when the sound toggle is on. We trigger the sound here rather
    /// than via the notification's own sound so it fires even when the system suppresses banners.
    private func playSoundIfEnabled(_ settings: NotificationSettings) {
        guard settings.soundEnabled else { return }
        (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
    }

    #if DEBUG
    /// Reset internal state — test helper only.
    func resetForTesting() {
        self.firedThresholds.removeAll()
        self.depletedWindows.removeAll()
    }
    #endif

    private static func window(_ kind: WindowKind, in snapshot: DisplaySnapshot?) -> RateWindow? {
        switch kind {
        case .session: snapshot?.session
        case .weekly: snapshot?.weekly
        }
    }
}

/// Real poster backed by `UNUserNotificationCenter`. Ported from
/// `_reference_codexbar/Sources/CodexBar/AppNotifications.swift`.
@MainActor
final class SystemNotificationPoster: QuotaNotificationPosting {
    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    private let log = CoreLog.logger("notifications")
    private var authorizationTask: Task<Bool, Never>?

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = {
        UNUserNotificationCenter.current()
    }) {
        self.centerProvider = centerProvider
    }

    /// Request `[.alert, .sound]` authorization once at launch (AC11). Fire-and-forget.
    func requestAuthorizationOnStartup() {
        guard !Self.isRunningHeadless else { return }
        _ = self.ensureAuthorizationTask()
    }

    func post(idPrefix: String, title: String, body: String, soundEnabled: Bool) {
        guard !Self.isRunningHeadless else { return }
        let center = self.centerProvider()
        let log = self.log

        Task { @MainActor in
            let granted = await self.ensureAuthorized()
            // AC11: silently skip when permission denied.
            guard granted else {
                log.debug("notifications not authorized; skipping \(idPrefix, privacy: .public)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = soundEnabled ? .default : nil

            let request = UNNotificationRequest(
                identifier: "eximiabar-\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil)
            do {
                try await center.add(request)
            } catch {
                log.error("failed to post \(idPrefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Authorization

    private func ensureAuthorizationTask() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task { @MainActor in await self.requestAuthorization() }
        self.authorizationTask = task
        return task
    }

    private func ensureAuthorized() async -> Bool {
        await self.ensureAuthorizationTask().value
    }

    private func requestAuthorization() async -> Bool {
        if let existing = await self.authorizationStatus() {
            if existing == .authorized || existing == .provisional { return true }
            if existing == .denied { return false }
        }
        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func authorizationStatus() async -> UNAuthorizationStatus? {
        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Outside a real `.app` bundle (tests / CLI), `UNUserNotificationCenter` can crash; treat as
    /// headless and no-op. Mirrors the reference's guard.
    private static var isRunningHeadless: Bool {
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
