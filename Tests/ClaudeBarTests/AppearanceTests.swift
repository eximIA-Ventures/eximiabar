import AppKit
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for EXB-3.1 — Glassmorphism REAL + Appearance pane.
///
/// Covers the load-bearing contract the failed rounds missed: that each `TransparencyLevel` maps to a
/// genuinely translucent `NSVisualEffectView.Material` (AC6), that `ThemeOverride` maps to the right
/// `NSAppearance` (AC4), that both survive a restart through `SettingsStore` (AC3/AC4), that the
/// live-apply callbacks fire (AC3/AC4), and that every new string resolves in both languages (AC5).
@MainActor
struct AppearanceTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "exb.appearance.\(UUID().uuidString)")!
    }

    private func withLanguage<T>(_ language: String?, _ body: () -> T) -> T {
        ClaudeBarLocalization.$languageOverride.withValue(language) {
            resetClaudeBarLocalizationCache()
            defer { resetClaudeBarLocalizationCache() }
            return body()
        }
    }

    // MARK: - TransparencyLevel → Material mapping (AC6)

    /// The exact mapping the failed rounds got wrong: `.frosted` MUST be `.hudWindow` (strong frost),
    /// `.standard` the medium `.popover`, and `.opaque` the least-translucent vibrant material. None of
    /// these is `.windowBackground`, the solid material that produced the opaque result in EXB-2.1.
    @Test
    func transparencyLevelMapsToMaterial() {
        #expect(TransparencyLevel.opaque.material == .underWindowBackground)
        #expect(TransparencyLevel.standard.material == .popover)
        #expect(TransparencyLevel.frosted.material == .hudWindow)
    }

    /// Guard against a regression that re-introduces the opaque material: no level may map to
    /// `.windowBackground`, which renders near-solid on a floating window (the EXB-2.1 root cause).
    @Test
    func noTransparencyLevelUsesOpaqueWindowBackground() {
        for level in TransparencyLevel.allCases {
            #expect(level.material != .windowBackground)
        }
    }

    /// The shipping default is `.frosted` (strong glass) — the whole point of EXB-3.1.
    @Test
    func transparencyDefaultsToFrosted() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.transparencyLevel == .frosted)
        #expect(store.transparencyLevel.material == .hudWindow)
    }

    // MARK: - ThemeOverride → NSAppearance mapping (AC4)

    @Test
    func themeOverrideMapsToAppearance() {
        #expect(ThemeOverride.system.appearance == nil)
        #expect(ThemeOverride.light.appearance?.name == .aqua)
        #expect(ThemeOverride.dark.appearance?.name == .darkAqua)
    }

    @Test
    func themeDefaultsToSystem() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.themeOverride == .system)
        #expect(store.themeOverride.appearance == nil)
    }

    // MARK: - Persistence round-trip (AC3/AC4 — survive restart)

    @Test
    func appearanceSettingsSurviveRestart() {
        let suite = defaults()

        let first = SettingsStore(defaults: suite)
        first.transparencyLevel = .opaque
        first.themeOverride = .dark
        first.flush()

        let second = SettingsStore(defaults: suite)
        #expect(second.transparencyLevel == .opaque)
        #expect(second.themeOverride == .dark)
    }

    /// A round-trip across every enum case proves the `RawRepresentable` string persistence is total,
    /// not just covering the values used above.
    @Test
    func everyAppearanceCaseRoundTrips() {
        for level in TransparencyLevel.allCases {
            for theme in ThemeOverride.allCases {
                let suite = defaults()
                let first = SettingsStore(defaults: suite)
                first.transparencyLevel = level
                first.themeOverride = theme
                first.flush()

                let second = SettingsStore(defaults: suite)
                #expect(second.transparencyLevel == level)
                #expect(second.themeOverride == theme)
            }
        }
    }

    // MARK: - Live-apply callbacks (AC3/AC4)

    @Test
    func transparencyChangeFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        var levels: [TransparencyLevel] = []
        store.onTransparencyChange = { levels.append($0) }

        store.transparencyLevel = .standard
        store.transparencyLevel = .standard // no-op, must not fire again
        store.transparencyLevel = .opaque

        #expect(levels == [.standard, .opaque])
    }

    @Test
    func themeChangeFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        var themes: [ThemeOverride] = []
        store.onThemeChange = { themes.append($0) }

        store.themeOverride = .light
        store.themeOverride = .light // no-op
        store.themeOverride = .dark

        #expect(themes == [.light, .dark])
    }

    // MARK: - Localization (AC5)

    /// Every new EXB-3.1 string resolves to a non-key literal in English (the key never leaks to the UI).
    @Test
    func appearanceStringsResolveInEnglish() {
        withLanguage("en") {
            #expect(L("appearance.tab") == "Appearance")
            #expect(L("appearance.transparency.label") == "Window material")
            #expect(L("appearance.transparency.opaque") == "Opaque")
            #expect(L("appearance.transparency.standard") == "Standard")
            #expect(L("appearance.transparency.frosted") == "Frosted")
            #expect(L("appearance.theme.label") == "Appearance")
            #expect(L("appearance.theme.system") == "System")
            #expect(L("appearance.theme.light") == "Light")
            #expect(L("appearance.theme.dark") == "Dark")
        }
    }

    /// The pt-BR table translates every new key (none falls back to the English literal or the raw key).
    @Test
    func appearanceStringsResolveInPortuguese() {
        withLanguage("pt-BR") {
            #expect(L("appearance.tab") == "Aparência")
            #expect(L("appearance.transparency.label") == "Material da janela")
            #expect(L("appearance.transparency.opaque") == "Opaco")
            #expect(L("appearance.transparency.standard") == "Padrão")
            #expect(L("appearance.transparency.frosted") == "Vidro")
            #expect(L("appearance.theme.system") == "Sistema")
            #expect(L("appearance.theme.light") == "Claro")
            #expect(L("appearance.theme.dark") == "Escuro")
        }
    }

    /// The enum `.label` accessors route through `L(…)`, so they translate too (the picker shows them).
    @Test
    func enumLabelsAreLocalized() {
        withLanguage("pt-BR") {
            #expect(TransparencyLevel.frosted.label == "Vidro")
            #expect(ThemeOverride.dark.label == "Escuro")
        }
        withLanguage("en") {
            #expect(TransparencyLevel.frosted.label == "Frosted")
            #expect(ThemeOverride.dark.label == "Dark")
        }
    }
}
