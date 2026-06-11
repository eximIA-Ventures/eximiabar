import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-2.4 AC2 / AC3 / AC5 / AC10: GitHub release fetch, semver decision, and error mapping.
///
/// All branches are exercised offline via `StubTransport` + fixture JSON. The real network flow is
/// validated by hand in EXB-2.5.
@Suite
struct UpdateCheckerTests {
    private func checker(_ transport: HTTPTransport) -> UpdateChecker {
        UpdateChecker(transport: transport, endpoint: UpdateChecker.defaultLatestReleaseURL)
    }

    // MARK: - Parse (AC3 / AC5)

    @Test
    func parsesStandardReleaseStrippingVPrefix() throws {
        let release = try UpdateChecker.parseRelease(
            GitHubReleaseFixtures.data(GitHubReleaseFixtures.v1_1_0))
        #expect(release.version == "1.1.0")
        #expect(release.assetName == "ExímIABar-1.1.0.zip")
        // `URL` percent-encodes the `í`; the decoded last path component round-trips back to the
        // original asset filename, which is the property the installer actually uses.
        #expect(release.downloadURL.lastPathComponent == "ExímIABar-1.1.0.zip")
    }

    @Test
    func parsesUnprefixedTag() throws {
        let release = try UpdateChecker.parseRelease(
            GitHubReleaseFixtures.data(GitHubReleaseFixtures.unprefixedTag))
        #expect(release.version == "1.3.0")
    }

    @Test
    func selectsFirstZipAsset() throws {
        let release = try UpdateChecker.parseRelease(
            GitHubReleaseFixtures.data(GitHubReleaseFixtures.multipleZipAssets))
        #expect(release.assetName == "first.zip")
    }

    @Test
    func noZipAssetThrowsNoAsset() {
        #expect(throws: UpdateError.noAsset) {
            _ = try UpdateChecker.parseRelease(
                GitHubReleaseFixtures.data(GitHubReleaseFixtures.noZipAsset))
        }
    }

    @Test
    func emptyAssetsThrowsNoAsset() {
        #expect(throws: UpdateError.noAsset) {
            _ = try UpdateChecker.parseRelease(
                GitHubReleaseFixtures.data(GitHubReleaseFixtures.emptyAssets))
        }
    }

    @Test
    func missingTagThrowsInvalidResponse() {
        #expect(throws: UpdateError.invalidResponse) {
            _ = try UpdateChecker.parseRelease(
                GitHubReleaseFixtures.data(GitHubReleaseFixtures.missingTag))
        }
    }

    @Test
    func malformedJSONThrowsInvalidResponse() {
        #expect(throws: UpdateError.invalidResponse) {
            _ = try UpdateChecker.parseRelease(Data("not json".utf8))
        }
    }

    // MARK: - Check decision (AC3)

    @Test
    func newerRemoteReturnsAvailable() async throws {
        let transport = StubTransport(response: HTTPResponse.make(
            status: 200, json: GitHubReleaseFixtures.v1_2_0))
        let result = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        guard case let .available(release) = result else {
            Issue.record("expected .available, got \(result)")
            return
        }
        #expect(release.version == "1.2.0")
    }

    @Test
    func sameVersionReturnsUpToDate() async throws {
        let transport = StubTransport(response: HTTPResponse.make(
            status: 200, json: GitHubReleaseFixtures.v1_1_0))
        let result = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        #expect(result == .upToDate)
    }

    @Test
    func olderRemoteReturnsUpToDate() async throws {
        let transport = StubTransport(response: HTTPResponse.make(
            status: 200, json: GitHubReleaseFixtures.v1_1_0))
        let result = try await checker(transport).checkForUpdates(currentVersion: "1.5.0")
        #expect(result == .upToDate)
    }

    // MARK: - HTTP error mapping (AC10)

    @Test
    func http403MapsToRateLimited() async {
        let transport = StubTransport(response: HTTPResponse.make(status: 403))
        await #expect(throws: UpdateError.rateLimited) {
            _ = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        }
    }

    @Test
    func http429MapsToRateLimited() async {
        let transport = StubTransport(response: HTTPResponse.make(status: 429))
        await #expect(throws: UpdateError.rateLimited) {
            _ = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        }
    }

    @Test
    func http500MapsToServerError() async {
        let transport = StubTransport(response: HTTPResponse.make(status: 500))
        await #expect(throws: UpdateError.server(status: 500)) {
            _ = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        }
    }

    @Test
    func networkFailureMapsToNoNetwork() async {
        let transport = StubTransport(error: URLError(.notConnectedToInternet))
        await #expect(throws: UpdateError.noNetwork) {
            _ = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        }
    }

    @Test
    func dnsFailureMapsToNoNetwork() async {
        let transport = StubTransport(error: URLError(.cannotFindHost))
        await #expect(throws: UpdateError.noNetwork) {
            _ = try await checker(transport).checkForUpdates(currentVersion: "1.1.0")
        }
    }
}
