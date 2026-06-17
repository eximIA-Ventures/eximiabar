import AppKit
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
        case .manual: L("settings.cadence.manual")
        case .min1: L("settings.cadence.min1")
        case .min2: L("settings.cadence.min2")
        case .min5: L("settings.cadence.min5")
        case .min15: L("settings.cadence.min15")
        case .min30: L("settings.cadence.min30")
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
        case .never: L("settings.claude.policy.never")
        case .onUserAction: L("settings.claude.policy.on_user_action")
        case .always: L("settings.claude.policy.always")
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

/// App language preference (EXB-2.2 AC3/AC4). Persisted as its raw string in `UserDefaults` under
/// `"appLanguage"`: `""` (System), `"en"`, or `"pt-BR"`. `system` follows the macOS language.
enum AppLanguage: String, Sendable, Equatable, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    /// Localized display label for the picker (AC3). Resolved through `L(…)` so the option names
    /// themselves adapt to the active language.
    var label: String {
        switch self {
        case .system: L("settings.general.language.system")
        case .english: L("settings.general.language.english")
        case .portuguese: L("settings.general.language.portuguese")
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
        case .off: L("settings.display.workday.off")
        case .fourDay: L("settings.display.workday.four_day")
        case .fiveDay: L("settings.display.workday.five_day")
        case .sevenDay: L("settings.display.workday.seven_day")
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

/// Window translucency level (EXB-3.1 AC3). Persisted as its raw string in `UserDefaults`.
///
/// Maps each level onto the `NSVisualEffectView.Material` the popover and Settings window apply at
/// runtime — the higher the frost, the more the desktop content behind the window shows through:
/// - `.opaque` → `.underWindowBackground` (the least-translucent vibrant material; still vibrant, but
///   reads as a near-solid surface, the "off switch" for users who dislike blur — there is no truly
///   opaque `NSVisualEffectView.Material`, so this is the closest native equivalent).
/// - `.standard` → `.popover` (medium, adaptive frost — the legacy EXB-2.1 default).
/// - `.frosted` → `.hudWindow` (strong frost with a darkened backing — the new v1.2.0 default).
enum TransparencyLevel: String, Sendable, Equatable, CaseIterable, Identifiable, Codable {
    case opaque
    case standard
    case frosted

    var id: String { rawValue }

    /// The AppKit material this level maps to (AC6 — unit-tested mapping).
    var material: NSVisualEffectView.Material {
        switch self {
        case .opaque: .underWindowBackground
        case .standard: .popover
        case .frosted: .hudWindow
        }
    }

    /// The macOS 26 Liquid Glass style this level maps to (EXB-3.5 AC4 — unit-tested mapping), or
    /// `nil` for `.opaque`: there is no "glass" for the off switch, so the macOS 26 path hides the
    /// glass view and falls back to a solid window background (AC4). `.standard → .regular` (standard
    /// glass), `.frosted → .clear` (the maximally-translucent Liquid Glass). Mirrors the `material`
    /// mapping above so both OS paths express the same three-level intent.
    @available(macOS 26.0, *)
    var glassStyle: NSGlassEffectView.Style? {
        switch self {
        case .opaque: nil
        case .standard: .regular
        case .frosted: .clear
        }
    }

    /// Localized picker label (AC3/AC5).
    var label: String {
        switch self {
        case .opaque: L("appearance.transparency.opaque")
        case .standard: L("appearance.transparency.standard")
        case .frosted: L("appearance.transparency.frosted")
        }
    }
}

/// App appearance override (EXB-3.1 AC4). Persisted as its raw string in `UserDefaults`.
///
/// Drives `NSApp.appearance`: `.system` clears the override (follow macOS), `.light`/`.dark` force a
/// fixed appearance. Applied immediately on change and re-applied at launch from the persisted value.
enum ThemeOverride: String, Sendable, Equatable, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The `NSAppearance` to install on `NSApp`, or `nil` to follow the system (AC4).
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Localized picker label (AC4/AC5).
    var label: String {
        switch self {
        case .system: L("appearance.theme.system")
        case .light: L("appearance.theme.light")
        case .dark: L("appearance.theme.dark")
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

    /// App language (EXB-2.2 AC3/AC4). Persisted under `UserDefaults` key `"appLanguage"` as the raw
    /// string (`""`/`"en"`/`"pt-BR"`). Default `.system`.
    ///
    /// **Switch mechanism — Option A (in-process, no relaunch):** changing this resets the
    /// localization bundle cache (`resetClaudeBarLocalizationCache()`), `UserDefaults` already holds
    /// the new value that `L(…)` reads, and `onAppLanguageChange` lets the app force a UI repaint. Every
    /// SwiftUI body resolves its strings through `L(…)`; because this property is `@Observable`, the
    /// views that read it re-render immediately and pick up the new `.lproj` table. No `Process`
    /// relaunch and no confirmation dialog (the path AC6 describes for Option B) are used — see
    /// `Localization.swift` for the resolver.
    var appLanguage: AppLanguage = .system {
        didSet {
            guard appLanguage != oldValue else { return }
            // Persist eagerly so `L(…)` (which reads `UserDefaults` directly) sees the new value the
            // instant the cache is dropped, then drop the cache and notify the app to repaint.
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
            resetClaudeBarLocalizationCache()
            onAppLanguageChange?(appLanguage)
            scheduleSave()
        }
    }

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
    var costEnabled: Bool = true {
        didSet {
            guard costEnabled != oldValue else { return }
            onCostSettingsChange?(costEnabled, costDays)
            scheduleSave()
        }
    }

    /// How many days of cost history the scan covers, 1–365 (AC3). Default 30.
    var costDays: Int = 30 {
        didSet {
            guard costDays != oldValue else { return }
            onCostSettingsChange?(costEnabled, costDays)
            scheduleSave()
        }
    }

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

    /// When ON, layer (e) reads credentials via the trusted `/usr/bin/security` CLI first
    /// (prompt-free) and only falls back to the direct Security.framework call. This is the path
    /// that eliminates the recurring Allow/Deny keychain dialog, so it defaults **ON**.
    var useSecurityCLIReader: Bool = true {
        didSet {
            guard useSecurityCLIReader != oldValue else { return }
            onSecurityCLIReaderChange?(coreReadStrategy)
            scheduleSave()
        }
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

    // MARK: - Appearance (EXB-3.1 AC3/AC4)

    /// Window translucency level. Default `.frosted` (strong glass — the v1.2.0 default). Changing
    /// this re-applies the material to the live popover and Settings window via `onTransparencyChange`
    /// with no relaunch (AC3).
    var transparencyLevel: TransparencyLevel = .frosted {
        didSet {
            guard transparencyLevel != oldValue else { return }
            onTransparencyChange?(transparencyLevel)
            scheduleSave()
        }
    }

    /// App theme override. Default `.system` (follow macOS). Changing this re-applies `NSApp.appearance`
    /// via `onThemeChange` immediately, with no relaunch (AC4).
    var themeOverride: ThemeOverride = .system {
        didSet {
            guard themeOverride != oldValue else { return }
            onThemeChange?(themeOverride)
            scheduleSave()
        }
    }

    // MARK: - Callbacks

    /// Invoked when `appLanguage` changes so the app can force an immediate UI repaint (EXB-2.2 AC5,
    /// Option A in-process switch). The bundle cache is already reset by the `didSet`.
    var onAppLanguageChange: (@MainActor (AppLanguage) -> Void)?

    /// Invoked when `refreshCadence` changes so `AppState` can restart the timer (AC3).
    var onRefreshCadenceChange: (@MainActor (RefreshCadence) -> Void)?

    /// Invoked when `displayMode` changes so the status item can re-render immediately (AC5/T5).
    var onDisplayModeChange: (@MainActor () -> Void)?

    /// Invoked when `keychainPromptPolicy` changes so the off-MainActor policy holder stays in
    /// lock-step with the live setting (AC11). Carries the mapped Core policy.
    var onKeychainPolicyChange: (@MainActor (PromptPolicy) -> Void)?

    /// Invoked when `useSecurityCLIReader` changes so the off-MainActor read-strategy holder stays
    /// in lock-step with the live setting. Carries the mapped Core strategy.
    var onSecurityCLIReaderChange: (@MainActor (KeychainReadStrategy) -> Void)?

    /// Invoked when `claudeBinaryPath` changes so the off-MainActor CLI binary holder stays in
    /// lock-step with the live setting (EXB-1.6). Carries the optional override path.
    var onClaudeBinaryChange: (@MainActor (String?) -> Void)?

    /// Invoked when `costEnabled` or `costDays` changes so the off-MainActor cost-settings holder
    /// stays in lock-step with the live setting (EXB-1.7 AC9/AC11). Carries `(enabled, days)`.
    var onCostSettingsChange: (@MainActor (Bool, Int) -> Void)?

    /// Invoked when `transparencyLevel` changes so the popover and Settings window re-apply their
    /// `NSVisualEffectView.material` live, without recreating the window (EXB-3.1 AC3).
    var onTransparencyChange: (@MainActor (TransparencyLevel) -> Void)?

    /// Invoked when `themeOverride` changes so `NSApp.appearance` is re-applied immediately
    /// (EXB-3.1 AC4).
    var onThemeChange: (@MainActor (ThemeOverride) -> Void)?

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

    /// Plain-value snapshot of the keychain read strategy for off-MainActor reads.
    /// `CredentialsStore` reads this through the provider closure on every fetch — no memoization.
    var coreReadStrategy: KeychainReadStrategy {
        useSecurityCLIReader ? .securityCLIPrimary : .securityFramework
    }

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
        /// EXB-2.2 AC4 — the stable, un-namespaced key the localization engine reads directly.
        static let appLanguage = "appLanguage"
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
        static let transparencyLevel = "settings.transparencyLevel"
        static let themeOverride = "settings.themeOverride"
    }

    /// Immutable, `Sendable` carrier of every persisted value so the write can hop off-main (AC8).
    private struct PersistedSnapshot: Sendable {
        let appLanguage: String
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
        let transparencyLevel: String
        let themeOverride: String

        func write(to defaults: UserDefaults) {
            defaults.set(appLanguage, forKey: Key.appLanguage)
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
            defaults.set(transparencyLevel, forKey: Key.transparencyLevel)
            defaults.set(themeOverride, forKey: Key.themeOverride)
        }
    }

    private func persistedSnapshot() -> PersistedSnapshot {
        PersistedSnapshot(
            appLanguage: appLanguage.rawValue,
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
            workdayMarkers: workdayMarkers.rawValue,
            transparencyLevel: transparencyLevel.rawValue,
            themeOverride: themeOverride.rawValue)
    }

    /// Hydrate from `UserDefaults`. Missing keys keep the code default (AC8 — settings survive
    /// restart; a fresh install starts at the documented defaults). The caller owns `isLoading`.
    private func load() {
        if let raw = defaults.string(forKey: Key.appLanguage),
           let value = AppLanguage(rawValue: raw) {
            appLanguage = value
        }
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
        if let raw = defaults.string(forKey: Key.transparencyLevel),
           let value = TransparencyLevel(rawValue: raw) {
            transparencyLevel = value
        }
        if let raw = defaults.string(forKey: Key.themeOverride),
           let value = ThemeOverride(rawValue: raw) {
            themeOverride = value
        }
    }
}
