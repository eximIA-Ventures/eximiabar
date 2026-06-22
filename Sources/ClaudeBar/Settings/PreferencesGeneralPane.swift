import AppKit
import ClaudeBarCore
import SwiftUI

/// General preferences pane — redesigned (v2.1.4): grouped by user intent.
///
/// Three sections: **System** (launch at login + language), **Data** (refresh cadence + the cost
/// scan toggle), and **Connection** (credential source + keychain prompt behaviour + an "Advanced"
/// disclosure with the developer-only web-extras / custom-binary options).
///
/// The redesign consolidates what used to be scattered: notifications and the warning thresholds
/// moved to the dedicated `PreferencesAlertsPane`; transparency/theme moved into `PreferencesDisplayPane`;
/// and Quit moved to the window footer in `SettingsRootView`.
@MainActor
struct PreferencesGeneralPane: View {
    @Bindable var settings: SettingsStore
    /// Applies the launch-at-login change to `SMAppService` when the toggle flips.
    let launchManager: LaunchAtLoginManager

    @State private var launchError: String?

    /// Credential-source choice; `auto` maps to `settings.source == nil`. Web is P2 (disabled).
    private enum SourceChoice: String, CaseIterable, Identifiable {
        case auto, oauth, cli, web
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: L("settings.claude.source.auto")
            case .oauth: L("settings.claude.source.oauth")
            case .cli: L("settings.claude.source.cli")
            case .web: L("settings.claude.source.web")
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                systemSection
                Divider()
                dataSection
                Divider()
                connectionSection
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

            // EXB-2.2 AC3: Language / Idioma — `appLanguage`'s didSet does the in-process switch.
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
        }
    }

    /// Mirrors `settings.launchAtLogin` but routes the register/unregister through `SMAppService`.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    try launchManager.set(enabled: newValue)
                    settings.launchAtLogin = newValue
                    launchError = nil
                } catch {
                    settings.launchAtLogin = launchManager.isEnabled
                    launchError = L("settings.general.launch_error", error.localizedDescription)
                }
            })
    }

    // MARK: - Data (refresh cadence + cost scan)

    private var dataSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.general.section.data"))

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

    // MARK: - Connection (credential source + keychain + advanced)

    private var connectionSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.general.section.connection"))

            LabelledRow(
                title: L("settings.claude.source"),
                subtitle: L("settings.claude.source.subtitle"))
            {
                Picker(L("settings.claude.source"), selection: sourceBinding) {
                    ForEach(SourceChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
            // Web is P2 (out of scope) — surfaced but disabled so the option is visible/greyed.
            Text(L("settings.claude.source.web_note"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            PreferenceToggleRow(
                title: L("settings.claude.avoid_prompts"),
                subtitle: L("settings.claude.avoid_prompts.subtitle"),
                binding: $settings.useSecurityCLIReader)

            // The prompt-policy picker is only relevant when the security CLI reader is ON.
            if settings.useSecurityCLIReader {
                LabelledRow(
                    title: L("settings.claude.prompt_policy"),
                    subtitle: L("settings.claude.prompt_policy.subtitle"))
                {
                    Picker(L("settings.claude.prompt_policy"), selection: $settings.keychainPromptPolicy) {
                        ForEach(KeychainPromptPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
            }

            DisclosureGroup(L("settings.claude.developer")) {
                VStack(alignment: .leading, spacing: 12) {
                    PreferenceToggleRow(
                        title: L("settings.claude.web_extras"),
                        subtitle: L("settings.claude.web_extras.subtitle"),
                        binding: $settings.webExtrasEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.claude.custom_binary"))
                            .font(.body)
                        TextField(L("settings.claude.custom_binary.placeholder"), text: claudeBinaryBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                        Text(L("settings.claude.custom_binary.subtitle"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var sourceBinding: Binding<SourceChoice> {
        Binding(
            get: {
                switch settings.source {
                case .none: .auto
                case .oauth: .oauth
                case .cli: .cli
                case .web: .web
                }
            },
            set: { choice in
                switch choice {
                case .auto: settings.source = nil
                case .oauth: settings.source = .oauth
                case .cli: settings.source = .cli
                // Web stays disabled — ignore the selection (P2 not available).
                case .web: break
                }
            })
    }

    /// Maps the optional `claudeBinaryPath` to a non-optional text-field binding (empty → `nil`).
    private var claudeBinaryBinding: Binding<String> {
        Binding(
            get: { settings.claudeBinaryPath ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.claudeBinaryPath = trimmed.isEmpty ? nil : trimmed
            })
    }
}
