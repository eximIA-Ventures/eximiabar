import ClaudeBarCore
import SwiftUI

/// Claude-specific preferences pane (AC4).
///
/// Derived from `_reference_codexbar/Sources/CodexBar/PreferencesProviderDetailView.swift`, stripped
/// to Claude-only: credential source selection, keychain prompt behaviour, and the developer-only
/// web-extras / custom-binary options hidden behind a disclosure group.
@MainActor
struct PreferencesClaudePane: View {
    @Bindable var settings: SettingsStore

    /// `nil` source means auto — the picker uses a sentinel tag the binding maps to/from `nil`.
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
                sourceSection
                Divider()
                keychainSection
                Divider()
                advancedSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Source

    private var sourceSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.claude.section.source"))
            LabelledRow(
                title: L("settings.claude.source"),
                subtitle: L("settings.claude.source.subtitle"))
            {
                Picker(L("settings.claude.source"), selection: sourceBinding) {
                    ForEach(SourceChoice.allCases) { choice in
                        Text(choice.label)
                            .tag(choice)
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

    // MARK: - Keychain

    private var keychainSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.claude.section.keychain"))
            PreferenceToggleRow(
                title: L("settings.claude.avoid_prompts"),
                subtitle: L("settings.claude.avoid_prompts.subtitle"),
                binding: $settings.useSecurityCLIReader)

            // AC4: the prompt-policy picker is only visible when the security CLI reader is ON.
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
        }
    }

    // MARK: - Advanced (developer)

    private var advancedSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.claude.section.per_window"))
            ThresholdPairField(title: L("settings.threshold.session"), thresholds: $settings.sessionThresholds)
            ThresholdPairField(title: L("settings.threshold.weekly"), thresholds: $settings.weeklyThresholds)

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
