import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for the EXB-1.4 refresh loop, coalescing, phase propagation and quota notifications.
@MainActor
struct AppStateTests {
    // MARK: - Helpers

    /// Records every posted notification so threshold/transition logic can be asserted.
    private final class RecordingPoster: QuotaNotificationPosting {
        struct Post: Equatable {
            let idPrefix: String
            let body: String
        }

        private(set) var posts: [Post] = []

        func post(idPrefix: String, title: String, body: String, soundEnabled: Bool) {
            posts.append(Post(idPrefix: idPrefix, body: body))
        }
    }

    private func snapshot(sessionRemaining: Double, weeklyRemaining: Double = 100) -> DisplaySnapshot {
        DisplaySnapshot(
            session: RateWindow(utilization: 100 - sessionRemaining, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(utilization: 100 - weeklyRemaining, resetsAt: nil, windowMinutes: 10080),
            updatedAt: Date())
    }

    // MARK: - AC15a: Coalescing

    /// Firing 3 simultaneous refresh triggers results in at most 2 fetch calls
    /// (1 in-flight + 1 pending). Excess triggers are dropped.
    @Test
    func coalescingCapsConcurrentTriggersAtTwo() async {
        let counter = FetchCounter()
        let settings = SettingsStore(refreshCadence: .manual)
        let state = AppState(
            fetch: { _ in
                await counter.increment()
                // Hold the first fetch open long enough for the burst of triggers to arrive.
                try? await Task.sleep(for: .milliseconds(50))
                return DisplaySnapshot(session: nil, weekly: nil, updatedAt: Date())
            },
            settingsStore: settings)

        // Burst of three triggers while the first fetch is still in flight.
        state.triggerRefresh(.background)
        state.triggerRefresh(.background)
        state.triggerRefresh(.background)

        // Let both the in-flight and the single pending fetch drain.
        try? await Task.sleep(for: .milliseconds(300))

        let count = await counter.value
        #expect(count <= 2)
        #expect(count >= 1)
    }

    // MARK: - AC15b: Phase propagation

    /// A user-initiated refresh bypasses the 429 gate: the phase reaching the fetch closure is
    /// `.userInitiated`, whose `fetchMode` is `.userInitiated` (gate-bypassing).
    @Test
    func userInitiatedPhaseReachesFetch() async {
        let recorder = PhaseRecorder()
        let settings = SettingsStore(refreshCadence: .manual)
        let state = AppState(
            fetch: { phase in
                await recorder.record(phase)
                return DisplaySnapshot(session: nil, weekly: nil, updatedAt: Date())
            },
            settingsStore: settings)

        state.triggerRefresh(.userInitiated)
        try? await Task.sleep(for: .milliseconds(100))

        let phases = await recorder.phases
        #expect(phases.contains(.userInitiated))
        #expect(RefreshPhase.userInitiated.fetchMode == .userInitiated)
        #expect(RefreshPhase.background.fetchMode == .auto)
        #expect(RefreshPhase.startup.fetchMode == .auto)
    }

    // MARK: - AC15c: Threshold fires once

    /// A threshold notification fires once when remaining crosses below it, not on every tick.
    @Test
    func thresholdFiresOnceOnCrossing() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50, 20], soundEnabled: false)

        // Start above 50 (baseline).
        notifier.evaluate(old: nil, new: snapshot(sessionRemaining: 80), settings: settings)
        // Cross below 50 → one warning.
        notifier.evaluate(
            old: snapshot(sessionRemaining: 80),
            new: snapshot(sessionRemaining: 45),
            settings: settings)
        // Stay below 50 (still above 20) → NO additional warning.
        notifier.evaluate(
            old: snapshot(sessionRemaining: 45),
            new: snapshot(sessionRemaining: 40),
            settings: settings)
        notifier.evaluate(
            old: snapshot(sessionRemaining: 40),
            new: snapshot(sessionRemaining: 35),
            settings: settings)

        let warnings = poster.posts.filter { $0.idPrefix.hasPrefix("threshold-session-50") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.body.contains("Session") == true)
    }

    /// Crossing two thresholds in one tick still fires only the relevant warnings, and dropping
    /// below 20 later fires the 20 warning exactly once.
    @Test
    func separateThresholdsFireIndependently() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50, 20], soundEnabled: false)

        notifier.evaluate(old: nil, new: snapshot(sessionRemaining: 80), settings: settings)
        notifier.evaluate(
            old: snapshot(sessionRemaining: 80),
            new: snapshot(sessionRemaining: 45),
            settings: settings)
        // Now drop below 20.
        notifier.evaluate(
            old: snapshot(sessionRemaining: 45),
            new: snapshot(sessionRemaining: 15),
            settings: settings)

        let fifty = poster.posts.filter { $0.idPrefix.hasPrefix("threshold-session-50") }
        let twenty = poster.posts.filter { $0.idPrefix.hasPrefix("threshold-session-20") }
        #expect(fifty.count == 1)
        #expect(twenty.count == 1)
    }

    // MARK: - AC15d: Depleted / restored

    /// A depleted notification fires on reaching 0, and a restored one fires on recovery.
    @Test
    func depletedThenRestoredFires() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50, 20], soundEnabled: false)

        // Baseline above zero.
        notifier.evaluate(old: nil, new: snapshot(sessionRemaining: 30), settings: settings)
        // Deplete.
        notifier.evaluate(
            old: snapshot(sessionRemaining: 30),
            new: snapshot(sessionRemaining: 0),
            settings: settings)
        // Restore (after a reset).
        notifier.evaluate(
            old: snapshot(sessionRemaining: 0),
            new: snapshot(sessionRemaining: 100),
            settings: settings)

        let depleted = poster.posts.filter { $0.idPrefix == "depleted-session" }
        let restored = poster.posts.filter { $0.idPrefix == "restored-session" }
        #expect(depleted.count == 1)
        #expect(restored.count == 1)
        #expect(depleted.first?.body == "Claude Session quota exhausted")
        #expect(restored.first?.body == "Claude Session quota restored")
    }

    /// After a window resets above a fired threshold, the threshold can fire again on the next
    /// downward crossing (anti-spam set is cleared).
    @Test
    func thresholdRefiresAfterRecovery() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50], soundEnabled: false)

        notifier.evaluate(old: nil, new: snapshot(sessionRemaining: 80), settings: settings)
        notifier.evaluate(
            old: snapshot(sessionRemaining: 80),
            new: snapshot(sessionRemaining: 40),
            settings: settings) // fire 50
        notifier.evaluate(
            old: snapshot(sessionRemaining: 40),
            new: snapshot(sessionRemaining: 90),
            settings: settings) // recover → clear
        notifier.evaluate(
            old: snapshot(sessionRemaining: 90),
            new: snapshot(sessionRemaining: 40),
            settings: settings) // fire 50 again

        let warnings = poster.posts.filter { $0.idPrefix.hasPrefix("threshold-session-50") }
        #expect(warnings.count == 2)
    }
}

/// Thread-safe fetch counter for the coalescing test.
private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Thread-safe phase recorder for the propagation test.
private actor PhaseRecorder {
    private(set) var phases: [RefreshPhase] = []
    func record(_ phase: RefreshPhase) { phases.append(phase) }
}
