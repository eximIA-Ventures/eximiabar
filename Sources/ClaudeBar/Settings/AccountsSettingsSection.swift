import ClaudeBarCore
import SwiftUI

/// The two operations Settings needs on the account roster, as plain `Sendable` closures
/// (EXB-5.5 AC5).
///
/// Settings depends on this port rather than on the roster actor itself, for two reasons that both
/// matter. First, R10: the actor's file and keychain I/O must never be reachable from a view body,
/// and a closure pair that can only be `await`ed makes the synchronous call impossible to write.
/// Second, it keeps the app's single reference to the roster actor where EXB-5.2 put it — in
/// `LiveUsageProvider`, which builds it off-MainActor — so the store still has exactly one owner.
struct AccountRosterAccess: Sendable {
    var load: @Sendable () async -> [AccountRosterEntry]
    var remove: @Sendable (AccountKey) async -> Void

    /// The no-op port used by previews, tests and any build without a wired roster.
    static let empty = AccountRosterAccess(load: { [] }, remove: { _ in })
}

/// Drives the Settings account list: holds the roster snapshot the pane renders and routes every
/// mutation through a `Task` (AC5.12 — the actor is `await`ed, never called from `body`).
@MainActor
@Observable
final class AccountRosterViewModel {
    private(set) var entries: [AccountRosterEntry] = []
    /// `true` while a load or a removal is in flight, so the rows can be disabled instead of
    /// letting a second click race the first.
    private(set) var isBusy = false

    @ObservationIgnored private let access: AccountRosterAccess

    init(access: AccountRosterAccess = .empty) {
        self.access = access
    }

    /// Refresh the list. Safe to call from `onAppear`: the read happens inside the task, off the
    /// main actor, and only the assignment comes back here.
    func reload() {
        Task { await self.reloadAndAwait() }
    }

    /// Forget one account — index row **and** archived keychain secret, both dropped by the port's
    /// `remove` (AC5.11).
    func remove(_ key: AccountKey) {
        Task { await self.removeAndAwait(key) }
    }

    /// The same work as `reload()`, awaitable — the seam the tests drive so they never sleep on a
    /// detached task.
    func reloadAndAwait() async {
        self.isBusy = true
        self.entries = await self.access.load()
        self.isBusy = false
    }

    /// The awaitable form of `remove(_:)`, for the same reason.
    func removeAndAwait(_ key: AccountKey) async {
        self.isBusy = true
        await self.access.remove(key)
        self.entries = await self.access.load()
        self.isBusy = false
    }
}

/// The "Accounts" section of the General pane (AC5.10): the whole roster, one remove button per row,
/// and the note explaining that archived accounts are read-only.
///
/// Plain rows and plain buttons — no pop-up control of any kind, for the same reason the switcher has
/// none (I4/R18).
@MainActor
struct AccountsSettingsSection: View {
    let model: AccountRosterViewModel

    var body: some View {
        SettingsSection(contentSpacing: 10) {
            SectionHeader(L("settings.accounts.section"))

            Text(L("settings.accounts.readonly_note"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if self.model.entries.isEmpty {
                Text(L("settings.accounts.empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.model.entries, id: \.key) { entry in
                        AccountRow(entry: entry, isBusy: self.model.isBusy) {
                            self.model.remove(entry.key)
                        }
                    }
                }
            }
        }
        .onAppear { self.model.reload() }
    }
}

/// One roster row: provider + e-mail, a lifecycle badge, and the remove action.
@MainActor
private struct AccountRow: View {
    let entry: AccountRosterEntry
    let isBusy: Bool
    let onRemove: () -> Void

    /// An archived account whose captured token is already past its expiry — the roster keeps the
    /// row so the user can recognise and clear it, but nothing can be read from it any more.
    private var isExpired: Bool {
        self.entry.lifecycle == .archived
            && (self.entry.tokenExpiresAt.map { $0 <= Date() } ?? false)
    }

    private var badge: String {
        if self.entry.lifecycle == .live { return L("settings.accounts.badge.live") }
        return self.isExpired
            ? L("settings.accounts.badge.expired")
            : L("settings.accounts.badge.archived")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(AccountSwitcherItem.providerLabel(for: self.entry.key.provider))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(self.entry.identity.email.isEmpty
                ? self.entry.key.identifier
                : self.entry.identity.email)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(self.badge)
                .font(.caption2)
                .foregroundStyle(self.isExpired ? Color(nsColor: .systemOrange) : Color.secondary)

            Spacer(minLength: 8)

            Button(L("settings.accounts.remove"), action: self.onRemove)
                .controlSize(.small)
                .disabled(self.isBusy)
        }
    }
}
