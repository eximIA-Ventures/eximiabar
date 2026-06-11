import SwiftUI

/// The "Check for Updates" control + state-driven status, embedded in the About pane (EXB-2.4 AC1/AC4).
///
/// A pure, declarative read of ``UpdateViewModel/state``: the button is shown when idle / up-to-date
/// / errored, and the status line below mirrors the six update states (spinner + label, progress
/// bar, error text in `systemRed` with Retry). All work is delegated to the view model — this view
/// never touches the network or the filesystem.
@MainActor
struct UpdateSectionView: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        VStack(spacing: 10) {
            primaryControl
            statusLine
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.state)
    }

    // MARK: - Primary control (AC1)

    @ViewBuilder
    private var primaryControl: some View {
        switch model.state {
        case .idle, .upToDate, .error:
            Button(L("update.check_button")) {
                model.checkForUpdates()
            }
            .controlSize(.regular)
        case let .available(version):
            VStack(spacing: 8) {
                Text(L("update.available", version))
                    .font(.body)
                Button(L("update.download_button")) {
                    model.installPendingRelease()
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            }
        case .checking, .downloading, .installing:
            EmptyView()
        }
    }

    // MARK: - Status line (AC4)

    @ViewBuilder
    private var statusLine: some View {
        switch model.state {
        case .idle, .available:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("update.checking"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            Text(L("update.up_to_date", model.displayVersion))
                .font(.footnote)
                .foregroundStyle(.secondary)

        case let .downloading(progress):
            VStack(spacing: 4) {
                // Determinate when we have a fraction, indeterminate (0) renders as a spinner-like
                // bar — AC4 allows either depending on Content-Length availability.
                if progress > 0 {
                    ProgressView(value: progress)
                        .frame(maxWidth: 220)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(L("update.downloading", model.pendingRelease?.version ?? model.displayVersion))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("update.installing"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case let .error(message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("update.retry_button")) {
                    model.checkForUpdates()
                }
                .controlSize(.small)
            }
        }
    }
}
