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
            SectionHeader("Menu Bar")
            // AC5: switches `displayMode` between `.meterIcon` and `.brandIconPercent` (F2/P1).
            PreferenceToggleRow(
                title: "Brand icon + %",
                subtitle: "Show the Claude brand icon with the remaining percentage instead of the "
                    + "meter icon.",
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
            SectionHeader("Menu Content")

            PreferenceToggleRow(
                title: "Show usage as used",
                subtitle: "Bars fill with consumed quota. Turn off to show remaining instead.",
                binding: $settings.showUsed)

            PreferenceToggleRow(
                title: "Reset time as clock",
                subtitle: "Show \"Resets 14:00\" instead of \"Resets in 2h 15m\".",
                binding: $settings.showAbsoluteReset)

            PreferenceToggleRow(
                title: "Warning markers",
                subtitle: "Show threshold dashes on the usage bars.",
                binding: $settings.showWarningMarkers)

            LabelledRow(
                title: "Workday markers",
                subtitle: "Pace markers on the weekly bar.")
            {
                Picker("Workday markers", selection: $settings.workdayMarkers) {
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
