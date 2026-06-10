import AppKit
import SwiftUI

/// A labelled checkbox with an optional tertiary subtitle 5.4 pt below it (AC7).
///
/// Adapted from `_reference_codexbar/Sources/CodexBar/PreferencesComponents.swift` for visual
/// fidelity — same checkbox style, same `.footnote .tertiary` subtitle, same spacing.
@MainActor
struct PreferenceToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var binding: Bool

    init(title: String, subtitle: String? = nil, binding: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._binding = binding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5.4) {
            Toggle(isOn: self.$binding) {
                Text(self.title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A titled section: `.subheadline.semibold` title over a `VStack(spacing: 10)` of content (AC7).
@MainActor
struct SettingsSection<Content: View>: View {
    let title: String?
    let caption: String?
    let contentSpacing: CGFloat
    private let content: () -> Content

    init(
        title: String? = nil,
        caption: String? = nil,
        contentSpacing: CGFloat = 14,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.title = title
        self.caption = caption
        self.contentSpacing = contentSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: self.contentSpacing) {
                self.content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An UPPERCASE `.caption` secondary section header (AC3 — "UPPERCASE style").
@MainActor
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(self.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// A label/picker row: a leading title (+ optional subtitle) and a trailing `.menu` picker
/// constrained to `maxWidth` (AC3/AC5). Mirrors the reference label-then-picker layout.
@MainActor
struct LabelledRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    private let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(.body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            self.trailing()
        }
    }
}

/// An accent-colored link row that underlines on hover (AC6).
@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                Text(self.title)
                    .underline(self.hovering, color: .accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
    }
}

/// A two-field "warn at: upper / lower" threshold editor (AC3/AC4 multi-value picker).
///
/// Renders the `[upper, lower]` threshold pair as two numeric text fields plus an Apply button —
/// matching `QuotaWarningThresholdField` in the reference. Values are sanitized to 1–99 and sorted
/// descending on commit.
@MainActor
struct ThresholdPairField: View {
    let title: String
    @Binding var thresholds: [Int]

    @State private var upperText = ""
    @State private var lowerText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(self.title)
                .font(.footnote.weight(.semibold))
                .frame(width: 110, alignment: .leading)

            Text("Upper")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("50", text: self.$upperText)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(width: 56)
                .onChange(of: self.upperText) { _, value in
                    self.upperText = Self.filtered(value)
                }
                .onSubmit { self.commit() }

            Text("Lower")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("20", text: self.$lowerText)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(width: 56)
                .onChange(of: self.lowerText) { _, value in
                    self.lowerText = Self.filtered(value)
                }
                .onSubmit { self.commit() }

            Button("Apply") { self.commit() }
                .controlSize(.small)
        }
        .onAppear { self.sync(from: self.thresholds) }
        .onChange(of: self.thresholds) { _, value in self.sync(from: value) }
    }

    private func commit() {
        let values = [Self.int(self.upperText), Self.int(self.lowerText)]
            .compactMap { $0 }
            .map { min(99, max(1, $0)) }
            .sorted(by: >)
        self.thresholds = values
        self.sync(from: values)
    }

    private func sync(from values: [Int]) {
        let sorted = values.sorted(by: >)
        self.upperText = sorted.first.map(String.init) ?? ""
        self.lowerText = sorted.dropFirst().first.map(String.init) ?? ""
    }

    private static func filtered(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }

    private static func int(_ text: String) -> Int? {
        text.isEmpty ? nil : Int(text)
    }
}
