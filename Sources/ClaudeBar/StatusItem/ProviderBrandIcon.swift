import AppKit

/// Loads the Claude brand icon used by the F2 "brand icon + %" display mode (AC13).
///
/// Adapted from CodexBar's `ProviderBrandIcon` (Peter Steinberger, MIT), stripped to a single
/// provider: there is no multi-provider dispatch in exímIABar. The SVG ships in the app's
/// resource bundle (`Resources/ProviderIcon-claude.svg`, declared in `Package.swift`). The image
/// is loaded once, sized to 16×16, marked `isTemplate = true` so AppKit tints it with the menu-bar
/// label colour, and cached.
@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cached: NSImage?

    /// Lazily resolved resource bundle for the provider SVG. When running as a packaged `.app`,
    /// SwiftPM emits a `ClaudeBar_ClaudeBar.bundle`; in development `Bundle.module` works directly.
    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        if let bundleURL = Bundle.main.url(forResource: "ClaudeBar_ClaudeBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.main
    }()

    /// The 16×16 Claude template icon, or `nil` if the resource could not be loaded.
    static func image() -> NSImage? {
        if let cached { return cached }

        guard let bundle = resourceBundle,
              let url = bundle.url(forResource: "ProviderIcon-claude", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = size
        image.isTemplate = true
        cached = image
        return image
    }

    /// Test hook to clear the memoized image.
    static func resetCacheForTesting() {
        cached = nil
    }
}
