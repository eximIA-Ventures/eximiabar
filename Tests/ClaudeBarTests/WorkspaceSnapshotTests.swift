import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-5.3 — the immutable aggregate itself: assembly, focus (D-C) and the archived-pane contract.
@MainActor
struct WorkspaceSnapshotTests {
    // MARK: - Fixtures

    static func key(_ provider: Provider, _ identifier: String) -> AccountKey {
        AccountKey(provider: provider, identifier: identifier)
    }

    static func identity(_ provider: Provider, _ email: String) -> AccountIdentity {
        AccountIdentity(key: key(provider, email), email: email)
    }

    static func display(sessionRemaining: Double, at date: Date = Date()) -> DisplaySnapshot {
        DisplaySnapshot(
            session: RateWindow(
                utilization: 100 - sessionRemaining,
                resetsAt: nil,
                windowMinutes: 300),
            weekly: RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 10080),
            updatedAt: date)
    }

    static func archivedEntry(
        _ email: String,
        expiresAt: Date?,
        lastSeenAt: Date = Date()) -> AccountRosterEntry
    {
        AccountRosterEntry(
            identity: identity(.claude, email),
            lifecycle: .archived,
            plan: "pro",
            capturedAt: lastSeenAt,
            lastSeenAt: lastSeenAt,
            tokenExpiresAt: expiresAt)
    }

    static func liveEntry(_ email: String) -> AccountRosterEntry {
        AccountRosterEntry(
            identity: identity(.claude, email),
            lifecycle: .live,
            plan: "max",
            capturedAt: Date(),
            lastSeenAt: Date(),
            tokenExpiresAt: Date().addingTimeInterval(3600))
    }

    // MARK: - AC1 / AC3: assembly

    /// The aggregate carries one pane per account: the live Claude one, the Codex one, and every
    /// archived row of the roster — in a stable order with the live account first.
    @Test
    func assembleBuildsOnePanePerAccountWithLiveFirst() {
        let now = Date()
        let codex = WorkspaceSnapshot.AccountPane(
            identity: Self.identity(.codex, "hugo@openai.example"),
            lifecycle: .live,
            display: Self.display(sessionRemaining: 90, at: now),
            status: .live)

        let workspace = WorkspaceSnapshot.assemble(
            claude: WorkspaceSnapshot.claudePane(
                display: Self.display(sessionRemaining: 70, at: now),
                rosterLive: Self.liveEntry("hugo@live.example")),
            codex: codex,
            archived: [
                Self.archivedEntry("old-a@example.com", expiresAt: now.addingTimeInterval(3600)),
                Self.archivedEntry("old-b@example.com", expiresAt: now.addingTimeInterval(-60)),
            ],
            now: now)

        #expect(workspace.accounts.count == 4)
        #expect(workspace.accounts[0].key == Self.key(.claude, "hugo@live.example"))
        #expect(workspace.menuBarKey == Self.key(.claude, "hugo@live.example"))
        #expect(workspace.accounts[1].key == Self.key(.codex, "hugo@openai.example"))
        // "Expired" is derived from `tokenExpiresAt` alone — no keychain read anywhere in here.
        #expect(workspace.accounts[2].status == .archivedValid)
        #expect(workspace.accounts[3].status == .archivedExpired)
    }

    /// An archived pane never carries a reading: it is metadata only, which is what makes
    /// "archived accounts are never fetched" structural rather than a rule someone has to remember.
    @Test
    func archivedPanesCarryNoReadingAndAreNeverLive() {
        let now = Date()
        let workspace = WorkspaceSnapshot.assemble(
            claude: WorkspaceSnapshot.claudePane(display: Self.display(sessionRemaining: 50), rosterLive: nil),
            codex: nil,
            archived: [Self.archivedEntry("old@example.com", expiresAt: now.addingTimeInterval(600))],
            now: now)

        let archived = workspace.accounts.filter { $0.lifecycle == .archived }
        #expect(archived.count == 1)
        #expect(archived[0].display == nil)
        #expect(workspace.livePanes.allSatisfy { $0.lifecycle == .live })
    }

    /// A live roster row is never duplicated as an archived pane, even if the caller passes the
    /// whole roster (which it does).
    @Test
    func assembleIgnoresLiveRosterRowsWhenBuildingArchivedPanes() {
        let now = Date()
        let workspace = WorkspaceSnapshot.assemble(
            claude: WorkspaceSnapshot.claudePane(
                display: Self.display(sessionRemaining: 50),
                rosterLive: Self.liveEntry("hugo@live.example")),
            codex: nil,
            archived: [Self.liveEntry("hugo@live.example")],
            now: now)

        #expect(workspace.accounts.count == 1)
    }

    /// `.absent` means "this user does not use Codex" — no pane at all, no error row, no noise.
    @Test
    func codexAbsentProducesNoPane() {
        #expect(WorkspaceSnapshot.codexPane(from: .absent, now: Date()) == nil)
    }

    /// An expired Codex token still produces a pane (the user must be told), but one with no
    /// windows — so nothing downstream can read a quota off it.
    @Test
    func codexExpiredProducesUnavailablePaneWithoutWindows() {
        let pane = WorkspaceSnapshot.codexPane(
            from: .expired(CodexUsageFetcher.expiredMessage),
            now: Date())
        #expect(pane?.status == .unavailable)
        #expect(pane?.lifecycle == .live)
        #expect(pane?.display?.session == nil)
        #expect(pane?.display?.error != nil)
    }

    // MARK: - AC5 (D-C): focus

    /// D-C, at the type level: the only public initializer pins the focus to the menu-bar account,
    /// so no construction path — including one that read something off disk — can open the app on
    /// a previously focused account.
    @Test
    func focusResetsToLiveOnFreshAppStateConstruction() {
        let liveKey = Self.key(.claude, "hugo@live.example")
        let archivedKey = Self.key(.claude, "old@example.com")

        let fresh = WorkspaceSnapshot(
            accounts: [
                WorkspaceSnapshot.AccountPane(
                    identity: Self.identity(.claude, "hugo@live.example"),
                    lifecycle: .live,
                    display: Self.display(sessionRemaining: 80),
                    status: .live),
                WorkspaceSnapshot.AccountPane(
                    identity: Self.identity(.claude, "old@example.com"),
                    lifecycle: .archived,
                    display: nil,
                    status: .archivedValid),
            ],
            menuBarKey: liveKey,
            updatedAt: Date())

        #expect(fresh.focusedKey == fresh.menuBarKey)

        // Move the focus during the session…
        let switched = fresh.withFocus(archivedKey)
        #expect(switched.focusedKey == archivedKey)

        // …then rebuild from the same accounts, as a relaunch does. The focus is back on the live
        // account: the previous session's choice is nowhere to be read from.
        let relaunched = WorkspaceSnapshot(
            accounts: switched.accounts,
            menuBarKey: liveKey,
            updatedAt: Date())
        #expect(relaunched.focusedKey == liveKey)
        #expect(relaunched.focusedKey == relaunched.menuBarKey)
    }

    /// Focusing an account that is not in the workspace is a no-op, never a broken focus.
    @Test
    func withFocusIgnoresUnknownAccount() {
        let workspace = WorkspaceSnapshot.singleAccount(Self.display(sessionRemaining: 40))
        let unchanged = workspace.withFocus(Self.key(.codex, "nobody@example.com"))
        #expect(unchanged == workspace)
    }

    /// Moving the focus never moves the menu-bar account: the icon is anchored to the live account
    /// by construction (AC4.7).
    @Test
    func menuBarNeverChangesWhenFocusChanges() {
        let now = Date()
        let workspace = WorkspaceSnapshot.assemble(
            claude: WorkspaceSnapshot.claudePane(
                display: Self.display(sessionRemaining: 70, at: now),
                rosterLive: Self.liveEntry("hugo@live.example")),
            codex: WorkspaceSnapshot.AccountPane(
                identity: Self.identity(.codex, "hugo@openai.example"),
                lifecycle: .live,
                display: Self.display(sessionRemaining: 10, at: now),
                status: .live),
            archived: [],
            now: now)

        let focusedOnCodex = workspace.withFocus(Self.key(.codex, "hugo@openai.example"))

        #expect(focusedOnCodex.menuBarKey == workspace.menuBarKey)
        #expect(focusedOnCodex.menuBar?.display == workspace.menuBar?.display)
        #expect(focusedOnCodex.focused?.key == Self.key(.codex, "hugo@openai.example"))
    }

    // MARK: - Identity resolution

    /// With no roster entry, the live pane is keyed by the reading's own e-mail; with neither, by
    /// the opaque fallback — the pane stays addressable in every case.
    @Test
    func claudeIdentityFallsBackFromRosterToEmailToOpaqueKey() {
        let fromRoster = WorkspaceSnapshot.claudeIdentity(
            display: nil,
            rosterLive: Self.liveEntry("roster@example.com"))
        #expect(fromRoster.key == Self.key(.claude, "roster@example.com"))

        let withEmail = DisplaySnapshot(
            session: nil,
            weekly: nil,
            identity: DisplaySnapshot.Identity(name: "Hugo", email: "  Hugo@Example.COM "),
            updatedAt: Date())
        let fromDisplay = WorkspaceSnapshot.claudeIdentity(display: withEmail, rosterLive: nil)
        // Normalized (trim + lowercase) — the same rule the roster uses, so the keys can match.
        #expect(fromDisplay.key == Self.key(.claude, "hugo@example.com"))

        let opaque = WorkspaceSnapshot.claudeIdentity(display: nil, rosterLive: nil)
        #expect(opaque.key == WorkspaceSnapshot.claudeLiveFallbackKey)
    }

    // MARK: - Spinner

    /// The spinner is a live-pane concern: archived panes have nothing in flight to spin for.
    @Test
    func refreshingOnlyTouchesLivePanes() {
        let now = Date()
        let workspace = WorkspaceSnapshot.assemble(
            claude: WorkspaceSnapshot.claudePane(
                display: Self.display(sessionRemaining: 60, at: now),
                rosterLive: Self.liveEntry("hugo@live.example")),
            codex: nil,
            archived: [Self.archivedEntry("old@example.com", expiresAt: now.addingTimeInterval(600))],
            now: now)

        let refreshing = workspace.refreshingLivePanes()
        #expect(refreshing.menuBar?.display?.isRefreshing == true)
        // Windows preserved while the spinner is on — the anti-flicker contract.
        #expect(refreshing.menuBar?.display?.session != nil)
        #expect(refreshing.accounts.last?.display == nil)

        let cleared = refreshing.clearingRefreshing()
        #expect(cleared.menuBar?.display?.isRefreshing == false)
        #expect(cleared.menuBar?.display?.session != nil)
    }
}
