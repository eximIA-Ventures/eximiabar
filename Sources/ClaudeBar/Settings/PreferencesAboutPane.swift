import AppKit
import SwiftUI

/// About preferences pane (AC6).
///
/// App icon (92×92, corner radius 16, hover scale 1.05), name + version from `Bundle.main`, and
/// accent-colored links. Adapted from `_reference_codexbar/Sources/CodexBar/PreferencesAboutPane.swift`,
/// minus the Sparkle auto-update controls (not in scope for exímIABar).
@MainActor
struct PreferencesAboutPane: View {
    private static let repoURL = "https://github.com/eximIA-Ventures/eximiabar"

    @State private var iconHover = false
    @StateObject private var updateModel = UpdateViewModel()

    private var versionString: String {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        VStack(spacing: 12) {
            iconButton

            VStack(spacing: 2) {
                Text(L("about.app_name"))
                    .font(.title3).bold()
                Text(L("about.version", versionString))
                    .foregroundStyle(.secondary)
                Text(L("about.tagline"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            UpdateSectionView(model: updateModel)
                .padding(.top, 4)

            VStack(alignment: .center, spacing: 10) {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: L("about.github"),
                    url: Self.repoURL)
                AboutLinkRow(
                    icon: "doc.text",
                    title: L("about.license"),
                    url: "\(Self.repoURL)/blob/main/LICENSE")
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Divider()

            Text(L("about.attribution"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var iconButton: some View {
        if let image = NSApplication.shared.applicationIconImage {
            Button(action: Self.openProjectHome) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 92, height: 92)
                    .cornerRadius(16)
                    .scaleEffect(self.iconHover ? 1.05 : 1.0)
                    .shadow(
                        color: self.iconHover ? .accentColor.opacity(0.25) : .clear,
                        radius: 6)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.iconHover = hovering
                }
            }
        }
    }

    private static func openProjectHome() {
        guard let url = URL(string: repoURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
