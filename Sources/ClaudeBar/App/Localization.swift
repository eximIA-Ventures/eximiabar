import Foundation

/// In-process localization engine (EXB-2.2 — **Option A**).
///
/// `L("key")` resolves a string from the `.lproj` bundle for the currently-selected language and
/// re-resolves transparently the moment the language changes. Because every user-visible SwiftUI
/// `body` calls `L(…)`, and the selected language is read from the `@Observable` `SettingsStore`,
/// flipping `appLanguage` re-renders the whole UI **without a relaunch** (AC5 / AC7). No `Bundle`
/// subclassing or `object_setClass` swizzling is needed: the lookup simply targets a different
/// `.lproj` bundle resolved from the package resource bundle.
///
/// Adapted from `_reference_codexbar/Sources/CodexBar/Localization.swift` (proven against this exact
/// SwiftPM `.app` layout): renamed Codex→Claude, the catalog trimmed to the three languages this app
/// ships (System / English / Português Brasil), and the `UsageFormatter` provider hooks dropped
/// (exímIABar formats inline via `PopoverFormatter`, not a Core formatter).
///
/// **Anti-freeze (EPIC-EXB):** the resolved bundles never change unless the language changes, so they
/// are cached behind a lock with the disk lookup performed *outside* the critical section. `L(…)` is
/// pure and `nonisolated` — safe to call from any view body without an actor hop or blocking I/O on
/// the hot path.
enum ClaudeBarLocalization {
    /// Test seam: a `@TaskLocal` override forces a language for the duration of a test block.
    @TaskLocal static var languageOverride: String?
}

/// The `appLanguage` value the app started this process with — used to detect, in test processes,
/// whether a test mutated the preference (and should therefore honour it) versus the ambient value
/// (which must resolve to the deterministic English base so string-comparing tests stay stable).
private let standardAppLanguageAtProcessStart = UserDefaults.standard.string(forKey: "appLanguage")

private let isRunningTestsProcess: Bool = {
    let env = ProcessInfo.processInfo.environment
    if env["XCTestConfigurationFilePath"] != nil { return true }
    if env["SWIFT_TESTING"] != nil { return true }
    if env["TESTING_LIBRARY_VERSION"] != nil { return true }
    return NSClassFromString("XCTestCase") != nil
}()

/// The raw language code currently in effect: `""` = System, `"en"`, or `"pt-BR"`.
private func resolvedAppLanguage() -> String {
    if let override = ClaudeBarLocalization.languageOverride {
        return override
    }
    if isRunningTestsProcess {
        // Tests run against the English base unless a test explicitly set `appLanguage`. This keeps
        // every existing string-comparing test (UsagePaceText, MenuBarDisplayText, …) deterministic
        // regardless of the host machine's locale.
        let current = UserDefaults.standard.string(forKey: "appLanguage")
        return current == standardAppLanguageAtProcessStart ? "en" : (current ?? "")
    }
    return UserDefaults.standard.string(forKey: "appLanguage") ?? ""
}

// MARK: - Bundle resolution (cached)

/// Caches the resolved resource + localized bundles. `.lproj`/`Bundle(path:)` lookups hit the
/// filesystem; the resolved bundles only change when the language changes, so they are memoized
/// behind a lock with the compute performed outside the critical section (no re-entrant deadlock).
private enum LocalizationBundleCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var resourceBundle: Bundle?
    private nonisolated(unsafe) static var cachedLanguage: String?
    private nonisolated(unsafe) static var cachedLocalizedBundle: Bundle?

    static func defaultResourceBundle(_ compute: () -> Bundle) -> Bundle {
        self.lock.lock()
        if let resourceBundle {
            self.lock.unlock()
            return resourceBundle
        }
        self.lock.unlock()
        let computed = compute()
        self.lock.lock()
        self.resourceBundle = computed
        self.lock.unlock()
        return computed
    }

    static func localizedBundle(forLanguage language: String, _ compute: () -> Bundle) -> Bundle {
        self.lock.lock()
        if self.cachedLanguage == language, let cachedLocalizedBundle {
            let hit = cachedLocalizedBundle
            self.lock.unlock()
            return hit
        }
        self.lock.unlock()
        let computed = compute()
        self.lock.lock()
        self.cachedLanguage = language
        self.cachedLocalizedBundle = computed
        self.lock.unlock()
        return computed
    }

    static func reset() {
        self.lock.lock()
        self.resourceBundle = nil
        self.cachedLanguage = nil
        self.cachedLocalizedBundle = nil
        self.lock.unlock()
    }
}

/// The package resource bundle that carries the `.lproj` folders.
///
/// In the built `.app` the SwiftPM resource bundle is `ClaudeBar_ClaudeBar.bundle` inside
/// `Contents/Resources/`; outside an `.app` (tests / `swift run`) `Bundle.module` is the resource
/// bundle directly. AC2/AC7: this is where `.copy("Resources/en.lproj")` lands the tables.
private func claudeBarResourceBundle() -> Bundle {
    LocalizationBundleCache.defaultResourceBundle {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        let bundleName = "ClaudeBar_ClaudeBar"
        if let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
           let bundle = Bundle(url: url)
        {
            return bundle
        }
        if let resourceURL = Bundle.main.resourceURL?.absoluteURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle"))
        {
            return bundle
        }
        return Bundle.module
    }
}

private func localizedBundle() -> Bundle {
    let language = resolvedAppLanguage()
    return LocalizationBundleCache.localizedBundle(forLanguage: language) {
        resolveLocalizedBundle(forLanguage: language)
    }
}

private func resolveLocalizedBundle(forLanguage language: String) -> Bundle {
    let resourceBundle = claudeBarResourceBundle()
    if !language.isEmpty {
        if let bundle = lprojBundle(named: language, in: resourceBundle) {
            return bundle
        }
    } else {
        // System mode: follow macOS language preferences, falling back to en below.
        if let preferred = resourceBundle.preferredLocalizations.first,
           let bundle = lprojBundle(named: preferred, in: resourceBundle)
        {
            return bundle
        }
    }
    if let bundle = lprojBundle(named: "en", in: resourceBundle) {
        return bundle
    }
    return resourceBundle
}

private func lprojBundle(named language: String, in resourceBundle: Bundle) -> Bundle? {
    for candidate in [language, language.lowercased()] where !candidate.isEmpty {
        if let path = resourceBundle.path(forResource: candidate, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    }
    return nil
}

// MARK: - Public API

/// Localize `key`, falling back to the English table and then the key itself if missing.
nonisolated func L(_ key: String) -> String {
    let resourceBundle = claudeBarResourceBundle()
    let bundle = localizedBundle()
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    if value != key, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
    }
    // Missing in the active table → try the English base before surfacing the raw key.
    if bundle.bundleURL.lastPathComponent != "en.lproj",
       let englishBundle = lprojBundle(named: "en", in: resourceBundle)
    {
        let fallback = englishBundle.localizedString(forKey: key, value: nil, table: nil)
        if fallback != key, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
    }
    return key
}

/// Localize `key` and substitute positional `printf` arguments (e.g. `%@`, `%d`, `%1$@`).
nonisolated func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// A signature that changes whenever the resolved language changes. SwiftUI views read this from the
/// `@Observable` settings so a language switch invalidates and re-renders their bodies (AC7).
nonisolated func claudeBarLocalizationSignature() -> String {
    resolvedAppLanguage()
}

/// Drop the cached bundles so the next `L(…)` re-resolves for the freshly-selected language. Called
/// by `SettingsStore` whenever `appLanguage` changes (AC5 — immediate in-process switch).
nonisolated func resetClaudeBarLocalizationCache() {
    LocalizationBundleCache.reset()
}
