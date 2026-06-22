import ApplicationServices
import SwiftUI

/// Display preferences pane — redesigned (v2.1.4): everything the user *sees*, under one roof.
///
/// Three sections: **Menu Bar** (icon style + what renders beside it + the global shortcut),
/// **Usage Card** (how the popover bars and reset times render), and **Appearance** (transparency +
/// theme — folded in from the former separate Appearance tab). Both appearance controls apply
/// immediately with no relaunch via `SettingsStore.onTransparencyChange` / `onThemeChange`.
@MainActor
struct PreferencesDisplayPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                menuBarSection
                Divider()
                usageCardSection
                Divider()
                appearanceSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.display.section.menu_bar"))
            // Switches `displayMode` between `.meterIcon` and `.brandIconPercent` (F2/P1).
            PreferenceToggleRow(
                title: L("settings.display.brand_icon"),
                subtitle: L("settings.display.brand_icon.subtitle"),
                binding: brandIconBinding)

            // Picks what renders next to the icon (none / % / time / cost / sparkline).
            LabelledRow(
                title: L("settings.display.menu_content"),
                subtitle: L("settings.display.menu_content.subtitle"))
            {
                Picker(L("settings.display.menu_content"), selection: $settings.menuBarContent) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.label).tag(content)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }

            // Capture field for the global popover-toggle shortcut.
            LabelledRow(
                title: L("settings.display.hotkey"),
                subtitle: L("settings.display.hotkey.subtitle"))
            {
                HotkeyCaptureField(
                    binding: $settings.globalHotkey,
                    placeholder: L("settings.display.hotkey.placeholder"),
                    capturingPrompt: L("settings.display.hotkey.capturing"))
                    .frame(width: 130)
            }

            // Show the Accessibility hint when the process is not yet trusted (out-of-app shortcut).
            if !accessibilityTrusted {
                Text(L("settings.display.hotkey.accessibility_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether the process has Accessibility permission, re-evaluated whenever the pane re-renders.
    private var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// `displayMode == .brandIconPercent` expressed as a Bool toggle.
    private var brandIconBinding: Binding<Bool> {
        Binding(
            get: { settings.displayMode == .brandIconPercent },
            set: { settings.displayMode = $0 ? .brandIconPercent : .meterIcon })
    }

    // MARK: - Usage Card (popover bars)

    private var usageCardSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.display.section.menu_content"))

            PreferenceToggleRow(
                title: L("settings.display.show_used"),
                subtitle: L("settings.display.show_used.subtitle"),
                binding: $settings.showUsed)

            PreferenceToggleRow(
                title: L("settings.display.reset_clock"),
                subtitle: L("settings.display.reset_clock.subtitle"),
                binding: $settings.showAbsoluteReset)

            PreferenceToggleRow(
                title: L("settings.display.warning_markers"),
                subtitle: L("settings.display.warning_markers.subtitle"),
                binding: $settings.showWarningMarkers)

            LabelledRow(
                title: L("settings.display.workday_markers"),
                subtitle: L("settings.display.workday_markers.subtitle"))
            {
                Picker(L("settings.display.workday_markers"), selection: $settings.workdayMarkers) {
                    ForEach(WorkdayMarkers.allCases) { marker in
                        Text(marker.label).tag(marker)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 100)
            }

            // How the weekly pace / forecast is surfaced (stripe on the bar vs. text).
            LabelledRow(
                title: L("settings.display.pace_mode"),
                subtitle: L("settings.display.pace_mode.subtitle"))
            {
                Picker(L("settings.display.pace_mode"), selection: $settings.paceDisplayMode) {
                    ForEach(PaceDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }
        }
    }

    // MARK: - Appearance (transparency + theme; folded in from the former Appearance tab)

    private var appearanceSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.display.section.appearance"))

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
