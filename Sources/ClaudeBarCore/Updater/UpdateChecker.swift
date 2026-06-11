import Foundation

/// Errors surfaced by the update pipeline. Raw, transport-agnostic causes are mapped to these by
/// ``UpdateChecker`` (network/HTTP) and ``ClaudeBarCore/SemanticVersion`` (parse). The app layer maps
/// each case to a localized message for the About-pane error state (EXB-2.4 AC10).
public enum UpdateError: Error, Equatable, Sendable {
    /// No network / DNS failure (AC10 → "No network connection.").
    case noNetwork
    /// GitHub API returned 403/429 — rate limited (AC10 → "Rate limited. Try again later.").
    case rateLimited
    /// The latest release carries no `.zip` asset (AC10 → "No downloadable asset found…").
    case noAsset
    /// The GitHub API response could not be decoded (malformed JSON / missing `tag_name`).
    case invalidResponse
    /// An unexpected HTTP status (anything not 200 / 403 / 429).
    case server(status: Int)
    /// The downloaded archive failed to extract (AC10 → "Failed to extract update.").
    case extractionFailed
    /// The extracted bundle is structurally invalid (AC7 → "Downloaded bundle is invalid.").
    case invalidBundle
    /// The running app lives in a read-only location (AC10 → "Cannot update: app location…").
    case notWritable
    /// The install step (remove/move/chmod/codesign) failed.
    case installFailed(String)
}

/// One published GitHub release, reduced to the fields the updater needs (AC2/AC3/AC5).
public struct ReleaseInfo: Equatable, Sendable {
    /// Semver string with the leading `"v"` already stripped (e.g. `"1.1.0"`).
    public let version: String
    /// `browser_download_url` of the first `.zip` asset.
    public let downloadURL: URL
    /// The asset filename (e.g. `"ExímIABar-1.1.0.zip"`).
    public let assetName: String

    public init(version: String, downloadURL: URL, assetName: String) {
        self.version = version
        self.downloadURL = downloadURL
        self.assetName = assetName
    }
}

/// Outcome of an update check (AC4 drives the UI from this).
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
}

/// Checks the GitHub Releases API for a newer build (EXB-2.4 AC2 / AC3 / AC10).
///
/// An `actor` so the (off-main-thread) network call and the small amount of decode state are
/// serialized without locks. It owns only an `HTTPTransport` and a few immutable config values, so
/// it is trivially `Sendable`. The actual `URLSession` work happens inside the injected transport;
/// tests supply a `StubTransport` to exercise every branch without touching the network (mirrors how
/// ``UsageFetcher`` is tested).
///
/// **Anti-freeze (EPIC-EXB):** the only I/O is `transport.send(_:)`, which is `async` and runs on the
/// cooperative pool, never on `MainActor`. No `Data(contentsOf:)`, no synchronous parse on the main
/// thread.
public actor UpdateChecker {
    /// Default GitHub API endpoint for the latest release. Configurable so EXB-2.5 can validate
    /// against the real repo and tests can point at a stub — see the spawn brief's "URL as a
    /// configurable constant" requirement.
    public static let defaultLatestReleaseURL = URL(
        string: "https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest")!

    private let transport: HTTPTransport
    private let endpoint: URL
    private let log = CoreLog.logger(CoreLog.Category.http)

    public init(
        transport: HTTPTransport = HTTPClient(),
        endpoint: URL = UpdateChecker.defaultLatestReleaseURL)
    {
        self.transport = transport
        self.endpoint = endpoint
    }

    /// Fetch the latest release and compare it against `currentVersion` (AC2/AC3).
    ///
    /// - Parameter currentVersion: usually `CFBundleShortVersionString`. Passed in (not read here)
    ///   so this stays in the UI-free core and is fully unit-testable.
    /// - Returns: `.available` if the remote semver is strictly newer, else `.upToDate`.
    public func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        let response = try await fetchLatestRelease(currentVersion: currentVersion)

        switch response.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateError.rateLimited
        default:
            throw UpdateError.server(status: response.statusCode)
        }

        let release = try Self.parseRelease(response.data)

        if SemanticVersion.isNewer(remote: release.version, than: currentVersion) {
            return .available(release)
        }
        return .upToDate
    }

    // MARK: - Networking

    private func fetchLatestRelease(currentVersion: String) async throws -> HTTPResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // AC2: identify the client as `exímIABar/{version}`.
        request.setValue("exímIABar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            return try await transport.send(request)
        } catch let urlError as URLError {
            log.error("Update check transport error: \(urlError.code.rawValue, privacy: .public)")
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost, .timedOut:
                throw UpdateError.noNetwork
            default:
                throw UpdateError.noNetwork
            }
        }
    }

    // MARK: - Parsing (AC3 / AC5 / AC10 no-asset)

    /// Decode the GitHub `releases/latest` payload into a ``ReleaseInfo``.
    ///
    /// `internal` (not private) so `UpdateCheckerTests` can exercise the decode/no-asset logic
    /// against fixture JSON without standing up a transport.
    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        let decoded: GitHubRelease
        do {
            decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidResponse
        }

        let rawTag = decoded.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTag.isEmpty else { throw UpdateError.invalidResponse }
        // AC3: strip a single leading "v" (handles both "v1.1.0" and "1.1.0").
        let version = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag

        // AC5: first asset whose name ends in ".zip".
        guard let asset = decoded.assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip")
        }), let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.noAsset
        }

        return ReleaseInfo(version: version, downloadURL: url, assetName: asset.name)
    }
}

// MARK: - GitHub API DTOs

/// Minimal decodable mirror of the GitHub `releases/latest` response (AC2 Dev Notes shape).
private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
