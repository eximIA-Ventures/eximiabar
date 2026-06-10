import SwiftUI

/// The four-tab settings surface (AC2).
///
/// A `TabView` with the macOS toolbar-style tab picker at the top — General, Claude, Display,
/// About. Each tab supplies its own internal scroll/padding (h24/v16, AC1). The hosting window is
/// fixed to 546×638 pt by `SettingsWindowController` (AC1).
@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsStore
    let launchManager: LaunchAtLoginManager

    var body: some View {
        TabView {
            PreferencesGeneralPane(settings: settings, launchManager: launchManager)
                .tabItem { Label("General", systemImage: "gearshape") }

            PreferencesClaudePane(settings: settings)
                .tabItem { Label("Claude", systemImage: "key") }

            PreferencesDisplayPane(settings: settings)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }

            PreferencesAboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 546, height: 638)
    }
}
