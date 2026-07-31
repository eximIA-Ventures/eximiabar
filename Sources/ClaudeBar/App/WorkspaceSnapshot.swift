import ClaudeBarCore
import Foundation

/// What one account pane can be showing right now (EXB-5.3 AC1).
enum PaneStatus: String, Sendable, Equatable {
    /// A live account with a fresh reading.
    case live
    /// An archived account whose captured token has not expired yet.
    case archivedValid
    /// An archived account past `tokenExpiresAt` — terminal, never renewed (EXB-5.2 AC5).
    case archivedExpired
    /// The provider answered, but with nothing renderable (expired Codex token, transient failure).
    case unavailable
}

/// The immutable aggregate the whole UI renders from once the app knows about several accounts
/// (EXB-5.3 AC1) — one pane per Claude account of the roster, plus the Codex provider when present.
///
/// ## Why this type exists at all
///
/// `AppState` must keep publishing **exactly one** observable property assigned **atomically once
/// per refresh cycle** (invariant I3). A dictionary (`[AccountKey: DisplaySnapshot]`) would be one
/// property on paper and N observable mutations in practice — the `@Observable` storm this project
/// exists to eliminate. So the collection is folded into a single immutable value: the cycle
/// assembles the whole thing off-MainActor and hands it over in one assignment, and `snapshot` /
/// `menuBarSnapshot` become **computed** reads of it, which are not storage and therefore add no
/// second notification source.
///
/// ## Focus is session state, never persisted (decision D-C)
///
/// `focusedKey` says which pane the popover is showing. It is deliberately **not** reachable from
/// any initializer that could seed it from disk: the only public initializer pins it to
/// `menuBarKey`, and the only way to move it is `withFocus(_:)`, an in-memory reassignment. A fresh
/// launch therefore always opens on the live Claude account, by construction rather than by
/// convention.
struct WorkspaceSnapshot: Sendable, Equatable {
    /// One account's pane.
    struct AccountPane: Sendable, Equatable {
        let identity: AccountIdentity
        let lifecycle: AccountLifecycle
        /// `nil` for an archived account we hold no reading for, or an unavailable provider.
        let display: DisplaySnapshot?
        let status: PaneStatus

        init(
            identity: AccountIdentity,
            lifecycle: AccountLifecycle,
            display: DisplaySnapshot?,
            status: PaneStatus)
        {
            self.identity = identity
            self.lifecycle = lifecycle
            self.display = display
            self.status = status
        }

        var key: AccountKey { self.identity.key }

        func withDisplay(_ display: DisplaySnapshot?) -> AccountPane {
            AccountPane(
                identity: self.identity,
                lifecycle: self.lifecycle,
                display: display,
                status: self.status)
        }
    }

    /// One entry per known account, stable order: live Claude, Codex, then archived (most recently
    /// seen first).
    let accounts: [AccountPane]
    /// Which pane the popover shows (see D-C above).
    let focusedKey: AccountKey
    /// Which pane feeds the menu-bar icon — **always** the live Claude account.
    let menuBarKey: AccountKey
    let updatedAt: Date

    /// The only public initializer: focus starts pinned to the menu-bar account (D-C).
    init(accounts: [AccountPane], menuBarKey: AccountKey, updatedAt: Date) {
        self.init(
            accounts: accounts,
            focusedKey: menuBarKey,
            menuBarKey: menuBarKey,
            updatedAt: updatedAt)
    }

    /// Private so `focusedKey` can only diverge from `menuBarKey` through `withFocus(_:)` — an
    /// in-memory move that no persistence path can reach (D-C).
    private init(
        accounts: [AccountPane],
        focusedKey: AccountKey,
        menuBarKey: AccountKey,
        updatedAt: Date)
    {
        self.accounts = accounts
        self.focusedKey = focusedKey
        self.menuBarKey = menuBarKey
        self.updatedAt = updatedAt
    }

    // MARK: - Derived reads

    func pane(for key: AccountKey) -> AccountPane? {
        self.accounts.first { $0.key == key }
    }

    /// The pane in focus, falling back to the menu-bar pane when the focused key is gone (an account
    /// removed from the roster between cycles).
    var focused: AccountPane? {
        self.pane(for: self.focusedKey) ?? self.menuBar
    }

    var menuBar: AccountPane? {
        self.pane(for: self.menuBarKey)
    }

    /// Every pane of a **live** account — the Claude account the CLI is logged into plus Codex when
    /// present. This is what the quota notifier is allowed to look at (AC4.11).
    var livePanes: [AccountPane] {
        self.accounts.filter { $0.lifecycle == .live }
    }

    // MARK: - Transformations (all pure, all one new value)

    /// Move the popover focus. Free: no fetch, no I/O — the data is already in memory (AC5.14).
    /// An unknown key is a no-op rather than a broken focus.
    func withFocus(_ key: AccountKey) -> WorkspaceSnapshot {
        guard self.accounts.contains(where: { $0.key == key }) else { return self }
        return WorkspaceSnapshot(
            accounts: self.accounts,
            focusedKey: key,
            menuBarKey: self.menuBarKey,
            updatedAt: self.updatedAt)
    }

    func replacingDisplay(for key: AccountKey, with display: DisplaySnapshot?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            accounts: self.accounts.map { $0.key == key ? $0.withDisplay(display) : $0 },
            focusedKey: self.focusedKey,
            menuBarKey: self.menuBarKey,
            updatedAt: self.updatedAt)
    }

    /// Flip the spinner on for the live panes without discarding what is already on screen.
    /// Archived panes are untouched — nothing is being fetched for them, ever.
    func refreshingLivePanes() -> WorkspaceSnapshot {
        self.mappingLiveDisplays { DisplaySnapshot.refreshing($0) }
    }

    /// Clear the spinner without publishing new data (a cycle that produced nothing).
    func clearingRefreshing() -> WorkspaceSnapshot {
        self.mappingLiveDisplays { display in
            guard let display, display.isRefreshing else { return display }
            return display.settingRefreshing(false)
        }
    }

    private func mappingLiveDisplays(
        _ transform: (DisplaySnapshot?) -> DisplaySnapshot?) -> WorkspaceSnapshot
    {
        WorkspaceSnapshot(
            accounts: self.accounts.map { pane in
                pane.lifecycle == .live ? pane.withDisplay(transform(pane.display)) : pane
            },
            focusedKey: self.focusedKey,
            menuBarKey: self.menuBarKey,
            updatedAt: self.updatedAt)
    }
}

// MARK: - Assembly

extension WorkspaceSnapshot {
    /// The key used for the live Claude account when its identity could not be resolved (no roster
    /// entry and no e-mail on the reading). Keeps the pane addressable rather than absent.
    static let claudeLiveFallbackKey = AccountKey(provider: .claude, identifier: "live")
    /// Same idea for Codex, used when the provider answered without a decodable identity.
    static let codexLiveFallbackKey = AccountKey(provider: .codex, identifier: "live")

    static let claudeLiveFallbackIdentity = AccountIdentity(
        key: WorkspaceSnapshot.claudeLiveFallbackKey,
        email: "")
    static let codexLiveFallbackIdentity = AccountIdentity(
        key: WorkspaceSnapshot.codexLiveFallbackKey,
        email: "",
        displayName: "Codex")

    /// A one-account workspace — the shape every pre-multi-account consumer still sees (AC6.16).
    static func singleAccount(
        _ display: DisplaySnapshot?,
        identity: AccountIdentity = WorkspaceSnapshot.claudeLiveFallbackIdentity,
        updatedAt: Date = Date()) -> WorkspaceSnapshot
    {
        WorkspaceSnapshot(
            accounts: [AccountPane(
                identity: identity,
                lifecycle: .live,
                display: display,
                status: .live)],
            menuBarKey: identity.key,
            updatedAt: updatedAt)
    }

    /// Fold one cycle's results into the aggregate (AC3).
    ///
    /// `archived` comes straight from the roster index — **metadata only, zero fetch, zero
    /// keychain**. That is the structural reason an archived account can never be refreshed: no
    /// code path here can ask for one.
    static func assemble(
        claude: AccountPane,
        codex: AccountPane?,
        archived: [AccountRosterEntry],
        now: Date) -> WorkspaceSnapshot
    {
        var panes: [AccountPane] = [claude]
        if let codex { panes.append(codex) }
        for entry in archived where entry.lifecycle == .archived {
            guard !panes.contains(where: { $0.key == entry.key }) else { continue }
            panes.append(Self.archivedPane(from: entry, now: now))
        }
        return WorkspaceSnapshot(accounts: panes, menuBarKey: claude.key, updatedAt: now)
    }

    /// The live Claude pane. Its identity comes from the roster when the resolver has seen the
    /// account, else from the reading's own e-mail, else from the opaque fallback.
    static func claudePane(
        display: DisplaySnapshot?,
        rosterLive: AccountRosterEntry?) -> AccountPane
    {
        AccountPane(
            identity: Self.claudeIdentity(display: display, rosterLive: rosterLive),
            lifecycle: .live,
            display: display,
            status: .live)
    }

    static func claudeIdentity(
        display: DisplaySnapshot?,
        rosterLive: AccountRosterEntry?) -> AccountIdentity
    {
        if let rosterLive { return rosterLive.identity }
        let email = display?.identity.email.map(AccountKey.normalize) ?? ""
        guard !email.isEmpty else { return Self.claudeLiveFallbackIdentity }
        return AccountIdentity(
            key: AccountKey(provider: .claude, identifier: email),
            email: email,
            displayName: display?.identity.name)
    }

    /// Map the Codex provider's answer onto a pane. `.absent` returns `nil`: a user who does not use
    /// Codex sees no Codex row at all — no error, no empty card (EXB-5.4 AC4.12).
    static func codexPane(from state: CodexProviderState, now: Date) -> AccountPane? {
        switch state {
        case .absent:
            return nil
        case let .expired(message):
            return Self.codexUnavailablePane(message: message, now: now)
        case let .available(usage):
            return AccountPane(
                identity: usage.account,
                lifecycle: .live,
                display: DisplaySnapshot.from(usage.snapshot),
                status: .live)
        }
    }

    /// A Codex pane that carries only a message — an expired token or a failed fetch. It is still
    /// `.live` (it is the current Codex account), but with no windows, so the notifier finds nothing
    /// to evaluate on it and the Claude panel is untouched (EXB-5.4 AC4.11).
    static func codexUnavailablePane(message: String, now: Date) -> AccountPane {
        AccountPane(
            identity: Self.codexLiveFallbackIdentity,
            lifecycle: .live,
            display: DisplaySnapshot.errorOnly(.authRequired(message), at: now),
            status: .unavailable)
    }

    /// An archived account: metadata only, never a reading (`display == nil`). "Expired" is derived
    /// from `tokenExpiresAt` without touching the keychain (EXB-5.2 AC2).
    static func archivedPane(from entry: AccountRosterEntry, now: Date) -> AccountPane {
        let expired = entry.tokenExpiresAt.map { $0 <= now } ?? false
        return AccountPane(
            identity: entry.identity,
            lifecycle: .archived,
            display: nil,
            status: expired ? .archivedExpired : .archivedValid)
    }
}
