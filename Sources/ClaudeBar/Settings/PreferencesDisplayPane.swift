import SwiftUI

/// Display preferences pane (AC5).
///
/// Two sections: Menu Bar (brand-icon-plus-percent display mode) and Menu Content (how the bars and
/// reset times render). Layout mirrors `_reference_codexbar/Sources/CodexBar/PreferencesDisplayPane.swift`.
@MainActor
struct PreferencesDisplayPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                menuBarSection
                Divider()
                menuContentSection
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
            // AC5: switches `displayMode` between `.meterIcon` and `.brandIconPercent` (F2/P1).
            PreferenceToggleRow(
                title: L("settings.display.brand_icon"),
                subtitle: L("settings.display.brand_icon.subtitle"),
                binding: brandIconBinding)
        }
    }

    /// `displayMode == .brandIconPercent` expressed as a Bool toggle (AC5/T5).
    private var brandIconBinding: Binding<Bool> {
        Binding(
            get: { settings.displayMode == .brandIconPercent },
            set: { settings.displayMode = $0 ? .brandIconPercent : .meterIcon })
    }

    // MARK: - Menu Content

    private var menuContentSection: some View {
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
        }
    }
}
