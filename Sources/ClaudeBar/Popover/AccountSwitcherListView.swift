import ClaudeBarCore
import SwiftUI

/// One row of the inline account switcher — a **pure projection** of one
/// `WorkspaceSnapshot.AccountPane` (EXB-5.5 AC3).
///
/// Everything the row draws is decided in this value type: which dot is filled, which status the row
/// carries, which row is the focused one. That is what makes the switcher's behaviour provable
/// without instantiating a single view.
///
/// Localization is deliberately **outside** the model: the row stores the raw `PaneStatus` and
/// `Provider`, and `statusLabel(for:)` / `providerLabel(for:)` resolve the strings at render time. So
/// two items compare equal in any language, and the tests do not depend on the active `.lproj`.
struct AccountSwitcherItem: Identifiable, Equatable {
    let key: AccountKey
    /// The e-mail when the identity resolved, else the display name, else the provider's own name —
    /// the row always has something addressable to show.
    let title: String
    let status: PaneStatus
    let isFocused: Bool

    var id: String { "\(self.key.provider.rawValue):\(self.key.identifier)" }

    var provider: Provider { self.key.provider }

    /// A filled dot means "this account is alive right now". Archived panes (valid or expired) and an
    /// unavailable provider all get the hollow dot — none of them is being refreshed.
    var isDotFilled: Bool { self.status == .live }

    /// An expired archived account is the one state the user has to act on, so it is the only one
    /// rendered in a warning tint.
    var needsAttention: Bool { self.status == .archivedExpired }

    /// The whole list, derived from the workspace and **nothing else** (AC3.7): no roster store, no
    /// keychain, no fetch. The panes already travelled off-MainActor with the refresh cycle, so
    /// building this list is pure arithmetic over data already in memory.
    static func items(from workspace: WorkspaceSnapshot) -> [AccountSwitcherItem] {
        // `focused` falls back to the menu-bar pane when the focused key vanished between cycles, so
        // the highlight follows what is actually on screen rather than a dangling key.
        let focusedKey = workspace.focused?.key ?? workspace.focusedKey
        return workspace.accounts.map { pane in
            AccountSwitcherItem(
                key: pane.key,
                title: Self.title(for: pane),
                status: pane.status,
                isFocused: pane.key == focusedKey)
        }
    }

    static func title(for pane: WorkspaceSnapshot.AccountPane) -> String {
        if !pane.identity.email.isEmpty { return pane.identity.email }
        if let name = pane.identity.displayName, !name.isEmpty { return name }
        if let email = pane.display?.identity.email, !email.isEmpty { return email }
        return Self.providerLabel(for: pane.key.provider)
    }

    static func providerLabel(for provider: Provider) -> String {
        switch provider {
        case .claude: L("popover.provider_name")
        case .codex: L("switcher.provider.codex")
        }
    }

    static func statusLabel(for status: PaneStatus) -> String {
        switch status {
        case .live: L("switcher.status.live")
        case .archivedValid: L("switcher.status.archived")
        case .archivedExpired: L("switcher.status.expired")
        case .unavailable: L("switcher.status.unavailable")
        }
    }
}

/// The inline account list that replaces the card body when the header chip is tapped (AC1/AC2).
///
/// **It is a plain `VStack` of buttons, hosted by the same `NSPanel` the card already lives in.** Not
/// a pop-up button, not an AppKit menu, not SwiftUI's own menu control — every one of those
/// materializes a real `NSMenu` underneath, which drags back the menu-tracking run loop this whole
/// project exists to avoid (I4/R18). Switching accounts here is a content swap inside a view tree
/// that is already on screen, so no new window and no new run loop is created.
struct AccountSwitcherListView: View {
    let items: [AccountSwitcherItem]
    let onSelect: (AccountKey) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: self.onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text(L("switcher.title"))
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("switcher.back"))

            Divider()

            ForEach(self.items) { item in
                AccountSwitcherRow(item: item) { self.onSelect(item.key) }
            }
        }
    }
}

/// A single selectable account row: state dot, provider + account, status line, focus checkmark.
private struct AccountSwitcherRow: View {
    let item: AccountSwitcherItem
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.popoverTheme) private var popoverTheme

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: 8) {
                StateDot(filled: self.item.isDotFilled, tint: PopoverStyle.accent(for: self.popoverTheme))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(AccountSwitcherItem.providerLabel(for: self.item.provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(self.item.title)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(AccountSwitcherItem.statusLabel(for: self.item.status))
                        .font(.caption2)
                        .foregroundStyle(self.item.needsAttention
                            ? Color(nsColor: .systemOrange)
                            : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                if self.item.isFocused {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PopoverStyle.accent(for: self.popoverTheme))
                        .padding(.top, 2)
                }
            }
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in self.isHovered = hovered }
        .accessibilityLabel("\(AccountSwitcherItem.providerLabel(for: self.item.provider)) \(self.item.title)")
        .accessibilityValue(AccountSwitcherItem.statusLabel(for: self.item.status))
    }
}

/// The lifecycle dot: filled for a live account, hollow otherwise.
private struct StateDot: View {
    let filled: Bool
    let tint: Color

    var body: some View {
        Group {
            if self.filled {
                Circle().fill(self.tint)
            } else {
                Circle().stroke(Color.secondary.opacity(0.7), lineWidth: 1)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}
