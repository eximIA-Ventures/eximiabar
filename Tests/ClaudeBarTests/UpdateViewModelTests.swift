import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// EXB-2.4 AC4 / AC10: ``UpdateViewModel`` state machine + localized error mapping.
///
/// The check path is driven through a real ``UpdateChecker`` wired to a fixture-backed
/// `StubTransport`, so the view model is exercised end-to-end without the network. The install path
/// (download/extract/codesign/relaunch) is validated for real in EXB-2.5 — here we cover the parts
/// that don't terminate the process: state transitions and error→message mapping.
@MainActor
struct UpdateViewModelTests {
    private func model(transport: HTTPTransport, currentVersion: String) -> UpdateViewModel {
        UpdateViewModel(
            checker: UpdateChecker(
                transport: transport, endpoint: UpdateChecker.defaultLatestReleaseURL),
            currentVersion: currentVersion)
    }

    /// Spin the run loop until `predicate` holds or we exceed `tries` (each ~5 ms). The check Task is
    /// detached inside `checkForUpdates()`, so we yield to let it complete.
    private func waitUntil(
        tries: Int = 200,
        _ predicate: () -> Bool) async
    {
        for _ in 0..<tries {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Initial state

    @Test
    func startsIdle() {
        let vm = model(
            transport: UpdateStubTransport(response: .stub(status: 200, json: stubReleaseJSON)),
            currentVersion: "1.1.0")
        #expect(vm.state == .idle)
    }

    // MARK: - Check → upToDate (AC4)

    @Test
    func checkUpToDateWhenSameVersion() async {
        let vm = model(
            transport: UpdateStubTransport(response: .stub(status: 200, json: stubReleaseJSON)),
            currentVersion: "1.1.0")
        vm.checkForUpdates()
        await waitUntil { vm.state == .upToDate }
        #expect(vm.state == .upToDate)
        #expect(vm.pendingRelease == nil)
    }

    // MARK: - Check → available (AC4)

    @Test
    func checkAvailableWhenNewerVersion() async {
        let vm = model(
            transport: UpdateStubTransport(response: .stub(status: 200, json: stubReleaseJSON)),
            currentVersion: "1.0.0")
        vm.checkForUpdates()
        await waitUntil {
            if case .available = vm.state { return true }
            return false
        }
        guard case let .available(version) = vm.state else {
            Issue.record("expected .available, got \(vm.state)")
            return
        }
        #expect(version == "1.1.0")
        #expect(vm.pendingRelease?.version == "1.1.0")
    }

    // MARK: - Check → error (AC10)

    @Test
    func checkRateLimitedShowsLocalizedError() async {
        let vm = model(
            transport: UpdateStubTransport(response: .stub(status: 403)),
            currentVersion: "1.1.0")
        vm.checkForUpdates()
        await waitUntil {
            if case .error = vm.state { return true }
            return false
        }
        guard case let .error(message) = vm.state else {
            Issue.record("expected .error, got \(vm.state)")
            return
        }
        #expect(message == L("update.error.rate_limited"))
    }

    @Test
    func checkNoNetworkShowsLocalizedError() async {
        let vm = model(
            transport: UpdateStubTransport(error: URLError(.notConnectedToInternet)),
            currentVersion: "1.1.0")
        vm.checkForUpdates()
        await waitUntil {
            if case .error = vm.state { return true }
            return false
        }
        guard case let .error(message) = vm.state else {
            Issue.record("expected .error, got \(vm.state)")
            return
        }
        #expect(message == L("update.error.no_network"))
    }

    // MARK: - Error mapping (AC10) — direct unit coverage of every case

    @Test
    func errorMappingCoversEveryCase() {
        #expect(UpdateViewModel.message(for: UpdateError.noNetwork) == L("update.error.no_network"))
        #expect(UpdateViewModel.message(for: UpdateError.rateLimited) == L("update.error.rate_limited"))
        #expect(UpdateViewModel.message(for: UpdateError.noAsset) == L("update.error.no_asset"))
        #expect(UpdateViewModel.message(for: UpdateError.notWritable) == L("update.error.not_writable"))
        #expect(UpdateViewModel.message(for: UpdateError.extractionFailed) == L("update.error.extraction_failed"))
        #expect(UpdateViewModel.message(for: UpdateError.invalidBundle) == L("update.error.invalid_bundle"))
        #expect(UpdateViewModel.message(for: UpdateError.invalidResponse) == L("update.error.generic"))
        #expect(UpdateViewModel.message(for: UpdateError.server(status: 500)) == L("update.error.generic"))
        let installFailed = UpdateViewModel.message(for: UpdateError.installFailed("boom"))
        #expect(installFailed.contains("boom"))
    }

    // MARK: - installPendingRelease guards on no pending release

    @Test
    func installPendingNoOpsWithoutRelease() {
        let vm = model(
            transport: UpdateStubTransport(response: .stub(status: 200, json: stubReleaseJSON)),
            currentVersion: "1.1.0")
        // No check ran → no pending release → state must stay idle.
        vm.installPendingRelease()
        #expect(vm.state == .idle)
    }

    // MARK: - Fixture

    private let stubReleaseJSON = """
    {
      "tag_name": "v1.1.0",
      "assets": [
        { "name": "ExímIABar-1.1.0.zip", "browser_download_url": "https://example.com/ExímIABar-1.1.0.zip" }
      ]
    }
    """
}
