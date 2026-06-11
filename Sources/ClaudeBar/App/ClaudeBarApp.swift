import AppKit
import ClaudeBarCore
import os
import SwiftUI
import UserNotifications

/// Thread-safe holder for the current keychain prompt policy (EXB-1.5 AC11).
///
/// `CredentialsStore` reads the policy off-MainActor on every fetch via a `@Sendable` closure; the
/// MainActor `SettingsStore` writes it whenever the user changes the setting. An unfair lock keeps
/// the read path lock-light and Swift-6 `Sendable`-clean — no actor hop on the hot path.
private final class PromptPolicyHolder: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: PromptPolicy.onUserAction)

    func get() -> PromptPolicy { lock.withLock { $0 } }
    func set(_ policy: PromptPolicy) { lock.withLock { $0 = policy } }
}

/// Thread-safe holder for the configured `claude` binary path override (EXB-1.6).
///
/// The CLI fallback resolves the binary off-MainActor on every fetch: the holder stores the user's
/// optional Settings override; the resolver (`CLISession.resolveBinaryPath`) maps an override or the
/// default name `"claude"` to an executable, returning `nil` when none is on PATH (→ `cliNotFound`).
private final class ClaudeBinaryHolder: Sendable {
    private let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The user override, or `nil` to fall back to a PATH search for `"claude"`.
    func set(_ override: String?) { lock.withLock { $0 = override } }

    /// Resolves to an executable path, or `nil` when no `claude` binary can be found.
    func resolve() -> String? {
        let override = lock.withLock { $0 }
        return CLISession.resolveBinaryPath(override ?? "claude")
    }
}

/// Thread-safe holder for the live cost-scan settings (EXB-1.7).
///
/// The cost scan reads `costEnabled` / `costDays` off-MainActor on every fetch via a `@Sendable`
/// closure; the MainActor `SettingsStore` writes them whenever the user changes the setting. Same
/// lock-light pattern as the prompt-policy / binary holders — no actor hop on the fetch path.
private final class CostSettingsHolder: Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: LiveUsageProvider.CostSettings(enabled: true, days: 30))

    func get() -> LiveUsageProvider.CostSettings { lock.withLock { $0 } }
    func set(enabled: Bool, days: Int) {
        lock.withLock { $0 = LiveUsageProvider.CostSettings(enabled: enabled, days: days) }
    }
}

/// Application entry point.
///
/// exímIABar is an `LSUIElement` agent (no Dock icon, no app menu — see `Info.plist`). It uses the
/// SwiftUI `App` lifecycle purely as a host: there is no main window. All UI lives in the menu-bar
/// status item, created by the `AppDelegate` in `applicationDidFinishLaunching`.
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window: the app is a menu-bar agent. This empty `Settings` scene is an inert lifecycle
        // host — SwiftUI requires a non-empty `App` body, and it has no openable content. The real
        // settings window is driven imperatively by `SettingsWindowController` (EXB-1.5), opened from
        // the popover `Settings…` action row and the ⌘, key equivalent on the installed main menu.
        Settings {
            EmptyView()
        }
    }
}

/// Wires the live refresh loop (EXB-1.4) to the status item on launch.
///
/// Lifecycle (AC6 / AC11 / T6):
///  1. Request notification authorization once (fire-and-forget).
///  2. Launch the watchdog helper if present (no-op if absent — S6).
///  3. Kick the startup refresh (`.startup` phase) and start the repeating timer.
///  4. Observe `AppState.snapshot` and push every change to the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let launchManager = LaunchAtLoginManager()
    /// Shared policy source read by `CredentialsStore` off-MainActor (AC11).
    private let promptPolicyHolder = PromptPolicyHolder()
    /// Shared `claude` binary source read by the CLI fallback off-MainActor (EXB-1.6).
    private let claudeBinaryHolder = ClaudeBinaryHolder()
    /// Shared cost-scan settings source read by the cost scanner off-MainActor (EXB-1.7).
    private let costSettingsHolder = CostSettingsHolder()
    private lazy var provider = LiveUsageProvider(
        promptPolicyProvider: { [promptPolicyHolder] in promptPolicyHolder.get() },
        claudeBinaryProvider: { [claudeBinaryHolder] in claudeBinaryHolder.resolve() },
        costSettingsProvider: { [costSettingsHolder] in costSettingsHolder.get() })
    private let notificationPoster = SystemNotificationPoster()
    private lazy var appState = AppState(
        fetch: provider.makeFetch(),
        settingsStore: settings,
        notifier: QuotaNotifier(poster: notificationPoster))
    private var statusItemController: StatusItemController?
    private var panelController: UsagePanelController?
    private var settingsWindowController: SettingsWindowController?
    /// EXB-2.3: owns the local Swift Charts dashboard window.
    private var dashboardWindowController: DashboardWindowController?
    private var observationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: enforce the agent activation policy even if `Info.plist` is missed
        // (e.g. running the bare executable during development).
        NSApp.setActivationPolicy(.accessory)

        // AC11: request notification authorization once at launch — fire and forget.
        notificationPoster.requestAuthorizationOnStartup()

        // EXB-1.5: reconcile persisted launch-at-login with the real `SMAppService` state, and seed
        // the policy holder from the loaded settings (AC11).
        settings.launchAtLogin = launchManager.isEnabled
        promptPolicyHolder.set(settings.corePromptPolicy)
        // EXB-1.6: seed the off-MainActor CLI binary holder from the persisted override.
        claudeBinaryHolder.set(settings.claudeBinaryPath)
        // EXB-1.7: seed the off-MainActor cost-settings holder from the persisted settings.
        costSettingsHolder.set(enabled: settings.costEnabled, days: settings.costDays)

        // EXB-1.5: build the settings window controller (opened from the menu action / ⌘,).
        settingsWindowController = SettingsWindowController(
            settings: settings,
            launchManager: launchManager)

        // EXB-2.3: build the local dashboard window controller. It reads the same off-MainActor
        // cost-settings holder and shared `CostScanner` the menu-bar fetch uses, so opening the
        // dashboard reuses the already-computed aggregate and never triggers a rate-limit fetch (AC11).
        dashboardWindowController = DashboardWindowController(
            costSettingsProvider: { [costSettingsHolder] in costSettingsHolder.get() },
            openSettings: { [weak self] in self?.settingsWindowController?.open() })

        let controller = StatusItemController(settings: settings)
        statusItemController = controller

        // EXB-1.5 AC5/T5: re-render the status item the instant the display mode flips, and keep the
        // off-MainActor policy holder in lock-step with the live keychain-prompt-policy setting.
        settings.onDisplayModeChange = { [weak self] in
            guard let self else { return }
            self.statusItemController?.update(snapshot: self.appState.snapshot)
        }
        settings.onKeychainPolicyChange = { [promptPolicyHolder] policy in
            promptPolicyHolder.set(policy)
        }
        // EXB-2.2 AC5/AC7 (Option A): on a language switch, repaint the menu-bar status item and the
        // installed main menu immediately. The bundle cache was already reset inside the store's
        // `didSet`; the open Settings window re-renders via `SettingsRootView.id(appLanguage)` and the
        // popover rebuilds its card the next time it is opened. No relaunch.
        settings.onAppLanguageChange = { [weak self] _ in
            guard let self else { return }
            self.installSettingsShortcutMenu()
            self.statusItemController?.update(snapshot: self.appState.snapshot)
        }
        // EXB-1.6: keep the off-MainActor CLI binary holder in lock-step with the live setting.
        settings.onClaudeBinaryChange = { [claudeBinaryHolder] override in
            claudeBinaryHolder.set(override)
        }
        // EXB-1.7: keep the off-MainActor cost-settings holder in lock-step, and refresh so a toggle
        // takes effect immediately (cost section appears/disappears on the next snapshot).
        settings.onCostSettingsChange = { [weak self, costSettingsHolder] enabled, days in
            costSettingsHolder.set(enabled: enabled, days: days)
            self?.appState.triggerRefresh(.userInitiated)
        }

        // EXB-1.3: build the popover (NSPanel) and wire its actions. The card reads the live
        // snapshot through the provider closure; opening it triggers a user-initiated refresh (AC6).
        let panel = UsagePanelController(
            snapshotProvider: { [weak self] in self?.appState.snapshot },
            actions: makeCardActions())
        panelController = panel

        // Click hook — toggle the popover anchored to the status-item button (EXB-1.3 T7).
        controller.onClick = { [weak panel] button in
            panel?.toggle(near: button)
        }

        // AC12: launch the watchdog helper if it exists (no-op when S6 binary is absent).
        appState.launchWatchdogIfPresent()

        // Render the initial (empty) state, then start observing.
        controller.update(snapshot: appState.snapshot)
        startObserving(controller: controller)

        // AC1: install a minimal main menu so ⌘, routes to the settings window even though the app
        // is an LSUIElement agent with no visible app menu.
        installSettingsShortcutMenu()

        // AC6a + AC3: startup refresh, then start the repeating timer.
        appState.triggerRefresh(.startup)
        appState.startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationTask?.cancel()
        appState.stopRefreshTimer()
        // AC8: persist any in-flight settings change synchronously before exit.
        settings.flush()
    }

    /// Open the settings window — target of the ⌘, menu item (AC1).
    @objc
    private func openSettingsFromMenu() {
        settingsWindowController?.open()
    }

    /// Build a minimal main menu providing the standard ⌘, "Settings…" shortcut (AC1). Without a
    /// menu, an LSUIElement agent never receives the key equivalent.
    private func installSettingsShortcutMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: L("popover.settings"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        NSApp.mainMenu = mainMenu
    }

    /// Build the action set the popover card triggers (AC17). Refresh routes to the user-initiated
    /// path (AC6); the link rows open external URLs; settings opens the SwiftUI `Settings` scene
    /// (the real panes land in EXB-1.5).
    private func makeCardActions() -> UsageCardActions {
        UsageCardActions(
            refresh: { [weak self] in
                self?.appState.triggerRefresh(.userInitiated)
            },
            openLocalDashboard: { [weak self] in
                // EXB-2.3: open the local Swift Charts dashboard window.
                self?.dashboardWindowController?.open()
            },
            openUsageDashboard: {
                Self.open("https://claude.ai/settings/usage")
            },
            openStatusPage: {
                Self.open("https://status.claude.com")
            },
            openSettings: { [weak self] in
                // EXB-1.5: open the real four-pane settings window (AC10 activation-policy dance is
                // handled inside the controller).
                self?.settingsWindowController?.open()
            },
            openRelogin: {
                Self.open("https://claude.ai")
            },
            quit: {
                NSApp.terminate(nil)
            })
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startObserving(controller: StatusItemController) {
        observationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                // Suspend until `snapshot` changes, then re-render. Each iteration re-registers via
                // `withObservationTracking` (one observable property → one re-render, AC2).
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.appState.snapshot
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                controller.update(snapshot: self.appState.snapshot)
            }
        }
    }
}
