import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for the EXB-1.5 `SettingsStore`: defaults, persistence/restore, debounced writes, and the
/// callbacks that drive the timer, the status item, and the off-MainActor keychain prompt policy.
@MainActor
struct SettingsStoreTests {
    /// A fresh, isolated `UserDefaults` per test so nothing leaks across runs or into the app domain.
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "exb.settings.\(UUID().uuidString)")!
    }

    // MARK: - Defaults (AC3–AC5)

    @Test
    func documentedDefaults() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.refreshCadence == .min5)
        #expect(store.launchAtLogin == false)
        #expect(store.notificationsEnabled == true)
        #expect(store.sessionThresholds == [50, 20])
        #expect(store.weeklyThresholds == [50, 20])
        #expect(store.notificationSound == false)
        #expect(store.costEnabled == true)
        #expect(store.costDays == 30)
        #expect(store.source == nil)
        #expect(store.keychainPromptPolicy == .onUserAction)
        // CLI reader is the prompt-free default (eliminates the recurring keychain dialog).
        #expect(store.useSecurityCLIReader == true)
        #expect(store.webExtrasEnabled == false)
        #expect(store.claudeBinaryPath == nil)
        #expect(store.displayMode == .meterIcon)
        #expect(store.showUsed == true)
        #expect(store.showAbsoluteReset == true)
        #expect(store.showWarningMarkers == true)
        #expect(store.workdayMarkers == .off)
    }

    // MARK: - Persistence round-trip (AC8 — survive restart)

    @Test
    func settingsSurviveRestart() {
        let suite = defaults()

        let first = SettingsStore(defaults: suite)
        first.refreshCadence = .min15
        first.notificationsEnabled = false
        first.sessionThresholds = [60, 30]
        first.weeklyThresholds = [40]
        first.costEnabled = false
        first.costDays = 90
        first.source = .oauth
        first.keychainPromptPolicy = .always
        first.useSecurityCLIReader = false // persist the non-default (CLI reader opt-out)
        first.claudeBinaryPath = "/opt/claude"
        first.displayMode = .brandIconPercent
        first.showUsed = false
        first.workdayMarkers = .fiveDay
        // Force a synchronous flush rather than waiting on the 500 ms debounce.
        first.flush()

        // A new store reading the same suite restores every value.
        let second = SettingsStore(defaults: suite)
        #expect(second.refreshCadence == .min15)
        #expect(second.notificationsEnabled == false)
        #expect(second.sessionThresholds == [60, 30])
        #expect(second.weeklyThresholds == [40])
        #expect(second.costEnabled == false)
        #expect(second.costDays == 90)
        #expect(second.source == .oauth)
        #expect(second.keychainPromptPolicy == .always)
        #expect(second.useSecurityCLIReader == false)
        #expect(second.claudeBinaryPath == "/opt/claude")
        #expect(second.displayMode == .brandIconPercent)
        #expect(second.showUsed == false)
        #expect(second.workdayMarkers == .fiveDay)
    }

    /// Clearing the optional binary path back to `nil` is persisted as a removal, not an empty
    /// string ghost.
    @Test
    func clearingOptionalPersistsAsNil() {
        let suite = defaults()
        let first = SettingsStore(defaults: suite)
        first.claudeBinaryPath = "/opt/claude"
        first.flush()
        first.claudeBinaryPath = nil
        first.flush()

        let second = SettingsStore(defaults: suite)
        #expect(second.claudeBinaryPath == nil)
    }

    // MARK: - Debounced save (AC8)

    @Test
    func debouncedSaveCoalescesRapidMutations() async {
        let suite = defaults()
        let store = SettingsStore(defaults: suite)

        // A burst of mutations within one debounce window persists only the final value.
        store.costDays = 10
        store.costDays = 20
        store.costDays = 45

        // Before the 500 ms window elapses, nothing is on disk yet.
        #expect(suite.object(forKey: "settings.costDays") == nil)

        // After the window, the last value is written exactly once.
        try? await Task.sleep(for: .milliseconds(650))
        #expect(suite.integer(forKey: "settings.costDays") == 45)
    }

    // MARK: - Callbacks

    @Test
    func cadenceChangeFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        var fired: [RefreshCadence] = []
        store.onRefreshCadenceChange = { fired.append($0) }

        store.refreshCadence = .min1
        store.refreshCadence = .min1 // no-op, must not fire again
        store.refreshCadence = .manual

        #expect(fired == [.min1, .manual])
    }

    @Test
    func displayModeChangeFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        var count = 0
        store.onDisplayModeChange = { count += 1 }

        store.displayMode = .brandIconPercent
        store.displayMode = .brandIconPercent // no-op
        store.displayMode = .meterIcon

        #expect(count == 2)
    }

    @Test
    func keychainPolicyChangeFiresCallbackWithMappedPolicy() {
        let store = SettingsStore(defaults: defaults())
        var policies: [PromptPolicy] = []
        store.onKeychainPolicyChange = { policies.append($0) }

        store.keychainPromptPolicy = .never
        store.keychainPromptPolicy = .always
        store.keychainPromptPolicy = .always // no-op

        #expect(policies == [.never, .always])
    }

    // MARK: - Policy mapping (AC11)

    @Test
    func keychainPolicyMapsToCorePolicy() {
        #expect(KeychainPromptPolicy.never.corePolicy == .never)
        #expect(KeychainPromptPolicy.onUserAction.corePolicy == .onUserAction)
        #expect(KeychainPromptPolicy.always.corePolicy == .always)

        let store = SettingsStore(defaults: defaults())
        store.keychainPromptPolicy = .always
        #expect(store.corePromptPolicy == .always)
    }
}
