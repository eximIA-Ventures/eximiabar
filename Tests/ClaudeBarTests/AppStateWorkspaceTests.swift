import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.3 — the generalized `AppState`: one assignment per cycle (T-I3), a free focus switch,
/// and a notifier that sees the live panes of every provider but never an archived one.
@MainActor
struct AppStateWorkspaceTests {
    // MARK: - Fixtures

    private final class RecordingPoster: QuotaNotificationPosting {
        struct Post: Equatable {
            let idPrefix: String
            let body: String
        }

        private(set) var posts: [Post] = []

        func post(idPrefix: String, title: String, body: String, soundEnabled: Bool) {
            self.posts.append(Post(idPrefix: idPrefix, body: body))
        }
    }

    private static func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "exb.workspace.\(UUID().uuidString)")!
    }

    private static func settings() -> SettingsStore {
        SettingsStore(defaults: Self.ephemeralDefaults(), refreshCadence: .manual)
    }

    /// A predictor writing to a throwaway file so no test ever touches the real sample history.
    private static func isolatedPredictor() -> ExhaustionPredictor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-workspace-\(UUID().uuidString).json")
        return ExhaustionPredictor(fileURL: url)
    }

    nonisolated private static func key(_ provider: Provider, _ identifier: String) -> AccountKey {
        AccountKey(provider: provider, identifier: identifier)
    }

    nonisolated private static func pane(
        _ provider: Provider,
        _ email: String,
        lifecycle: AccountLifecycle,
        sessionRemaining: Double?,
        status: PaneStatus,
        at date: Date = Date()) -> WorkspaceSnapshot.AccountPane
    {
        WorkspaceSnapshot.AccountPane(
            identity: AccountIdentity(key: Self.key(provider, email), email: email),
            lifecycle: lifecycle,
            display: sessionRemaining.map { remaining in
                DisplaySnapshot(
                    session: RateWindow(
                        utilization: 100 - remaining,
                        resetsAt: nil,
                        windowMinutes: 300),
                    weekly: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 10080),
                    updatedAt: date)
            },
            status: status)
    }

    /// A workspace with `count` accounts: 1 live Claude + 1 live Codex + the rest archived.
    nonisolated private static func workspace(accounts count: Int, claudeRemaining: Double = 80)
        -> WorkspaceSnapshot
    {
        var panes: [WorkspaceSnapshot.AccountPane] = [
            Self.pane(.claude, "live@example.com", lifecycle: .live,
                      sessionRemaining: claudeRemaining, status: .live),
        ]
        if count >= 2 {
            panes.append(Self.pane(.codex, "codex@example.com", lifecycle: .live,
                                   sessionRemaining: 90, status: .live))
        }
        for index in 2 ..< max(2, count) {
            panes.append(Self.pane(.claude, "archived-\(index)@example.com", lifecycle: .archived,
                                   sessionRemaining: nil, status: .archivedValid))
        }
        return WorkspaceSnapshot(
            accounts: panes,
            menuBarKey: Self.key(.claude, "live@example.com"),
            updatedAt: Date())
    }

    nonisolated private static func drain() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: - AC3 / T-I3: exactly one assignment per cycle

    /// **T-I3, the invariant of the whole wave.** A refresh cycle over 5 accounts writes `workspace`
    /// the same number of times as a cycle over 1: the spinner flip and the single publish of the
    /// assembled aggregate. Not once per account — that would be the `@Observable` storm this
    /// design exists to prevent.
    @Test
    func oneRefreshCycleAssignsWorkspaceExactlyOnceRegardlessOfAccountCount() async {
        func assignments(forAccounts count: Int) async -> (writes: Int, accounts: Int) {
            let state = AppState(
                fetch: { _ in Self.workspace(accounts: count) },
                settingsStore: Self.settings(),
                notifier: QuotaNotifier(poster: RecordingPoster()),
                predictor: Self.isolatedPredictor())
            state.triggerRefresh(.background)
            await Self.drain()
            return (state.workspaceAssignmentCount, state.workspace?.accounts.count ?? 0)
        }

        let single = await assignments(forAccounts: 1)
        let many = await assignments(forAccounts: 5)

        #expect(single.accounts == 1)
        #expect(many.accounts == 5)
        // One spinner flip + one publish of the completed aggregate.
        #expect(single.writes == 2)
        // The whole point: five accounts cost the same number of observable writes as one.
        #expect(many.writes == single.writes)
    }

    /// The published aggregate is the one the cycle assembled — a single value, not a merge of
    /// per-account updates.
    @Test
    func publishedWorkspaceHoldsEveryPaneOfTheCycle() async {
        let state = AppState(
            fetch: { _ in Self.workspace(accounts: 4) },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()

        #expect(state.workspace?.accounts.count == 4)
        #expect(state.workspace?.livePanes.count == 2)
        #expect(state.menuBarSnapshot != nil)
        #expect(state.snapshot == state.menuBarSnapshot) // focus starts on the live account
    }

    // MARK: - AC5 (D-C): focus is free, and never survives a relaunch

    /// Switching accounts costs one atomic reassignment and **zero fetches** — the data is already
    /// in memory (AC5.14).
    @Test
    func changingFocusNeverTriggersAFetch() async {
        let counter = FetchCounter()
        let state = AppState(
            fetch: { _ in
                await counter.increment()
                return Self.workspace(accounts: 3)
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()
        let fetchesAfterRefresh = await counter.value
        let writesAfterRefresh = state.workspaceAssignmentCount

        state.focusAccount(Self.key(.codex, "codex@example.com"))
        state.focusAccount(Self.key(.claude, "archived-2@example.com"))
        await Self.drain()

        #expect(await counter.value == fetchesAfterRefresh)
        // Two focus moves → two atomic reassignments, no more.
        #expect(state.workspaceAssignmentCount == writesAfterRefresh + 2)
        #expect(state.workspace?.focusedKey == Self.key(.claude, "archived-2@example.com"))
    }

    /// Moving the focus never moves the menu-bar reading: the icon stays on the live account
    /// (AC4.7).
    @Test
    func menuBarSnapshotIsUnaffectedByFocusChange() async {
        let state = AppState(
            fetch: { _ in Self.workspace(accounts: 2) },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()
        let menuBarBefore = state.menuBarSnapshot

        state.focusAccount(Self.key(.codex, "codex@example.com"))

        #expect(state.menuBarSnapshot == menuBarBefore)
        #expect(state.snapshot != state.menuBarSnapshot) // the popover moved; the icon did not
    }

    /// **D-C.** A focus chosen in one session is gone in the next: a freshly constructed `AppState`
    /// running a cycle always lands focused on the live account, and nothing on disk could say
    /// otherwise.
    @Test
    func focusResetsToLiveOnFreshAppStateConstruction() async {
        let first = AppState(
            fetch: { _ in Self.workspace(accounts: 3) },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())
        first.triggerRefresh(.background)
        await Self.drain()
        first.focusAccount(Self.key(.codex, "codex@example.com"))
        #expect(first.workspace?.focusedKey == Self.key(.codex, "codex@example.com"))

        // "Relaunch": a brand-new AppState, same accounts, no state carried over.
        let relaunched = AppState(
            fetch: { _ in Self.workspace(accounts: 3) },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())
        #expect(relaunched.workspace == nil)
        relaunched.triggerRefresh(.background)
        await Self.drain()

        #expect(relaunched.workspace?.focusedKey == relaunched.workspace?.menuBarKey)
        #expect(relaunched.workspace?.focusedKey == Self.key(.claude, "live@example.com"))
    }

    /// Within a session the focus does survive refreshes — otherwise the switcher would snap back
    /// every 60 seconds. This is the flip side of D-C, and the reason the focus lives in memory
    /// rather than being recomputed from scratch each cycle.
    @Test
    func focusSurvivesRefreshWithinTheSameSession() async {
        let state = AppState(
            fetch: { _ in Self.workspace(accounts: 3) },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()
        state.focusAccount(Self.key(.codex, "codex@example.com"))

        state.triggerRefresh(.background)
        await Self.drain()

        #expect(state.workspace?.focusedKey == Self.key(.codex, "codex@example.com"))
    }

    // MARK: - AC4 (D-D): the notifier sees every live pane, and only live panes

    /// **D-D.** Codex crosses its own thresholds and posts its own notification, with its own
    /// dedup key — the Claude alert neither duplicates nor silences it.
    @Test
    func quotaNotifierMonitorsCodexThresholdIndependently() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50, 20], soundEnabled: false)

        let before = WorkspaceSnapshot(
            accounts: [
                Self.pane(.claude, "live@example.com", lifecycle: .live,
                          sessionRemaining: 80, status: .live),
                Self.pane(.codex, "codex@example.com", lifecycle: .live,
                          sessionRemaining: 80, status: .live),
            ],
            menuBarKey: Self.key(.claude, "live@example.com"),
            updatedAt: Date())

        // Both providers drop below 50 in the same cycle.
        let after = WorkspaceSnapshot(
            accounts: [
                Self.pane(.claude, "live@example.com", lifecycle: .live,
                          sessionRemaining: 45, status: .live),
                Self.pane(.codex, "codex@example.com", lifecycle: .live,
                          sessionRemaining: 40, status: .live),
            ],
            menuBarKey: Self.key(.claude, "live@example.com"),
            updatedAt: Date())

        notifier.evaluate(panes: after.accounts, previous: before, settings: settings)

        let claude = poster.posts.filter { $0.idPrefix == "threshold-session-50" }
        let codex = poster.posts.filter { $0.idPrefix == "threshold-session-50-codex" }
        #expect(claude.count == 1)
        #expect(codex.count == 1)
        // Distinct wording, so the user knows which provider is running out.
        #expect(claude.first?.body.contains("Claude") == true)
        #expect(codex.first?.body.contains("Codex") == true)
    }

    /// The dedup key is `(account, window, threshold)`: one provider having already fired at 50 %
    /// must not consume the other's warning (nor re-fire its own).
    @Test
    func quotaNotifierNeverDuplicatesAcrossAccounts() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50], soundEnabled: false)

        func snapshotPair(claude: Double, codex: Double) -> WorkspaceSnapshot {
            WorkspaceSnapshot(
                accounts: [
                    Self.pane(.claude, "live@example.com", lifecycle: .live,
                              sessionRemaining: claude, status: .live),
                    Self.pane(.codex, "codex@example.com", lifecycle: .live,
                              sessionRemaining: codex, status: .live),
                ],
                menuBarKey: Self.key(.claude, "live@example.com"),
                updatedAt: Date())
        }

        let start = snapshotPair(claude: 80, codex: 80)
        // Cycle 1: only Claude crosses.
        let cycle1 = snapshotPair(claude: 45, codex: 70)
        notifier.evaluate(panes: cycle1.accounts, previous: start, settings: settings)
        // Cycle 2: Codex crosses; Claude stays below without re-firing.
        let cycle2 = snapshotPair(claude: 40, codex: 30)
        notifier.evaluate(panes: cycle2.accounts, previous: cycle1, settings: settings)

        #expect(poster.posts.filter { $0.idPrefix == "threshold-session-50" }.count == 1)
        #expect(poster.posts.filter { $0.idPrefix == "threshold-session-50-codex" }.count == 1)
        #expect(notifier.firedThresholds.count == 2) // one per account, never merged
    }

    /// **AC4.11.** An archived account sitting at 0 % remaining — above every configured threshold —
    /// produces nothing at all. Its reading is frozen; alerting on a quota that cannot move is
    /// noise, and the filter lives in the notifier so no caller can bypass it.
    @Test
    func archivedPaneAboveThresholdNeverNotifies() {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let settings = NotificationSettings(thresholds: [50, 20], soundEnabled: false)

        let archivedAtZero = Self.pane(
            .claude, "archived@example.com",
            lifecycle: .archived,
            sessionRemaining: 0,
            status: .archivedValid)
        let before = WorkspaceSnapshot(
            accounts: [archivedAtZero],
            menuBarKey: Self.key(.claude, "archived@example.com"),
            updatedAt: Date())

        notifier.evaluate(panes: [archivedAtZero], previous: before, settings: settings)
        notifier.evaluate(panes: [archivedAtZero], previous: nil, settings: settings)

        #expect(poster.posts.isEmpty)
        #expect(notifier.firedThresholds.isEmpty)
        #expect(notifier.depletedWindows.isEmpty)
    }

    /// End-to-end through `AppState`: a full cycle notifies for both live providers, and for
    /// neither archived one — proving the call site hands over the collection, not the focused pane.
    @Test
    func fullCycleNotifiesEveryLiveProviderAndNoArchivedOne() async {
        let poster = RecordingPoster()
        let notifier = QuotaNotifier(poster: poster)
        let remainings = RemainingSequence(values: [80, 40])
        let state = AppState(
            fetch: { _ in
                let remaining = await remainings.next()
                return WorkspaceSnapshot(
                    accounts: [
                        Self.pane(.claude, "live@example.com", lifecycle: .live,
                                  sessionRemaining: remaining, status: .live),
                        Self.pane(.codex, "codex@example.com", lifecycle: .live,
                                  sessionRemaining: remaining, status: .live),
                        Self.pane(.claude, "archived@example.com", lifecycle: .archived,
                                  sessionRemaining: 0, status: .archivedValid),
                    ],
                    menuBarKey: Self.key(.claude, "live@example.com"),
                    updatedAt: Date())
            },
            settingsStore: Self.settings(),
            notifier: notifier,
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background) // baseline at 80
        await Self.drain()
        state.triggerRefresh(.background) // crosses 50
        await Self.drain()

        #expect(poster.posts.contains { $0.idPrefix == "threshold-session-50" })
        #expect(poster.posts.contains { $0.idPrefix == "threshold-session-50-codex" })
        // The archived account is at 0 % — depleted, above every threshold — and stays silent.
        #expect(poster.posts.allSatisfy { !$0.idPrefix.hasPrefix("depleted") })
    }

    // MARK: - Provider isolation

    /// A Codex failure is contained in the Codex pane: the Claude reading is published intact.
    /// (`WorkspaceSnapshot.codexUnavailablePane` is what `LiveUsageProvider` produces on a throw.)
    @Test
    func codexFailureNeverDegradesTheClaudePane() async {
        let state = AppState(
            fetch: { _ in
                WorkspaceSnapshot.assemble(
                    claude: Self.pane(.claude, "live@example.com", lifecycle: .live,
                                      sessionRemaining: 72, status: .live),
                    codex: WorkspaceSnapshot.codexUnavailablePane(
                        message: "boom",
                        now: Date()),
                    archived: [],
                    now: Date())
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()

        #expect(state.menuBarSnapshot?.session?.remaining == 72)
        #expect(state.menuBarSnapshot?.error == nil)
        let codexPane = state.workspace?.pane(for: WorkspaceSnapshot.codexLiveFallbackKey)
        #expect(codexPane?.status == .unavailable)
        #expect(codexPane?.display?.error != nil)
    }

    // MARK: - AC6.16: single-account compatibility

    /// The convenience initializer still yields a working one-account app: `snapshot` reads back
    /// what was seeded, and it is the menu-bar account too.
    @Test
    func initSnapshotConvenienceWrapsSingleAccountWorkspace() {
        let seeded = DisplaySnapshot(
            session: RateWindow(utilization: 30, resetsAt: nil, windowMinutes: 300),
            weekly: nil,
            updatedAt: Date())
        let state = AppState(
            displayFetch: { _ in nil },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor(),
            snapshot: seeded)

        #expect(state.workspace?.accounts.count == 1)
        #expect(state.snapshot == seeded)
        #expect(state.menuBarSnapshot == seeded)
        #expect(state.workspace?.focusedKey == state.workspace?.menuBarKey)
    }

    /// A cycle through the single-account convenience publishes exactly like the multi-account one:
    /// spinner flip plus one publish.
    @Test
    func singleAccountConvenienceCyclePublishesOnce() async {
        let state = AppState(
            displayFetch: { _ in
                DisplaySnapshot(
                    session: RateWindow(utilization: 10, resetsAt: nil, windowMinutes: 300),
                    weekly: nil,
                    updatedAt: Date())
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()

        #expect(state.workspaceAssignmentCount == 2)
        #expect(state.snapshot?.session?.utilization == 10)
    }

    // MARK: - Assembly does no work for archived accounts

    /// Archived panes are assembled from roster metadata alone — no fetch closure is ever consulted
    /// for them, which is why adding accounts costs nothing per cycle.
    @Test
    func archivedPanesNeverTriggerFetchDuringAssembly() async {
        let counter = FetchCounter()
        let state = AppState(
            fetch: { _ in
                await counter.increment()
                return Self.workspace(accounts: 6) // 1 Claude + 1 Codex + 4 archived
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()

        // Six accounts, one call into the fetch closure — the archived four cost nothing.
        #expect(await counter.value == 1)
        #expect(state.workspace?.accounts.count == 6)
        #expect(state.workspace?.accounts.filter { $0.lifecycle == .archived }.count == 4)
        #expect(state.workspace?.accounts.filter { $0.lifecycle == .archived }
            .allSatisfy { $0.display == nil } == true)
    }

    // MARK: - Error merge survives the generalization

    /// A failed cycle must not zero the windows: the error-only sentinel is merged onto the live
    /// Claude pane's previous reading (the EXB rate-limit fix, preserved through the refactor).
    @Test
    func errorOnlyCycleKeepsPreviousWindowsOnTheLivePane() async {
        let failNext = FailureToggle()
        let state = AppState(
            fetch: { _ in
                if await failNext.isFailing {
                    return WorkspaceSnapshot.assemble(
                        claude: WorkspaceSnapshot.AccountPane(
                            identity: AccountIdentity(
                                key: Self.key(.claude, "live@example.com"),
                                email: "live@example.com"),
                            lifecycle: .live,
                            display: DisplaySnapshot.errorOnly(.networkError("offline")),
                            status: .live),
                        codex: nil,
                        archived: [],
                        now: Date())
                }
                return Self.workspace(accounts: 1, claudeRemaining: 64)
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: RecordingPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        await Self.drain()
        #expect(state.menuBarSnapshot?.session?.remaining == 64)

        await failNext.fail()
        state.triggerRefresh(.background)
        await Self.drain()

        // Windows preserved, error appended.
        #expect(state.menuBarSnapshot?.session?.remaining == 64)
        #expect(state.menuBarSnapshot?.error != nil)
    }
}

/// Thread-safe fetch counter.
private actor FetchCounter {
    private(set) var value = 0
    func increment() { self.value += 1 }
}

/// Emits a scripted sequence of "remaining" values, repeating the last one.
private actor RemainingSequence {
    private var values: [Double]
    private var index = 0

    init(values: [Double]) { self.values = values }

    func next() -> Double {
        defer { self.index = min(self.index + 1, self.values.count - 1) }
        return self.values[self.index]
    }
}

/// Flips a fetch closure from success to failure between cycles.
private actor FailureToggle {
    private(set) var isFailing = false
    func fail() { self.isFailing = true }
}
