import Foundation

/// Canned GitHub `releases/latest` payloads for EXB-2.4 ``UpdateChecker`` tests.
///
/// These mirror the real `https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest`
/// shape (only the fields the decoder reads). The live flow is validated for real in EXB-2.5; here
/// we exercise every parse/compare branch deterministically and offline.
enum GitHubReleaseFixtures {
    /// A normal v1.1.0 release with a single `.zip` asset (the canonical happy path).
    static let v1_1_0 = """
    {
      "tag_name": "v1.1.0",
      "name": "v1.1.0 — Onda 4",
      "assets": [
        {
          "name": "ExímIABar-1.1.0.zip",
          "browser_download_url": "https://github.com/eximIA-Ventures/eximiabar/releases/download/v1.1.0/ExímIABar-1.1.0.zip"
        }
      ]
    }
    """

    /// A newer v1.2.0 release — used to assert `.available` against a 1.1.0 local version.
    static let v1_2_0 = """
    {
      "tag_name": "v1.2.0",
      "assets": [
        {
          "name": "ExímIABar-1.2.0.zip",
          "browser_download_url": "https://github.com/eximIA-Ventures/eximiabar/releases/download/v1.2.0/ExímIABar-1.2.0.zip"
        }
      ]
    }
    """

    /// A release whose only asset is a non-`.zip` file → triggers `.noAsset`.
    static let noZipAsset = """
    {
      "tag_name": "v1.1.0",
      "assets": [
        { "name": "ExímIABar-1.1.0.dmg", "browser_download_url": "https://example.com/x.dmg" }
      ]
    }
    """

    /// A release with an empty assets array → triggers `.noAsset`.
    static let emptyAssets = """
    {
      "tag_name": "v1.1.0",
      "assets": []
    }
    """

    /// A tag without the leading "v" — the stripper must still parse it.
    static let unprefixedTag = """
    {
      "tag_name": "1.3.0",
      "assets": [
        { "name": "ExímIABar-1.3.0.zip", "browser_download_url": "https://example.com/a.zip" }
      ]
    }
    """

    /// Two zip assets — the first should be selected (AC5 "first asset ending in .zip").
    static let multipleZipAssets = """
    {
      "tag_name": "v1.1.0",
      "assets": [
        { "name": "first.zip",  "browser_download_url": "https://example.com/first.zip" },
        { "name": "second.zip", "browser_download_url": "https://example.com/second.zip" }
      ]
    }
    """

    /// Malformed payload (missing `tag_name`) → `.invalidResponse`.
    static let missingTag = """
    { "assets": [] }
    """

    static func data(_ json: String) -> Data { Data(json.utf8) }
}
