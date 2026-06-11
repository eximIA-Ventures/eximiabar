import ClaudeBarCore
import Foundation
import SwiftUI

/// The six display states of the update flow (EXB-2.4 AC4).
///
/// `Equatable` so the view diffs cheaply and tests can assert exact transitions. The associated
/// values carry exactly what each state needs to render: a version string, a download fraction, or a
/// (already-localized) error message.
public enum UpdateState: Equatable, Sendable {
    /// Initial / resting state — only the "Check for Updates" button is shown.
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(Double)
    case installing
    case error(message: String)
}

/// Bridges the off-main update pipeline to the SwiftUI About pane (EXB-2.4 AC4 / AC11).
///
/// `@MainActor` and `ObservableObject`: every state mutation happens on the main thread, so the
/// `@Published` property is always read/written from the UI context. The actual work is delegated to
/// the ``UpdateChecker`` / ``AppUpdater`` actors, which run off-main; results hop back here via
/// `await` and a `MainActor`-isolated assignment. The view model never blocks the main thread.
@MainActor
public final class UpdateViewModel: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle

    /// The release resolved by the last successful `.available` check — drives "Download and Install".
    public private(set) var pendingRelease: ReleaseInfo?

    private let checker: UpdateChecker
    private let updaterFactory: @Sendable () -> AppUpdater
    private let currentVersion: String

    public init(
        checker: UpdateChecker = UpdateChecker(),
        updaterFactory: @escaping @Sendable () -> AppUpdater = { AppUpdater() },
        currentVersion: String = UpdateViewModel.bundleShortVersion())
    {
        self.checker = checker
        self.updaterFactory = updaterFactory
        self.currentVersion = currentVersion
    }

    /// The current `CFBundleShortVersionString` (e.g. `"1.1.0"`), used both as the local version for
    /// comparison (AC3) and in the up-to-date label (AC4).
    public var displayVersion: String { currentVersion }

    // MARK: - Actions (AC1 / AC4)

    /// AC2/AC3: kick off an update check. State → `.checking`, then `.upToDate` / `.available` /
    /// `.error`. All the off-main work lives in the actor; we only publish results here.
    public func checkForUpdates() {
        state = .checking
        pendingRelease = nil
        let version = currentVersion
        Task {
            do {
                let result = try await checker.checkForUpdates(currentVersion: version)
                switch result {
                case .upToDate:
                    state = .upToDate
                case let .available(release):
                    pendingRelease = release
                    state = .available(version: release.version)
                }
            } catch {
                state = .error(message: Self.message(for: error))
            }
        }
    }

    /// AC5–AC9: download + install the given release, driving the progress bar from the actor's
    /// callback. On success the app relaunches and terminates, so this never returns to `.idle`.
    public func downloadAndInstall(release: ReleaseInfo) {
        state = .downloading(0)
        let updater = updaterFactory()
        Task {
            do {
                try await updater.downloadAndInstall(release: release) { [weak self] fraction in
                    // The callback fires off-main; hop to the actor to publish.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(fraction ?? 0)
                        }
                    }
                }
                // Reaching here means the relaunch step ran; show installing as a terminal frame.
                state = .installing
            } catch {
                state = .error(message: Self.message(for: error))
            }
        }
    }

    /// Convenience for the "Download and Install" button — installs the most recent `.available`.
    public func installPendingRelease() {
        guard let release = pendingRelease else { return }
        downloadAndInstall(release: release)
    }

    // MARK: - Error mapping (AC10)

    /// Map an ``UpdateError`` (or any error) to a localized, user-facing message.
    static func message(for error: Error) -> String {
        guard let updateError = error as? UpdateError else {
            return L("update.error.generic")
        }
        switch updateError {
        case .noNetwork:
            return L("update.error.no_network")
        case .rateLimited:
            return L("update.error.rate_limited")
        case .noAsset:
            return L("update.error.no_asset")
        case .notWritable:
            return L("update.error.not_writable")
        case .extractionFailed:
            return L("update.error.extraction_failed")
        case .invalidBundle:
            return L("update.error.invalid_bundle")
        case .invalidResponse, .server:
            return L("update.error.generic")
        case let .installFailed(detail):
            return L("update.error.install_failed", detail)
        }
    }

    // MARK: - Version source

    /// Read `CFBundleShortVersionString` from the running bundle, defaulting to `"0.0.0"` so a
    /// missing key never crashes the check (it would simply make every remote look newer).
    public static func bundleShortVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }
}
