import SwiftUI

/// The five-tab settings surface (AC2; EXB-3.1 adds Appearance).
///
/// A `TabView` with the macOS toolbar-style tab picker at the top — General, Claude, Display,
/// Appearance, About. Each tab supplies its own internal scroll/padding (h24/v16, AC1). The hosting
/// window is fixed to 546×638 pt by `SettingsWindowController` (AC1).
///
/// EXB-2.1 AC2: the hosting window uses `.fullSizeContentView` so the visual-effect blur extends
/// under the titlebar. The `titlebarInset` pushes the tab strip below the traffic-light band so the
/// tabs do not collide with the window controls while the frosted material still shows through the
/// titlebar area.
@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsStore
    let launchManager: LaunchAtLoginManager

    /// Standard macOS titlebar height; reserved at the top so the tab strip clears the traffic
    /// lights now that the content view spans the full window (`.fullSizeContentView`).
    private static let titlebarInset: CGFloat = 28

    var body: some View {
        TabView {
            PreferencesGeneralPane(settings: settings, launchManager: launchManager)
                .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }

            PreferencesClaudePane(settings: settings)
                .tabItem { Label(L("settings.tab.claude"), systemImage: "key") }

            PreferencesDisplayPane(settings: settings)
                .tabItem { Label(L("settings.tab.display"), systemImage: "menubar.rectangle") }

            // EXB-3.1: the Appearance pane (transparency level + theme override).
            AppearancePaneView(settings: settings)
                .tabItem { Label(L("appearance.tab"), systemImage: "paintbrush") }

            PreferencesAboutPane()
                .tabItem { Label(L("settings.tab.about"), systemImage: "info.circle") }
        }
        .padding(.top, Self.titlebarInset)
        .frame(width: 546, height: 638 + Self.titlebarInset)
        // v2.1 design system: terracotta accent across every control (toggles, selection, focus) so
        // Preferences reads as the same family as the popover, instead of the system blue.
        .tint(DesignTokens.brand)
        // EXB-2.2 AC5/AC7 (Option A): `L(…)` reads the active `.lproj` table, not an `@Observable`
        // property, so keying the subtree on the selected language is what forces SwiftUI to rebuild
        // every localized body the instant the picker changes — an immediate, relaunch-free switch.
        .id(settings.appLanguage)
    }
}
