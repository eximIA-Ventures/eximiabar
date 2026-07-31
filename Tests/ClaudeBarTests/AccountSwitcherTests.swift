import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

#if os(macOS)
import Security
#endif

/// EXB-5.5 — the inline account switcher and the Settings roster manager.
///
/// The centre of gravity here is `T-R18`: the switcher must never materialize an AppKit menu, in any
/// of its disguises. That is checked mechanically over the source tree rather than by review, because
/// the failure mode it guards is invisible in tests and in debug builds — a menu-tracking run loop
/// only stalls the WindowServer in real use.
@MainActor
struct AccountSwitcherTests {
    // MARK: - Fixtures

    /// The repository root, derived from this file's own path.
    nonisolated private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    nonisolated private static func swiftFiles(under relativePath: String) -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativePath)
        return FileManager.default
            .enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
    }

    /// Every `(file, line, text)` in `relativePath` whose line matches `pattern` — the Swift
    /// equivalent of `grep -rnE`, matched line by line so `^` means "start of line" exactly as it
    /// does for grep.
    nonisolated private static func matches(
        pattern: String,
        under relativePath: String,
        excluding excluded: [String] = []) throws -> [String]
    {
        let regex = try NSRegularExpression(pattern: pattern)
        var hits: [String] = []
        for file in Self.swiftFiles(under: relativePath) {
            guard !excluded.contains(where: { file.path.hasSuffix($0) }) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in source.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    hits.append("\(file.lastPathComponent):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    nonisolated private static func key(_ provider: Provider, _ identifier: String) -> AccountKey {
        AccountKey(provider: provider, identifier: identifier)
    }

    nonisolated private static func pane(
        _ provider: Provider,
        _ email: String,
        lifecycle: AccountLifecycle,
        status: PaneStatus,
        hasDisplay: Bool = true) -> WorkspaceSnapshot.AccountPane
    {
        WorkspaceSnapshot.AccountPane(
            identity: AccountIdentity(key: Self.key(provider, email), email: email),
            lifecycle: lifecycle,
            display: hasDisplay
                ? DisplaySnapshot(
                    session: RateWindow(utilization: 20, resetsAt: nil, windowMinutes: 300),
                    weekly: nil,
                    updatedAt: Date())
                : nil,
            status: status)
    }

    /// Live Claude + live Codex + one valid archive + one expired archive.
    nonisolated private static func fullWorkspace() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            accounts: [
                Self.pane(.claude, "live@example.com", lifecycle: .live, status: .live),
                Self.pane(.codex, "codex@example.com", lifecycle: .live, status: .live),
                Self.pane(.claude, "old@example.com", lifecycle: .archived,
                          status: .archivedValid, hasDisplay: false),
                Self.pane(.claude, "dead@example.com", lifecycle: .archived,
                          status: .archivedExpired, hasDisplay: false),
            ],
            menuBarKey: Self.key(.claude, "live@example.com"),
            updatedAt: Date())
    }

    private static func settings() -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: "exb.switcher.\(UUID().uuidString)")!,
            refreshCadence: .manual)
    }

    private static func isolatedPredictor() -> ExhaustionPredictor {
        ExhaustionPredictor(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("exb-switcher-\(UUID().uuidString).json"))
    }

    // MARK: - AC2 / T-R18: the switcher never materializes an AppKit menu

    /// **The gate of this story.** SwiftUI's own menu control and `NSPopUpButton` both build a real
    /// `NSMenu` underneath, which drags back the menu-tracking run loop the `NSPanel` architecture
    /// exists to avoid. Neither compiles differently, neither fails a unit test, and the freeze only
    /// shows up in production — so the ban is enforced as a mechanical scan of the whole app target.
    ///
    /// The one allowed exception is `App/ClaudeBarApp.swift`, whose two menu constructions predate
    /// this story: they build the app's main menu so the ⌘, key equivalent reaches an `LSUIElement`
    /// agent. That is static system menu-bar content, not dynamic content inside the popover.
    @Test
    nonisolated func switcherNeverMaterializesAnAppKitMenu() throws {
        let hits = try Self.matches(
            pattern: #"NSPopUpButton|NSMenu\(|(^|[^A-Za-z])Menu\s*[{(]|\.menuStyle|MenuPickerStyle"#,
            under: "Sources/ClaudeBar",
            excluding: ["App/ClaudeBarApp.swift"])
        #expect(hits.isEmpty, "menu construct(s) reached the app target: \(hits)")

        // And the exception really is only the pre-existing main-menu install — not a loophole that
        // silently absorbed a new one.
        let exempt = try Self.matches(
            pattern: #"NSMenu\("#,
            under: "Sources/ClaudeBar/App",
            excluding: [])
        #expect(exempt.count == 2)
        #expect(exempt.allSatisfy { $0.hasPrefix("ClaudeBarApp.swift:") })

        // The switcher itself exists and is a plain stack of buttons.
        let switcher = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/ClaudeBar/Popover/AccountSwitcherListView.swift"),
            encoding: .utf8)
        #expect(switcher.contains("struct AccountSwitcherListView: View"))
        #expect(switcher.contains("VStack"))
    }

    // MARK: - AC4.9 (D-C): the switcher introduces no persistence of focus

    /// Focus is session state by construction (`WorkspaceSnapshot` D-C). This proves the UI layer did
    /// not quietly add a parallel one: no `@AppStorage`, no `UserDefaults` write anywhere in the
    /// popover — which is where the entire switcher lives.
    ///
    /// The scan looks at code, not prose: `PopoverTheme.swift` has carried a doc comment naming
    /// `UserDefaults` since before this story, and a comment cannot persist anything.
    @Test
    nonisolated func switcherIntroducesNoFocusPersistence() throws {
        let hits = try Self.matches(
            pattern: #"@AppStorage|UserDefaults"#,
            under: "Sources/ClaudeBar/Popover")
            .filter { line in
                // Strip the `file:line: ` prefix, then drop pure comment lines.
                let code = line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                return !code.hasPrefix("//") && !code.hasPrefix("///") && !code.hasPrefix("*")
            }
        #expect(hits.isEmpty, "the popover persists something it should not: \(hits)")

        // `@AppStorage` is banned outright — there is no legitimate commented use of it either.
        let appStorage = try Self.matches(pattern: #"@AppStorage"#, under: "Sources/ClaudeBar/Popover")
        #expect(appStorage.isEmpty)
    }

    // MARK: - AC3.7 (R10): the switcher reads the workspace, never the roster store

    /// The list is a projection of data that already travelled off-MainActor with the refresh cycle.
    /// If the popover could reach `AccountRosterStore`, it could reach file and keychain I/O from a
    /// view body — which is precisely the class of bug this architecture forbids.
    @Test
    nonisolated func switcherReadsOnlyFromWorkspaceNeverFromRosterStore() throws {
        let hits = try Self.matches(pattern: "AccountRosterStore", under: "Sources/ClaudeBar/Popover")
        #expect(hits.isEmpty, "the popover reaches the roster actor: \(hits)")

        // Positive half of the same claim: the list is built from the workspace.
        let switcher = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/ClaudeBar/Popover/AccountSwitcherListView.swift"),
            encoding: .utf8)
        #expect(switcher.contains("static func items(from workspace: WorkspaceSnapshot)"))
    }

    // MARK: - AC3.6 / AC5.14: navigating the switcher is free

    /// Selecting a row moves the focus and nothing else: one atomic reassignment of the aggregate,
    /// zero fetches. The test drives the exact callback the card wires up, so it proves the wiring,
    /// not just `AppState` in isolation.
    @Test
    func focusSwitchIsInstantWithoutFetch() async throws {
        let counter = FetchCounter()
        let state = AppState(
            fetch: { _ in
                await counter.increment()
                return Self.fullWorkspace()
            },
            settingsStore: Self.settings(),
            notifier: QuotaNotifier(poster: SilentPoster()),
            predictor: Self.isolatedPredictor())

        state.triggerRefresh(.background)
        try? await Task.sleep(for: .milliseconds(150))

        let fetchesAfterRefresh = await counter.value
        let writesAfterRefresh = state.workspaceAssignmentCount

        // Exactly what `UsageCardView` hands to `AccountSwitcherListView.onSelect`.
        let actions = UsageCardActions(focusAccount: { key in state.focusAccount(key) })

        let before = AccountSwitcherItem.items(from: try #require(state.workspace))
        #expect(before.first { $0.isFocused }?.key == Self.key(.claude, "live@example.com"))

        actions.focusAccount(Self.key(.codex, "codex@example.com"))
        try? await Task.sleep(for: .milliseconds(50))

        let after = AccountSwitcherItem.items(from: try #require(state.workspace))
        #expect(after.first { $0.isFocused }?.key == Self.key(.codex, "codex@example.com"))
        #expect(after.filter(\.isFocused).count == 1)

        // The whole point of the design: the reading was already in memory.
        #expect(await counter.value == fetchesAfterRefresh)
        #expect(state.workspaceAssignmentCount == writesAfterRefresh + 1)
        // And the menu-bar icon did not follow the popover.
        #expect(state.workspace?.menuBarKey == Self.key(.claude, "live@example.com"))
    }

    // MARK: - AC3.5: the four visual states

    /// An expired archive is the one state the user must act on, so it must not read like an ordinary
    /// archive. The labels are compared to each other rather than to a literal, so the assertion holds
    /// in every localization.
    @Test
    nonisolated func archivedExpiredRendersDistinctLabel() {
        let items = AccountSwitcherItem.items(from: Self.fullWorkspace())

        let expired = items.first { $0.key.identifier == "dead@example.com" }
        let archived = items.first { $0.key.identifier == "old@example.com" }
        let live = items.first { $0.key.identifier == "live@example.com" }

        #expect(expired?.status == .archivedExpired)
        #expect(archived?.status == .archivedValid)
        #expect(live?.status == .live)

        // Only a live account gets the filled dot; only the expired one is flagged for attention.
        #expect(live?.isDotFilled == true)
        #expect(archived?.isDotFilled == false)
        #expect(expired?.isDotFilled == false)
        #expect(expired?.needsAttention == true)
        #expect(archived?.needsAttention == false)

        let labels = [PaneStatus.live, .archivedValid, .archivedExpired, .unavailable]
            .map(AccountSwitcherItem.statusLabel(for:))
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count) // all four read differently
        // The expired label carries the recovery instruction, so it is the longest of the archives.
        #expect(labels[2].count > labels[1].count)
    }

    /// Codex appears as a first-class row with its own provider label — and disappears entirely when
    /// the provider is absent, rather than showing an empty or errored row.
    @Test
    nonisolated func codexPaneAppearsInSwitcherWhenPresent() {
        let withCodex = AccountSwitcherItem.items(from: Self.fullWorkspace())
        let codex = withCodex.first { $0.provider == .codex }
        #expect(codex != nil)
        #expect(codex?.status == .live)
        #expect(codex?.isDotFilled == true)
        #expect(codex?.title == "codex@example.com")
        #expect(AccountSwitcherItem.providerLabel(for: .codex)
            != AccountSwitcherItem.providerLabel(for: .claude))

        // A user without `~/.codex/auth.json` produces no Codex pane at all (EXB-5.4 AC4.12).
        let claudeOnly = WorkspaceSnapshot.assemble(
            claude: Self.pane(.claude, "live@example.com", lifecycle: .live, status: .live),
            codex: nil,
            archived: [],
            now: Date())
        #expect(AccountSwitcherItem.items(from: claudeOnly).allSatisfy { $0.provider == .claude })
        #expect(AccountSwitcherItem.items(from: claudeOnly).count == 1)
    }

    /// The chip is only clickable when there is somewhere to go: a single-account user sees the
    /// header EXB-1.3 shipped, untouched.
    @Test
    nonisolated func singleAccountWorkspaceYieldsASingleNonSwitchableRow() {
        let single = WorkspaceSnapshot.singleAccount(nil)
        let items = AccountSwitcherItem.items(from: single)
        #expect(items.count == 1)
        #expect(items[0].isFocused)
    }

    // MARK: - AC5: Settings roster management

    /// Removing an account in Settings erases both layers: the index row **and** the archived secret
    /// in the keychain. The store is pinned to a throwaway directory and its own keychain service, so
    /// neither the real index nor the production keychain item is ever touched.
    @Test
    func settingsRemoveAccountClearsIndexAndKeychainSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-switcher-\(UUID().uuidString)")
        let service = "com.eximia.eximiabar.accounts.test.\(UUID().uuidString)"
        let store = AccountRosterStore(supportDirectory: directory, keychainService: service)
        defer {
            try? FileManager.default.removeItem(at: directory)
            #if os(macOS)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
            #endif
        }

        func credentials(_ token: String) -> ClaudeOAuthCredentials {
            ClaudeOAuthCredentials(
                accessToken: token,
                refreshToken: "never-archived",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                scopes: ["user:profile"],
                rateLimitTier: nil,
                subscriptionType: "max")
        }
        func identity(_ email: String) -> AccountIdentity {
            AccountIdentity(key: Self.key(.claude, email), email: email)
        }

        // Log in as A, then switch to B — A is archived, secret and all.
        await store.captureIfIdentityChanged(current: identity("a@example.com"),
                                             credentials: credentials("TOKEN-A"))
        await store.captureIfIdentityChanged(current: identity("b@example.com"),
                                             credentials: credentials("TOKEN-A"))

        let archivedKey = Self.key(.claude, "a@example.com")
        #expect(await store.archivedToken(for: archivedKey) != nil)

        // Exactly the port the Settings pane is built on.
        let model = AccountRosterViewModel(access: AccountRosterAccess(
            load: { await store.roster() },
            remove: { key in await store.remove(key) }))

        await model.reloadAndAwait()
        #expect(model.entries.count == 2)
        #expect(model.isBusy == false)

        await model.removeAndAwait(archivedKey)

        // Gone from the list the pane renders…
        #expect(model.entries.count == 1)
        #expect(!model.entries.contains { $0.key == archivedKey })
        // …gone from the index on disk…
        let indexContents = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(!indexContents.contains("a@example.com"))
        #expect(indexContents.contains("b@example.com"))
        // …and gone from the keychain: no orphan secret survives the removal (AC5.11).
        #expect(await store.archivedToken(for: archivedKey) == nil)
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // The literal contract of AC5.11: `security -s <service> -a "claude:{email}"`. Spelled
            // out rather than reused from the implementation, so a change to the naming scheme
            // fails here instead of silently agreeing with itself.
            kSecAttrAccount as String: "claude:a@example.com",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) != errSecSuccess)
        #endif
    }

    /// AC5.12 / I1: the roster is an actor, so the Settings pane can only reach it through `await`.
    /// The view model funnels every call into a `Task`, and the view body holds no call at all.
    @Test
    nonisolated func settingsMutatesTheRosterOnlyFromATask() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/ClaudeBar/Settings/AccountsSettingsSection.swift"),
            encoding: .utf8)
        // Every `await` on the port lives inside the view model, never in a `body`.
        let body = source.components(separatedBy: "var body: some View").dropFirst().joined()
        #expect(!body.contains("await"))
        #expect(source.contains("Task { await self.removeAndAwait(key) }"))
    }

    // MARK: - AC6: localization parity

    /// Every string the switcher and the accounts pane show exists in **both** tables — a key present
    /// in one language only would silently fall back to English for half the users.
    @Test
    nonisolated func newSwitcherKeysAreLocalizedInBothTables() throws {
        func keys(_ language: String) throws -> Set<String> {
            let url = Self.repositoryRoot.appendingPathComponent(
                "Sources/ClaudeBar/Resources/\(language).lproj/Localizable.strings")
            let source = try String(contentsOf: url, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #"^"([^"]+)"\s*="#)
            var found: Set<String> = []
            for line in source.components(separatedBy: .newlines) {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let keyRange = Range(match.range(at: 1), in: line)
                else { continue }
                found.insert(String(line[keyRange]))
            }
            return found
        }

        let english = try keys("en")
        let portuguese = try keys("pt-BR")

        let introduced: Set<String> = [
            "switcher.title",
            "switcher.back",
            "switcher.open_accessibility",
            "switcher.provider.codex",
            "switcher.status.live",
            "switcher.status.archived",
            "switcher.status.expired",
            "switcher.status.unavailable",
            "settings.accounts.section",
            "settings.accounts.readonly_note",
            "settings.accounts.empty",
            "settings.accounts.remove",
            "settings.accounts.badge.live",
            "settings.accounts.badge.archived",
            "settings.accounts.badge.expired",
        ]
        #expect(introduced.isSubset(of: english))
        #expect(introduced.isSubset(of: portuguese))
        // And the tables as a whole stay in lockstep.
        #expect(english.symmetricDifference(portuguese).isEmpty)
    }

    /// The two tables actually translate — the expired label is the one users must understand, and it
    /// must not be the English string leaking into a Portuguese session.
    @Test
    nonisolated func expiredLabelTranslates() {
        func label(_ language: String) -> String {
            ClaudeBarLocalization.$languageOverride.withValue(language) {
                resetClaudeBarLocalizationCache()
                defer { resetClaudeBarLocalizationCache() }
                return AccountSwitcherItem.statusLabel(for: .archivedExpired)
            }
        }
        let english = label("en")
        let portuguese = label("pt-BR")
        #expect(english != portuguese)
        #expect(portuguese.contains("expirada"))
        #expect(english.contains("expired"))
    }
}

/// Thread-safe fetch counter.
private actor FetchCounter {
    private(set) var value = 0
    func increment() { self.value += 1 }
}

/// Swallows notifications so a test cycle never posts to the real notification centre.
private final class SilentPoster: QuotaNotificationPosting {
    func post(idPrefix: String, title: String, body: String, soundEnabled: Bool) {}
}
