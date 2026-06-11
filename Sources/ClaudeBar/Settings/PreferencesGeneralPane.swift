import AppKit
import SwiftUI

/// General preferences pane (AC3).
///
/// Sections (UPPERCASE `.caption` headers): System (launch at login), Automation (refresh cadence +
/// notifications + thresholds), Usage (cost scan + history days), and a trailing Quit button.
/// Layout mirrors `_reference_codexbar/Sources/CodexBar/PreferencesGeneralPane.swift`.
@MainActor
struct PreferencesGeneralPane: View {
    @Bindable var settings: SettingsStore
    /// Applies the launch-at-login change to `SMAppService` when the toggle flips (AC3/T3).
    let launchManager: LaunchAtLoginManager

    @State private var launchError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                systemSection
                Divider()
                automationSection
                Divider()
                usageSection
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - System

    private var systemSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.general.section.system"))

            // EXB-2.2 AC3: the Language / Idioma picker. Three options (System / English / Português).
            // The label and the option titles are themselves localized so they adapt to the active
            // language. The binding is `settings.appLanguage`, whose `didSet` performs the in-process
            // (Option A) switch — see `SettingsStore.appLanguage`.
            LabelledRow(
                title: L("settings.general.language"),
                subtitle: L("settings.general.language.subtitle"))
            {
                Picker(L("settings.general.language"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }

            PreferenceToggleRow(
                title: L("settings.general.launch_at_login"),
                subtitle: L("settings.general.launch_at_login.subtitle"),
                binding: launchBinding)
            if let launchError {
                Text(launchError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Mirrors `settings.launchAtLogin` but routes the actual register/unregister through
    /// `SMAppService` (AC3). If the system rejects the change, the toggle reverts and an error
    /// is surfaced.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    try launchManager.set(enabled: newValue)
                    settings.launchAtLogin = newValue
                    launchError = nil
                } catch {
                    // Keep the persisted state in sync with reality and tell the user.
                    settings.launchAtLogin = launchManager.isEnabled
                    launchError = L("settings.general.launch_error", error.localizedDescription)
                }
            })
    }

    // MARK: - Automation (refresh + notifications)

    private var automationSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.general.section.automation"))

            LabelledRow(
                title: L("settings.general.refresh_cadence"),
                subtitle: L("settings.general.refresh_cadence.subtitle"))
            {
                Picker(L("settings.general.refresh_cadence"), selection: $settings.refreshCadence) {
                    ForEach(RefreshCadence.allCases) { cadence in
                        Text(cadence.label).tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
            if settings.refreshCadence == .manual {
                Text(L("settings.general.refresh_cadence.manual_note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            PreferenceToggleRow(
                title: L("settings.general.notifications"),
                subtitle: L("settings.general.notifications.subtitle"),
                binding: $settings.notificationsEnabled)

            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    ThresholdPairField(title: L("settings.threshold.session"), thresholds: $settings.sessionThresholds)
                    ThresholdPairField(title: L("settings.threshold.weekly"), thresholds: $settings.weeklyThresholds)
                    PreferenceToggleRow(
                        title: L("settings.general.play_sound"),
                        subtitle: nil,
                        binding: $settings.notificationSound)
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Usage (cost scan)

    private var usageSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.general.section.usage"))
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.costEnabled) {
                    Text(L("settings.general.show_cost"))
                        .font(.body)
                }
                .toggleStyle(.checkbox)

                Text(L("settings.general.show_cost.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.costEnabled {
                    Stepper(value: $settings.costDays, in: 1...365, step: 1) {
                        Text(L(
                            settings.costDays == 1
                                ? "settings.general.history_one"
                                : "settings.general.history_other",
                            settings.costDays))
                            .font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Quit

    private var quitSection: some View {
        SettingsSection(contentSpacing: 12) {
            HStack {
                Spacer()
                Button(L("settings.general.quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
