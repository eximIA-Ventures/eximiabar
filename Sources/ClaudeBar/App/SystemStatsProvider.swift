import AppKit
import ClaudeBarCore
import Foundation
import Observation

/// App-level owner of the system stats: samples continuously (30 s cadence, always off the main
/// thread) so idle detection and the system alerts work even while the popover is closed. The
/// popover's `SystemSection` reads this provider and asks for extra samples while visible.
@MainActor
@Observable
final class SystemStatsProvider {
    /// Background cadence. Idle detection needs a continuous CPU-delta history; the popover adds
    /// faster samples on top while it is open.
    private static let backgroundInterval: Duration = .seconds(30)
    /// A session with no meaningful CPU for this long is offered for termination.
    static let idleThreshold: TimeInterval = 60 * 60

    private(set) var stats: SystemStats?
    /// Idle duration per live session pid, refreshed on every sample.
    private(set) var idleByPid: [Int32: TimeInterval] = [:]
    /// Git working trees currently shared by 2+ sessions (single-session-per-repo collisions).
    private(set) var collisionPaths: [String] = []

    @ObservationIgnored private var tracker = SessionActivityTracker()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private let alertNotifier: SystemAlertNotifier?

    init(alertNotifier: SystemAlertNotifier? = nil) {
        self.alertNotifier = alertNotifier
    }

    deinit {
        loopTask?.cancel()
    }

    /// Start the continuous background sampling loop. Idempotent.
    func start() {
        guard self.loopTask == nil else { return }
        self.loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleNow()
                do {
                    try await Task.sleep(for: Self.backgroundInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Take one sample now (syscalls + `.git` existence checks run off the main actor).
    func sampleNow() async {
        let sampled = await Task.detached(priority: .utility) { () -> (SystemStats, [String])? in
            guard let stats = SystemStatsSampler.sample() else { return nil }
            let collisions = ClaudeSessionAnalyzer.collisions(sessions: stats.sessions) { directory in
                FileManager.default.fileExists(atPath: directory + "/.git")
            }
            return (stats, collisions)
        }.value
        guard let (stats, collisions) = sampled else { return }

        self.tracker.update(sessions: stats.sessions, now: stats.sampledAt)
        var idle: [Int32: TimeInterval] = [:]
        for session in stats.sessions {
            idle[session.pid] = self.tracker.idleDuration(pid: session.pid, now: stats.sampledAt)
        }
        self.stats = stats
        self.idleByPid = idle
        self.collisionPaths = collisions
        self.alertNotifier?.evaluate(stats: stats, collisions: collisions)
    }

    /// Politely terminate a session (SIGTERM — the CLI shuts down cleanly and persists state).
    /// - Returns: `false` when the signal could not be delivered (process already gone, etc.).
    @discardableResult
    func terminateSession(pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }
}

/// Posts the three system alerts through the same notification poster the quota alerts use.
/// All alerts carry cooldowns so a persistent condition nudges once an hour, not once a sample.
@MainActor
final class SystemAlertNotifier {
    static let freeMemoryThresholdPercent = 20.0
    static let claudeBytesThreshold: UInt64 = 6 << 30 // 6 GB
    static let cooldown: TimeInterval = 60 * 60

    private let poster: QuotaNotificationPosting

    /// Low-memory fires only after 2 consecutive low samples (debounce against transient spikes).
    private var lowMemoryStreak = 0
    private var lastLowMemoryAlert: Date?
    private var lastClaudeFootprintAlert: Date?
    private var lastCollisionAlert: [String: Date] = [:]

    init(poster: QuotaNotificationPosting) {
        self.poster = poster
    }

    func evaluate(stats: SystemStats, collisions: [String], now: Date = Date()) {
        self.evaluateLowMemory(stats: stats, now: now)
        self.evaluateClaudeFootprint(stats: stats, now: now)
        self.evaluateCollisions(collisions, now: now)
    }

    private func evaluateLowMemory(stats: SystemStats, now: Date) {
        guard stats.memoryFreePercent < Self.freeMemoryThresholdPercent else {
            self.lowMemoryStreak = 0
            return
        }
        self.lowMemoryStreak += 1
        guard self.lowMemoryStreak >= 2, self.cooledDown(self.lastLowMemoryAlert, now: now) else {
            return
        }
        self.lastLowMemoryAlert = now
        self.poster.post(
            idPrefix: "system.lowmem",
            title: L("notification.system.low_memory_title"),
            body: L(
                "notification.system.low_memory_body",
                Int(stats.memoryFreePercent.rounded()),
                PopoverFormatter.bytes(stats.claudeResidentBytes),
                stats.claudeSessionCount),
            soundEnabled: false)
    }

    private func evaluateClaudeFootprint(stats: SystemStats, now: Date) {
        guard stats.claudeResidentBytes > Self.claudeBytesThreshold,
              self.cooledDown(self.lastClaudeFootprintAlert, now: now) else { return }
        self.lastClaudeFootprintAlert = now
        self.poster.post(
            idPrefix: "system.claudemem",
            title: L("notification.system.claude_footprint_title"),
            body: L(
                "notification.system.claude_footprint_body",
                PopoverFormatter.bytes(stats.claudeResidentBytes),
                stats.claudeSessionCount),
            soundEnabled: false)
    }

    private func evaluateCollisions(_ collisions: [String], now: Date) {
        for path in collisions where self.cooledDown(self.lastCollisionAlert[path], now: now) {
            self.lastCollisionAlert[path] = now
            self.poster.post(
                idPrefix: "system.collision",
                title: L("notification.system.collision_title"),
                body: L("notification.system.collision_body", PopoverFormatter.abbreviatePath(path)),
                soundEnabled: false)
        }
    }

    private func cooledDown(_ last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }
}
