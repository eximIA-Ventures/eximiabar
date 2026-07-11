import Foundation
import Testing
@testable import ClaudeBarCore

private func session(
    pid: Int32,
    cwd: String = "/Users/frm/repo",
    cpuNanos: UInt64) -> ClaudeSessionInfo
{
    ClaudeSessionInfo(pid: pid, workingDirectory: cwd, residentBytes: 1_000, cpuTotalNanos: cpuNanos)
}

struct SessionActivityTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test
    func firstSightingCountsAsActive() {
        var tracker = SessionActivityTracker()
        tracker.update(sessions: [session(pid: 1, cpuNanos: 0)], now: self.t0)
        #expect(tracker.idleDuration(pid: 1, now: self.t0) == 0)
        #expect(tracker.idleDuration(pid: 99, now: self.t0) == nil)
    }

    @Test
    func busySessionStaysActiveAndQuietSessionAccumulatesIdle() {
        var tracker = SessionActivityTracker()
        tracker.update(
            sessions: [session(pid: 1, cpuNanos: 0), session(pid: 2, cpuNanos: 0)],
            now: self.t0)

        // 30 s later: pid 1 burned 3 s of CPU (10% — active); pid 2 burned 30 ms (0.1% — idle).
        let t1 = self.t0.addingTimeInterval(30)
        tracker.update(
            sessions: [
                session(pid: 1, cpuNanos: 3_000_000_000),
                session(pid: 2, cpuNanos: 30_000_000),
            ],
            now: t1)

        #expect(tracker.idleDuration(pid: 1, now: t1) == 0)
        #expect(tracker.idleDuration(pid: 2, now: t1) == 30)

        // One hour of quiet samples later, pid 2 crosses the 1 h idle threshold.
        var now = t1
        var cpu: UInt64 = 30_000_000
        for _ in 0..<120 {
            now = now.addingTimeInterval(30)
            cpu += 1_000_000 // 1 ms per 30 s — far below the active fraction
            tracker.update(
                sessions: [session(pid: 1, cpuNanos: 4_000_000_000), session(pid: 2, cpuNanos: cpu)],
                now: now)
        }
        #expect((tracker.idleDuration(pid: 2, now: now) ?? 0) >= 3_600)
        // pid 1's burst still registers as active on the first loop sample (1 s CPU over 30 s),
        // so its idle clock starts one sample later: 3600 − 30 = 3570.
        #expect(tracker.idleDuration(pid: 1, now: now) == 3_570)
    }

    @Test
    func deadSessionsAreDropped() {
        var tracker = SessionActivityTracker()
        tracker.update(sessions: [session(pid: 7, cpuNanos: 0)], now: self.t0)
        tracker.update(sessions: [], now: self.t0.addingTimeInterval(30))
        #expect(tracker.idleDuration(pid: 7, now: self.t0.addingTimeInterval(60)) == nil)
    }
}

struct ClaudeSessionAnalyzerTests {
    @Test
    func flagsOnlyGitTreesWithTwoOrMoreSessions() {
        let sessions = [
            session(pid: 1, cwd: "/Users/frm/repo-a", cpuNanos: 0),
            session(pid: 2, cwd: "/Users/frm/repo-a", cpuNanos: 0),
            session(pid: 3, cwd: "/Users/frm/repo-b", cpuNanos: 0),
            session(pid: 4, cwd: "/Users/frm", cpuNanos: 0),
            session(pid: 5, cwd: "/Users/frm", cpuNanos: 0),
            session(pid: 6, cwd: "", cpuNanos: 0),
        ]
        // repo-a is a git tree (collision); ~ is not a repo (2 sessions there are fine).
        let collisions = ClaudeSessionAnalyzer.collisions(sessions: sessions) { path in
            path == "/Users/frm/repo-a"
        }
        #expect(collisions == ["/Users/frm/repo-a"])
    }

    @Test
    func emptyWhenNoDirectoryIsShared() {
        let sessions = [
            session(pid: 1, cwd: "/a", cpuNanos: 0),
            session(pid: 2, cwd: "/b", cpuNanos: 0),
        ]
        #expect(ClaudeSessionAnalyzer.collisions(sessions: sessions) { _ in true }.isEmpty)
    }
}
