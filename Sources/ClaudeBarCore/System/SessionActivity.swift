import Foundation

/// Tracks per-session CPU deltas across samples to classify Claude CLI sessions as idle.
///
/// A session is "active" at a sample when its CPU time grew by more than `activeCPUFraction`
/// of the wall-clock interval since the previous sample (an idle CLI still ticks its event
/// loop, so the threshold is a fraction, not zero). Idle duration is measured from the last
/// active sample. Pure value type — no clock, no syscalls — so it is deterministic in tests.
public struct SessionActivityTracker: Sendable, Equatable {
    /// CPU-over-wall-clock fraction above which a session counts as active (0.5% CPU).
    public static let activeCPUFraction = 0.005

    private struct Record: Sendable, Equatable {
        var cpuTotalNanos: UInt64
        var sampledAt: Date
        var lastActiveAt: Date
    }

    private var records: [Int32: Record] = [:]

    public init() {}

    /// Fold a new sample in: update per-pid activity and drop records of dead sessions.
    public mutating func update(sessions: [ClaudeSessionInfo], now: Date) {
        var next: [Int32: Record] = [:]
        for session in sessions {
            if let previous = self.records[session.pid] {
                let wallNanos = now.timeIntervalSince(previous.sampledAt) * 1_000_000_000
                let cpuDelta = Double(session.cpuTotalNanos &- previous.cpuTotalNanos)
                // Guard against clock skew / first-sample glitches: a non-positive wall interval
                // keeps the previous activity verdict.
                let isActive = wallNanos > 0
                    && session.cpuTotalNanos >= previous.cpuTotalNanos
                    && cpuDelta / wallNanos > Self.activeCPUFraction
                next[session.pid] = Record(
                    cpuTotalNanos: session.cpuTotalNanos,
                    sampledAt: now,
                    lastActiveAt: isActive ? now : previous.lastActiveAt)
            } else {
                // First sighting: assume active now (no delta to judge yet).
                next[session.pid] = Record(
                    cpuTotalNanos: session.cpuTotalNanos,
                    sampledAt: now,
                    lastActiveAt: now)
            }
        }
        self.records = next
    }

    /// How long the session has been idle, or `nil` when the pid is unknown.
    public func idleDuration(pid: Int32, now: Date) -> TimeInterval? {
        guard let record = self.records[pid] else { return nil }
        return max(0, now.timeIntervalSince(record.lastActiveAt))
    }
}

/// Pure analysis over a set of live sessions.
public enum ClaudeSessionAnalyzer {
    /// Working directories shared by 2+ sessions **that are git working trees** — the collision
    /// the single-session-per-repo discipline exists to prevent. Non-repo folders (e.g. several
    /// sessions parked in `~`) are legitimate and excluded; `isGitWorkingTree` is injected so the
    /// filesystem check stays out of this pure function.
    public static func collisions(
        sessions: [ClaudeSessionInfo],
        isGitWorkingTree: (String) -> Bool) -> [String]
    {
        var countByDirectory: [String: Int] = [:]
        for session in sessions where !session.workingDirectory.isEmpty {
            countByDirectory[session.workingDirectory, default: 0] += 1
        }
        return countByDirectory
            .filter { $0.value >= 2 }
            .map(\.key)
            .filter(isGitWorkingTree)
            .sorted()
    }
}
