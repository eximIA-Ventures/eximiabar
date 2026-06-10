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
            SectionHeader("System")
            PreferenceToggleRow(
                title: "Launch at Login",
                subtitle: "Start exímIABar automatically when you log in.",
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
                    launchError = "Couldn't update login item: \(error.localizedDescription)"
                }
            })
    }

    // MARK: - Automation (refresh + notifications)

    private var automationSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader("Automation")

            LabelledRow(
                title: "Refresh Cadence",
                subtitle: "How often usage is polled in the background.")
            {
                Picker("Refresh Cadence", selection: $settings.refreshCadence) {
                    ForEach(RefreshCadence.allCases) { cadence in
                        Text(cadence.label).tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
            if settings.refreshCadence == .manual {
                Text("Usage only refreshes on launch or when you open the menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            PreferenceToggleRow(
                title: "Quota notifications",
                subtitle: "Warn when remaining quota drops below a threshold.",
                binding: $settings.notificationsEnabled)

            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    ThresholdPairField(title: "Session warn at", thresholds: $settings.sessionThresholds)
                    ThresholdPairField(title: "Weekly warn at", thresholds: $settings.weeklyThresholds)
                    PreferenceToggleRow(
                        title: "Play sound",
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
            SectionHeader("Usage")
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.costEnabled) {
                    Text("Show cost summary")
                        .font(.body)
                }
                .toggleStyle(.checkbox)

                Text("Scans local Claude usage logs to estimate spend. Nothing leaves your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.costEnabled {
                    Stepper(value: $settings.costDays, in: 1...365, step: 1) {
                        Text("History: \(settings.costDays) day\(settings.costDays == 1 ? "" : "s")")
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
                Button("Quit exímIABar") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
