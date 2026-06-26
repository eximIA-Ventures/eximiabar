import AppKit
import SwiftUI

/// The settings surface — redesigned to four intent-based tabs (v2.1.4).
///
/// `General` (system + data + connection), `Display` (menu bar + usage card + appearance, folding in
/// the former separate Appearance tab), `Alerts` (notifications + thresholds, consolidated and
/// de-duplicated), and `About`. A persistent window footer hosts a discreet Quit button (it used to
/// live awkwardly inside a General section).
///
/// A `TabView` with the macOS toolbar-style tab picker at the top. Each tab supplies its own internal
/// scroll/padding (h24/v16). The hosting window is fixed to 546×(638+28) pt by
/// `SettingsWindowController`.
///
/// EXB-2.1 AC2: the hosting window uses `.fullSizeContentView` so the visual-effect blur extends under
/// the titlebar. The `titlebarInset` pushes the tab strip below the traffic-light band so the tabs do
/// not collide with the window controls while the frosted material still shows through.
@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsStore
    let launchManager: LaunchAtLoginManager

    /// Standard macOS titlebar height; reserved at the top so the tab strip clears the traffic lights
    /// now that the content view spans the full window (`.fullSizeContentView`).
    private static let titlebarInset: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                PreferencesGeneralPane(settings: settings, launchManager: launchManager)
                    .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }

                PreferencesDisplayPane(settings: settings)
                    .tabItem { Label(L("settings.tab.display"), systemImage: "menubar.rectangle") }

                PreferencesAlertsPane(settings: settings)
                    .tabItem { Label(L("settings.tab.alerts"), systemImage: "bell") }

                PreferencesAboutPane()
                    .tabItem { Label(L("settings.tab.about"), systemImage: "info.circle") }
            }

            Divider()

            HStack {
                Spacer()
                Button(L("settings.general.quit")) { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .padding(.top, Self.titlebarInset)
        .frame(width: 546, height: 638 + Self.titlebarInset)
        // v2.1 design system: accent across every control (toggles, selection, focus) so Preferences
        // reads as the same family as the popover. v2.3.0: the accent now follows the popover theme —
        // terracotta in classic, amber in meter — and the theme is injected so detail links pick it up.
        .tint(DesignTokens.accent(for: settings.popoverTheme))
        .environment(\.popoverTheme, settings.popoverTheme)
        // EXB-2.2 AC5/AC7 (Option A): `L(…)` reads the active `.lproj` table, not an `@Observable`
        // property, so keying the subtree on the selected language is what forces SwiftUI to rebuild
        // every localized body the instant the picker changes — an immediate, relaunch-free switch.
        .id(settings.appLanguage)
    }
}
