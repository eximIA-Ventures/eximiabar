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
            case .auto: "Auto"
            case .oauth: "OAuth"
            case .cli: "CLI"
            case .web: "Web"
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
            SectionHeader("Credential Source")
            LabelledRow(
                title: "Source",
                subtitle: "Where exímIABar reads your Claude usage from.")
            {
                Picker("Source", selection: sourceBinding) {
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
            Text("Web is not yet available (P2).")
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
            SectionHeader("Keychain")
            PreferenceToggleRow(
                title: "Avoid keychain prompts",
                subtitle: "Read credentials via the security CLI (1.5 s timeout) instead of the "
                    + "Security framework, which can show a system prompt.",
                binding: $settings.useSecurityCLIReader)

            // AC4: the prompt-policy picker is only visible when the security CLI reader is ON.
            if settings.useSecurityCLIReader {
                LabelledRow(
                    title: "Keychain prompt policy",
                    subtitle: "When a keychain dialog may be raised.")
                {
                    Picker("Keychain prompt policy", selection: $settings.keychainPromptPolicy) {
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
            SectionHeader("Per-window warnings")
            ThresholdPairField(title: "Session warn at", thresholds: $settings.sessionThresholds)
            ThresholdPairField(title: "Weekly warn at", thresholds: $settings.weeklyThresholds)

            DisclosureGroup("Developer") {
                VStack(alignment: .leading, spacing: 12) {
                    PreferenceToggleRow(
                        title: "Web extras",
                        subtitle: "Fetch an extra window-enrichment call from claude.ai on top of "
                            + "OAuth. Stubbed in this build — toggling it logs and skips.",
                        binding: $settings.webExtrasEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom claude binary path")
                            .font(.body)
                        TextField("/usr/local/bin/claude", text: claudeBinaryBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                        Text("For debugging the CLI source. Leave empty to use the default lookup.")
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
