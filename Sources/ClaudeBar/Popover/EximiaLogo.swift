import AppKit

/// Loads the eximIA brand symbol (the two mirrored marks) shown in the popover header (v2.3.0).
///
/// The official symbol SVG (`Resources/eximia-symbol.svg`, monochrome `#231F20`) is loaded once and
/// marked `isTemplate = true`, so SwiftUI tints it with whatever accent the active theme supplies
/// (terracotta in classic, amber in meter). Same resource-bundle resolution as `ProviderBrandIcon`.
@MainActor
enum EximiaLogo {
    private static var cached: NSImage?

    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return Bundle.module }
        if let url = Bundle.main.url(forResource: "ClaudeBar_ClaudeBar", withExtension: "bundle"),
           let bundle = Bundle(url: url)
        {
            return bundle
        }
        return Bundle.main
    }()

    /// The eximIA symbol as a template image sized to `height` pt (aspect-correct), or `nil` if the
    /// resource is missing. The native viewBox is 120.4 × 136.01, so width follows from the aspect.
    static func image(height: CGFloat = 16) -> NSImage? {
        let image: NSImage
        if let cached {
            image = cached
        } else {
            guard let bundle = resourceBundle,
                  let url = bundle.url(forResource: "eximia-symbol", withExtension: "svg"),
                  let loaded = NSImage(contentsOf: url)
            else {
                return nil
            }
            loaded.isTemplate = true
            cached = loaded
            image = loaded
        }
        let aspect = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: height * aspect, height: height)
        return image
    }

    /// Test hook to clear the memoized image.
    static func resetCacheForTesting() {
        cached = nil
    }
}
