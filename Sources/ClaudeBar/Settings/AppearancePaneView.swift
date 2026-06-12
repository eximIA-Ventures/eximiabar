import SwiftUI

/// Appearance preferences pane (EXB-3.1 AC3/AC4/AC5).
///
/// Two controls, both applied **immediately** with no relaunch:
/// - **Transparency** — a 3-level segmented picker (`Opaque` / `Standard` / `Frosted`) that drives the
///   `NSVisualEffectView.material` of the popover and Settings window via `SettingsStore.onTransparencyChange`.
/// - **Theme** — a `System` / `Light` / `Dark` override that drives `NSApp.appearance` via
///   `SettingsStore.onThemeChange`.
///
/// Both selections persist through `SettingsStore` (survive restart). The pane reuses the shared
/// `SettingsSection` / `SectionHeader` / `LabelledRow` components so its layout matches the other
/// panes (h24/v16). Like every other pane, the root is a plain `ScrollView`/`VStack` with NO
/// `.background` modifier so the window's frosted material shows through (EXB-3.1 AC2).
@MainActor
struct AppearancePaneView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                transparencySection
                Divider()
                themeSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Transparency (AC3)

    private var transparencySection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("appearance.section.transparency"))
            LabelledRow(
                title: L("appearance.transparency.label"),
                subtitle: L("appearance.transparency.subtitle"))
            {
                Picker(L("appearance.transparency.label"), selection: $settings.transparencyLevel) {
                    ForEach(TransparencyLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    // MARK: - Theme (AC4)

    private var themeSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("appearance.section.theme"))
            LabelledRow(
                title: L("appearance.theme.label"),
                subtitle: L("appearance.theme.subtitle"))
            {
                Picker(L("appearance.theme.label"), selection: $settings.themeOverride) {
                    ForEach(ThemeOverride.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}
