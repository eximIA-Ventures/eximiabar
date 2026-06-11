import Foundation
import Testing
@testable import ClaudeBar

/// Tests the EXB-2.2 localization engine: that both `.lproj` tables ship and resolve (AC2), that the
/// `<screen>.<element>` keyed strings translate (AC8), and that the in-process language override
/// (Option A — AC5/AC7) flips the resolved table without any relaunch.
///
/// Every test wraps its body in `ClaudeBarLocalization.$languageOverride.withValue(…)`, the `@TaskLocal`
/// test seam, and resets the bundle cache around it so the language switch is observed deterministically
/// regardless of the host's `appLanguage` default or run order.
struct LocalizationTests {
    private func withLanguage<T>(_ language: String?, _ body: () -> T) -> T {
        ClaudeBarLocalization.$languageOverride.withValue(language) {
            resetClaudeBarLocalizationCache()
            defer { resetClaudeBarLocalizationCache() }
            return body()
        }
    }

    /// AC2/AC8: the English base table resolves the exact literals the app shipped with — the same
    /// strings the existing string-comparing tests (UsagePaceText, PopoverFormatter, …) assert.
    @Test
    func englishBaseResolvesStableLiterals() {
        withLanguage("en") {
            #expect(L("popover.pace.on_pace") == "On pace")
            #expect(L("popover.pace.lasts_until_reset") == "Lasts until reset")
            #expect(L("popover.refresh_now") == "Refresh Now")
            #expect(L("popover.quit") == "Quit")
            #expect(L("settings.general.language") == "Language")
            #expect(L("settings.general.language.system") == "System")
            #expect(L("about.attribution") == "Based on CodexBar by Peter Steinberger (MIT).")
        }
    }

    /// AC2/AC3: the pt-BR table ships and translates. Proves the `.copy("Resources/pt-BR.lproj")`
    /// resource lands in the package bundle and the resolver finds it.
    @Test
    func portugueseTableResolves() {
        withLanguage("pt-BR") {
            #expect(L("popover.pace.on_pace") == "No ritmo")
            #expect(L("popover.refresh_now") == "Atualizar Agora")
            #expect(L("popover.quit") == "Encerrar")
            #expect(L("settings.general.language") == "Idioma")
            #expect(L("settings.general.language.system") == "Sistema")
            #expect(L("settings.tab.about") == "Sobre")
        }
    }

    /// AC5/AC7: switching the override re-resolves the table in-process — the same key yields a
    /// different string for `en` vs `pt-BR`, with no relaunch.
    @Test
    func switchingLanguageReResolvesInProcess() {
        let english = withLanguage("en") { L("notification.quota_exhausted", "Session") }
        let portuguese = withLanguage("pt-BR") { L("notification.quota_exhausted", "Sessão") }
        #expect(english == "Claude Session quota exhausted")
        #expect(portuguese == "Cota Sessão do Claude esgotada")
        #expect(english != portuguese)
    }

    /// Positional `printf` formatting survives localization (e.g. `%1$@ … %2$d`).
    @Test
    func formattedArgumentsSubstituteCorrectly() {
        withLanguage("en") {
            #expect(L("popover.metric.percent_left", 87) == "87% left")
            #expect(L("notification.quota_remaining", "Weekly", 12) == "Claude Weekly at 12% remaining")
            #expect(L("popover.pace.duration_days_hours", 2, 3) == "2d 3h")
        }
        withLanguage("pt-BR") {
            #expect(L("popover.metric.percent_left", 87) == "87% restante")
            #expect(L("popover.pace.duration_minutes", 45) == "45min")
        }
    }

    /// A missing key falls back to the English base, then to the raw key (never an empty string).
    @Test
    func missingKeyFallsBackGracefully() {
        withLanguage("pt-BR") {
            #expect(L("this.key.does.not.exist") == "this.key.does.not.exist")
        }
    }

    /// The pace/menu enums localize their labels through `L(…)`, so the same `AppLanguage` value
    /// renders a localized picker label (AC3 — the picker itself is localizable).
    @Test
    func appLanguageLabelsAreLocalized() {
        withLanguage("en") {
            #expect(AppLanguage.system.label == "System")
            #expect(AppLanguage.portuguese.label == "Português (Brasil)")
        }
        withLanguage("pt-BR") {
            #expect(AppLanguage.system.label == "Sistema")
        }
    }
}

/// AC4: the language preference persists under the stable `"appLanguage"` key and survives restart.
@MainActor
struct AppLanguageSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "exb.lang.\(UUID().uuidString)")!
    }

    @Test
    func defaultsToSystem() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.appLanguage == .system)
        #expect(store.appLanguage.rawValue == "")
    }

    @Test
    func persistsUnderAppLanguageKeyAndSurvivesRestart() {
        let suite = defaults()
        let first = SettingsStore(defaults: suite)
        first.appLanguage = .portuguese
        first.flush()

        // AC4: the raw value is stored under the un-namespaced `"appLanguage"` key the engine reads.
        #expect(suite.string(forKey: "appLanguage") == "pt-BR")

        let second = SettingsStore(defaults: suite)
        #expect(second.appLanguage == .portuguese)
    }

    @Test
    func changeFiresCallbackOnce() {
        let store = SettingsStore(defaults: defaults())
        var fired: [AppLanguage] = []
        store.onAppLanguageChange = { fired.append($0) }

        store.appLanguage = .english
        store.appLanguage = .english // no-op, must not fire again
        store.appLanguage = .portuguese

        #expect(fired == [.english, .portuguese])
    }
}
