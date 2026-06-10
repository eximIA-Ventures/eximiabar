import ClaudeBarCore
import Foundation
import Observation

/// How the status item presents usage in the menu bar.
enum DisplayMode: Sendable, Equatable {
    /// F1 — the two-bar crab meter icon.
    case meterIcon
    /// F2 — the Claude brand SVG plus a percentage / pace string.
    case brandIconPercent
}

/// Refresh timer cadence (AC3). Drives the `AppState` refresh loop.
enum RefreshCadence: String, Sendable, Equatable, CaseIterable, Identifiable {
    case manual
    case min1
    case min2
    case min5
    case min15
    case min30

    var id: String { rawValue }

    /// Interval in seconds. `manual` is `0` — the loop then idles until a user/startup trigger.
    var intervalSeconds: Double {
        switch self {
        case .manual: 0
        case .min1: 60
        case .min2: 120
        case .min5: 300
        case .min15: 900
        case .min30: 1800
        }
    }

    /// Picker label (AC3).
    var label: String {
        switch self {
        case .manual: "Manual"
        case .min1: "Every 1 min"
        case .min2: "Every 2 min"
        case .min5: "Every 5 min"
        case .min15: "Every 15 min"
        case .min30: "Every 30 min"
        }
    }
}

/// Keychain prompt policy (AC4 / AC11). Persisted as its raw string in `UserDefaults`.
///
/// Maps onto the Core `PromptPolicy` that `CredentialsStore` enforces at read time:
/// `never` → never prompt, `onUserAction` → prompt only on a user-initiated refresh,
/// `always` → prompt in any phase.
enum KeychainPromptPolicy: String, Sendable, Equatable, CaseIterable, Identifiable {
    case never
    case onUserAction
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .onUserAction: "Only on user action"
        case .always: "Always"
        }
    }

    /// The Core policy this maps to (AC11).
    var corePolicy: PromptPolicy {
        switch self {
        case .never: .never
        case .onUserAction: .onUserAction
        case .always: .always
        }
    }
}

/// Workday markers shown on the weekly bar (AC5).
enum WorkdayMarkers: String, Sendable, Equatable, CaseIterable, Identifiable {
    case off
    case fourDay
    case fiveDay
    case sevenDay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .fourDay: "4 days"
        case .fiveDay: "5 days"
        case .sevenDay: "7 days"
        }
    }

    /// Number of workdays, or `nil` when off.
    var days: Int? {
        switch self {
        case .off: nil
        case .fourDay: 4
        case .fiveDay: 5
        case .sevenDay: 7
        }
    }
}

/// Fully implemented settings store (AC8).
///
/// A `@MainActor @Observable` value holder that the UI binds to and `AppState`/`StatusItemController`
/// observe. Every mutation is persisted to `UserDefaults.standard` through a single debounced
/// (500 ms) save task — no write touches disk on the hot path of a slider drag (AC8).
///
/// **Anti-freeze:** the store itself does no blocking I/O. `UserDefaults` writes are coalesced and
/// the only persisted values are plain `Sendable` scalars / raw strings. Reads in
/// `CredentialsStore` happen off-MainActor via the `keychainPromptPolicy` snapshot the provider
/// threads through (AC11).
@MainActor
@Observable
final class SettingsStore {
    // MARK: - General (AC3)

    /// Refresh timer cadence. Default 5 minutes. Changing this restarts the `AppState` timer (AC3).
    var refreshCadence: RefreshCadence = .min5 {
        didSet {
            guard refreshCadence != oldValue else { return }
            onRefreshCadenceChange?(refreshCadence)
            scheduleSave()
        }
    }

    /// Launch-at-login preference. The view is responsible for calling
    /// `LaunchAtLoginManager.set(enabled:)`; this is the persisted mirror of that state.
    var launchAtLogin: Bool = false { didSet { scheduleSaveIfChanged(launchAtLogin, oldValue) } }

    /// Master switch for quota notifications. Default on.
    var notificationsEnabled: Bool = true {
        didSet { scheduleSaveIfChanged(notificationsEnabled, oldValue) }
    }

    /// Session-window warning thresholds (percent remaining). Default `[50, 20]` (AC3).
    var sessionThresholds: [Int] = [50, 20] {
        didSet { scheduleSaveIfChanged(sessionThresholds, oldValue) }
    }

    /// Weekly-window warning thresholds (percent remaining). Default `[50, 20]` (AC3).
    var weeklyThresholds: [Int] = [50, 20] {
        didSet { scheduleSaveIfChanged(weeklyThresholds, oldValue) }
    }

    /// Whether a sound plays on a notification (AC10). Default off.
    var notificationSound: Bool = false {
        didSet { scheduleSaveIfChanged(notificationSound, oldValue) }
    }

    /// Whether the local cost scan runs (AC3). Default on.
    var costEnabled: Bool = true { didSet { scheduleSaveIfChanged(costEnabled, oldValue) } }

    /// How many days of cost history the scan covers, 1–365 (AC3). Default 30.
    var costDays: Int = 30 { didSet { scheduleSaveIfChanged(costDays, oldValue) } }

    // MARK: - Claude (AC4)

    /// Forced credential source, or `nil` for auto-selection (AC4).
    var source: DataSource? { didSet { scheduleSaveIfChanged(source, oldValue) } }

    /// When a keychain dialog may be raised (AC4 / AC11). Default `.onUserAction`.
    var keychainPromptPolicy: KeychainPromptPolicy = .onUserAction {
        didSet {
            guard keychainPromptPolicy != oldValue else { return }
            onKeychainPolicyChange?(keychainPromptPolicy.corePolicy)
            scheduleSave()
        }
    }

    /// When ON, reads credentials via `/usr/bin/security` CLI instead of the direct
    /// Security.framework call to avoid keychain prompts (AC4). Default off.
    var useSecurityCLIReader: Bool = false {
        didSet { scheduleSaveIfChanged(useSecurityCLIReader, oldValue) }
    }

    /// Developer option — extra web fetch on top of OAuth (AC4). Default off; stubbed in P0/P1.
    var webExtrasEnabled: Bool = false {
        didSet { scheduleSaveIfChanged(webExtrasEnabled, oldValue) }
    }

    /// Optional override for the `claude` binary path used for CLI/debug (AC4).
    var claudeBinaryPath: String? {
        didSet {
            guard claudeBinaryPath != oldValue else { return }
            onClaudeBinaryChange?(claudeBinaryPath)
            scheduleSave()
        }
    }

    // MARK: - Display (AC5)

    /// Active status-item display mode. Default the meter icon (F1).
    var displayMode: DisplayMode = .meterIcon {
        didSet {
            guard displayMode != oldValue else { return }
            onDisplayModeChange?()
            scheduleSave()
        }
    }

    /// Show consumed (`true`) vs remaining (`false`) on the bars (AC5). Default consumed.
    var showUsed: Bool = true { didSet { scheduleSaveIfChanged(showUsed, oldValue) } }

    /// Show an absolute reset clock (`true`) vs a countdown (`false`) (AC5). Default absolute.
    var showAbsoluteReset: Bool = true {
        didSet { scheduleSaveIfChanged(showAbsoluteReset, oldValue) }
    }

    /// Show threshold dashes on the bars (AC5). Default on.
    var showWarningMarkers: Bool = true {
        didSet { scheduleSaveIfChanged(showWarningMarkers, oldValue) }
    }

    /// Workday markers on the weekly bar (AC5). Default off.
    var workdayMarkers: WorkdayMarkers = .off {
        didSet { scheduleSaveIfChanged(workdayMarkers, oldValue) }
    }

    // MARK: - Callbacks

    /// Invoked when `refreshCadence` changes so `AppState` can restart the timer (AC3).
    var onRefreshCadenceChange: (@MainActor (RefreshCadence) -> Void)?

    /// Invoked when `displayMode` changes so the status item can re-render immediately (AC5/T5).
    var onDisplayModeChange: (@MainActor () -> Void)?

    /// Invoked when `keychainPromptPolicy` changes so the off-MainActor policy holder stays in
    /// lock-step with the live setting (AC11). Carries the mapped Core policy.
    var onKeychainPolicyChange: (@MainActor (PromptPolicy) -> Void)?

    /// Invoked when `claudeBinaryPath` changes so the off-MainActor CLI binary holder stays in
    /// lock-step with the live setting (EXB-1.6). Carries the optional override path.
    var onClaudeBinaryChange: (@MainActor (String?) -> Void)?

    // MARK: - Persistence (AC8)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Suppresses save scheduling while `load()` hydrates from disk.
    @ObservationIgnored private var isLoading = false

    init(
        defaults: UserDefaults = .standard,
        displayMode: DisplayMode = .meterIcon,
        refreshCadence: RefreshCadence = .min5)
    {
        self.defaults = defaults
        // Hydrate from persistence (AC8 — settings survive restart). Then apply any explicit,
        // non-default seed so the `displayMode:`/`refreshCadence:` test seam stays deterministic.
        // The shipping app constructs `SettingsStore()` with no seeds → pure load.
        isLoading = true
        load()
        if displayMode != .meterIcon { self.displayMode = displayMode }
        if refreshCadence != .min5 { self.refreshCadence = refreshCadence }
        isLoading = false
    }

    deinit {
        saveTask?.cancel()
    }

    // MARK: - Notifier bridge

    /// Snapshot the notification-relevant settings into the value type `QuotaNotifier` consumes.
    /// Session thresholds drive the notifier (the menu-bar icon tracks the session window).
    var notificationSettings: NotificationSettings {
        NotificationSettings(
            thresholds: sessionThresholds,
            soundEnabled: notificationSound,
            enabled: notificationsEnabled)
    }

    /// Plain-value snapshot of the keychain prompt policy for off-MainActor reads (AC11).
    /// `CredentialsStore` reads this through the provider closure on every fetch — no memoization.
    var corePromptPolicy: PromptPolicy { keychainPromptPolicy.corePolicy }

    // MARK: - Debounced save (AC8)

    private func scheduleSaveIfChanged<T: Equatable>(_ new: T, _ old: T) {
        guard new != old else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        let snapshot = persistedSnapshot()
        let defaults = self.defaults
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Off the hot path: write the coalesced snapshot. `UserDefaults` is thread-safe.
            await Task.detached(priority: .utility) {
                snapshot.write(to: defaults)
            }.value
        }
    }

    /// Force an immediate, synchronous flush (used at app termination so nothing is lost).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persistedSnapshot().write(to: defaults)
    }

    // MARK: - Keys

    private enum Key {
        static let refreshCadence = "settings.refreshCadence"
        static let launchAtLogin = "settings.launchAtLogin"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let sessionThresholds = "settings.sessionThresholds"
        static let weeklyThresholds = "settings.weeklyThresholds"
        static let notificationSound = "settings.notificationSound"
        static let costEnabled = "settings.costEnabled"
        static let costDays = "settings.costDays"
        static let source = "settings.source"
        static let keychainPromptPolicy = "settings.keychainPromptPolicy"
        static let useSecurityCLIReader = "settings.useSecurityCLIReader"
        static let webExtrasEnabled = "settings.webExtrasEnabled"
        static let claudeBinaryPath = "settings.claudeBinaryPath"
        static let displayMode = "settings.displayMode"
        static let showUsed = "settings.showUsed"
        static let showAbsoluteReset = "settings.showAbsoluteReset"
        static let showWarningMarkers = "settings.showWarningMarkers"
        static let workdayMarkers = "settings.workdayMarkers"
    }

    /// Immutable, `Sendable` carrier of every persisted value so the write can hop off-main (AC8).
    private struct PersistedSnapshot: Sendable {
        let refreshCadence: String
        let launchAtLogin: Bool
        let notificationsEnabled: Bool
        let sessionThresholds: [Int]
        let weeklyThresholds: [Int]
        let notificationSound: Bool
        let costEnabled: Bool
        let costDays: Int
        let source: String?
        let keychainPromptPolicy: String
        let useSecurityCLIReader: Bool
        let webExtrasEnabled: Bool
        let claudeBinaryPath: String?
        let displayModeIsBrand: Bool
        let showUsed: Bool
        let showAbsoluteReset: Bool
        let showWarningMarkers: Bool
        let workdayMarkers: String

        func write(to defaults: UserDefaults) {
            defaults.set(refreshCadence, forKey: Key.refreshCadence)
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
            defaults.set(sessionThresholds, forKey: Key.sessionThresholds)
            defaults.set(weeklyThresholds, forKey: Key.weeklyThresholds)
            defaults.set(notificationSound, forKey: Key.notificationSound)
            defaults.set(costEnabled, forKey: Key.costEnabled)
            defaults.set(costDays, forKey: Key.costDays)
            if let source { defaults.set(source, forKey: Key.source) }
            else { defaults.removeObject(forKey: Key.source) }
            defaults.set(keychainPromptPolicy, forKey: Key.keychainPromptPolicy)
            defaults.set(useSecurityCLIReader, forKey: Key.useSecurityCLIReader)
            defaults.set(webExtrasEnabled, forKey: Key.webExtrasEnabled)
            if let claudeBinaryPath { defaults.set(claudeBinaryPath, forKey: Key.claudeBinaryPath) }
            else { defaults.removeObject(forKey: Key.claudeBinaryPath) }
            defaults.set(displayModeIsBrand, forKey: Key.displayMode)
            defaults.set(showUsed, forKey: Key.showUsed)
            defaults.set(showAbsoluteReset, forKey: Key.showAbsoluteReset)
            defaults.set(showWarningMarkers, forKey: Key.showWarningMarkers)
            defaults.set(workdayMarkers, forKey: Key.workdayMarkers)
        }
    }

    private func persistedSnapshot() -> PersistedSnapshot {
        PersistedSnapshot(
            refreshCadence: refreshCadence.rawValue,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsEnabled,
            sessionThresholds: sessionThresholds,
            weeklyThresholds: weeklyThresholds,
            notificationSound: notificationSound,
            costEnabled: costEnabled,
            costDays: costDays,
            source: source?.rawValue,
            keychainPromptPolicy: keychainPromptPolicy.rawValue,
            useSecurityCLIReader: useSecurityCLIReader,
            webExtrasEnabled: webExtrasEnabled,
            claudeBinaryPath: claudeBinaryPath,
            displayModeIsBrand: displayMode == .brandIconPercent,
            showUsed: showUsed,
            showAbsoluteReset: showAbsoluteReset,
            showWarningMarkers: showWarningMarkers,
            workdayMarkers: workdayMarkers.rawValue)
    }

    /// Hydrate from `UserDefaults`. Missing keys keep the code default (AC8 — settings survive
    /// restart; a fresh install starts at the documented defaults). The caller owns `isLoading`.
    private func load() {
        if let raw = defaults.string(forKey: Key.refreshCadence),
           let value = RefreshCadence(rawValue: raw) {
            refreshCadence = value
        }
        if defaults.object(forKey: Key.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }
        if defaults.object(forKey: Key.notificationsEnabled) != nil {
            notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        }
        if let value = defaults.array(forKey: Key.sessionThresholds) as? [Int] {
            sessionThresholds = value
        }
        if let value = defaults.array(forKey: Key.weeklyThresholds) as? [Int] {
            weeklyThresholds = value
        }
        if defaults.object(forKey: Key.notificationSound) != nil {
            notificationSound = defaults.bool(forKey: Key.notificationSound)
        }
        if defaults.object(forKey: Key.costEnabled) != nil {
            costEnabled = defaults.bool(forKey: Key.costEnabled)
        }
        if defaults.object(forKey: Key.costDays) != nil {
            costDays = min(365, max(1, defaults.integer(forKey: Key.costDays)))
        }
        if let raw = defaults.string(forKey: Key.source) {
            source = DataSource(rawValue: raw)
        }
        if let raw = defaults.string(forKey: Key.keychainPromptPolicy),
           let value = KeychainPromptPolicy(rawValue: raw) {
            keychainPromptPolicy = value
        }
        if defaults.object(forKey: Key.useSecurityCLIReader) != nil {
            useSecurityCLIReader = defaults.bool(forKey: Key.useSecurityCLIReader)
        }
        if defaults.object(forKey: Key.webExtrasEnabled) != nil {
            webExtrasEnabled = defaults.bool(forKey: Key.webExtrasEnabled)
        }
        claudeBinaryPath = defaults.string(forKey: Key.claudeBinaryPath)
        if defaults.object(forKey: Key.displayMode) != nil {
            displayMode = defaults.bool(forKey: Key.displayMode) ? .brandIconPercent : .meterIcon
        }
        if defaults.object(forKey: Key.showUsed) != nil {
            showUsed = defaults.bool(forKey: Key.showUsed)
        }
        if defaults.object(forKey: Key.showAbsoluteReset) != nil {
            showAbsoluteReset = defaults.bool(forKey: Key.showAbsoluteReset)
        }
        if defaults.object(forKey: Key.showWarningMarkers) != nil {
            showWarningMarkers = defaults.bool(forKey: Key.showWarningMarkers)
        }
        if let raw = defaults.string(forKey: Key.workdayMarkers),
           let value = WorkdayMarkers(rawValue: raw) {
            workdayMarkers = value
        }
    }
}
