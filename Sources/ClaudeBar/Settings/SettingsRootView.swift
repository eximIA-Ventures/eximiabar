import SwiftUI

/// The four-tab settings surface (AC2).
///
/// A `TabView` with the macOS toolbar-style tab picker at the top — General, Claude, Display,
/// About. Each tab supplies its own internal scroll/padding (h24/v16, AC1). The hosting window is
/// fixed to 546×638 pt by `SettingsWindowController` (AC1).
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
                .tabItem { Label("General", systemImage: "gearshape") }

            PreferencesClaudePane(settings: settings)
                .tabItem { Label("Claude", systemImage: "key") }

            PreferencesDisplayPane(settings: settings)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }

            PreferencesAboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(.top, Self.titlebarInset)
        .frame(width: 546, height: 638 + Self.titlebarInset)
    }
}
