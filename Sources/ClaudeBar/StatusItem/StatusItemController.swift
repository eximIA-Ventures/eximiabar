import AppKit
import ClaudeBarCore

/// Owns the menu-bar `NSStatusItem` and keeps its button image in sync with the latest
/// `DisplaySnapshot`.
///
/// Anti-freeze contract (AC15): the actual drawing is done by the stateless `IconRenderer` on a
/// background task; only the final `button.image` / `button.title` assignment happens on the main
/// actor. The controller itself is `@MainActor` because every property it touches is UI state.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let settings: SettingsStore

    /// Invoked when the user clicks the status item, passing the button to anchor the popover
    /// (`NSPanel`) to. EXB-1.3 wires this to `UsagePanelController.toggle(near:)`.
    var onClick: (@MainActor (NSStatusBarButton) -> Void)?

    /// The status-item button, exposed so the popover can anchor to it.
    var button: NSStatusBarButton? { self.statusItem.button }

    /// Monotonic token so a slow background render can't clobber a newer one (last-writer-wins).
    private var renderGeneration: UInt64 = 0

    init(statusBar: NSStatusBar = .system, settings: SettingsStore) {
        self.settings = settings
        // AC2: variable length so the brand-icon-plus-text mode can grow.
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // AC3/AC2: render the template at 1:1, no resampling (crisper edges).
            button.imageScaling = .scaleNone
            button.setAccessibilityTitle(L("statusitem.tooltip"))
            button.toolTip = L("statusitem.tooltip")
            button.target = self
            button.action = #selector(handleClick)
        }
    }

    /// Update the status item to reflect a new snapshot (or the empty placeholder when `nil`).
    ///
    /// Rendering is dispatched to a detached background task (off-main, AC3 §7). When it completes,
    /// the image and optional title are applied on the main actor — and only if no newer update has
    /// since been requested.
    ///
    /// Two orthogonal axes drive the result: `displayMode` picks the *icon* (meter vs brand), and
    /// `menuBarContent` (EXB-4.4 AC1) picks what renders *next to* it (nothing / percent / time-until-
    /// reset / today's cost / a sparkline). Text cases use `button.title`; the sparkline case
    /// composites icon + sparkline into a single image off-main (AC3 §8).
    func update(snapshot: DisplaySnapshot?) {
        renderGeneration &+= 1
        let generation = renderGeneration
        let mode = settings.displayMode
        let content = settings.menuBarContent

        // Snapshot the immutable, Sendable values the renderer needs so nothing UI/main-actor
        // bound is captured by the detached task.
        let session = snapshot?.session
        let weekly = snapshot?.weekly
        let pace = snapshot?.pace
        let cost = snapshot?.cost
        let isStale = snapshot?.isStale ?? false
        let hasError = snapshot?.hasError ?? false
        let sparklineSamples = snapshot?.sparklineSamples ?? []

        // The brand icon lives on the main actor; resolve it here so the detached task only carries a
        // Sendable `NSImage` (or `nil`) into its compositing step.
        let brandIcon: NSImage? = mode == .brandIconPercent ? ProviderBrandIcon.image() : nil

        // The trailing text for the text-bearing content cases (AC1). `nil` → icon alone.
        let trailingText: String? = switch content {
        case .none, .sparkline: nil
        case .percentRemaining:
            // Preserve the F2 brand-mode pace suffix when the brand icon is active; otherwise the
            // plain remaining percentage.
            mode == .brandIconPercent
                ? MenuBarDisplayText.displayText(session: session, pace: pace)
                : MenuBarContentText.percentRemaining(session: session)
        case .timeUntilReset:
            MenuBarContentText.timeUntilReset(session: session)
        case .costToday:
            MenuBarContentText.costToday(cost: cost)
        }

        Task.detached(priority: .userInitiated) {
            // Resolve the icon off-main where possible. The meter is rendered in the detached task;
            // the brand icon was resolved on the main actor above and is passed through.
            let icon: NSImage? = mode == .meterIcon
                ? IconRenderer.render(
                    session: session,
                    weekly: weekly,
                    isStale: isStale,
                    hasError: hasError)
                : brandIcon

            let image: NSImage?
            if content == .sparkline {
                // Composite the icon and a fresh sparkline into one image (AC2/AC3 §8).
                let sparkline = SparklineRenderer.render(samples: sparklineSamples)
                image = Self.composite(icon: icon, trailing: sparkline)
            } else {
                image = icon
            }
            await self.apply(image: image, title: trailingText, generation: generation)
        }
    }

    private func apply(image: NSImage?, title: String?, generation: UInt64) {
        guard generation == renderGeneration, let button = statusItem.button else { return }
        button.image = image
        button.imagePosition = (title?.isEmpty == false) ? .imageLeading : .imageOnly
        button.title = title ?? ""
    }

    /// Lay an `icon` and a `trailing` image side by side into a single template image, vertically
    /// centred with a small gap. Used for the `.sparkline` content case so the one `button.image`
    /// slot carries both glyphs. Returns `trailing` alone when there is no icon, and `icon` alone
    /// when there is no trailing image.
    ///
    /// Drawing goes through an off-screen `NSBitmapImageRep` (the same off-main-safe pattern as
    /// `IconRenderer`/`SparklineRenderer`) rather than `NSImage.lockFocus`, which is main-thread
    /// affine — so this is safe to call from the detached render task (anti-freeze, AC3 §8).
    nonisolated static func composite(icon: NSImage?, trailing: NSImage?) -> NSImage? {
        guard let trailing else { return icon }
        guard let icon else { return trailing }

        let gap: CGFloat = 3
        let scale: CGFloat = 2
        let width = icon.size.width + gap + trailing.size.width
        let height = max(icon.size.height, trailing.size.height)
        let size = NSSize(width: width, height: height)

        let combined = NSImage(size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return icon
        }
        rep.size = size
        combined.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let iconY = (height - icon.size.height) / 2
            icon.draw(
                in: CGRect(x: 0, y: iconY, width: icon.size.width, height: icon.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0)
            let trailingY = (height - trailing.size.height) / 2
            trailing.draw(
                in: CGRect(
                    x: icon.size.width + gap,
                    y: trailingY,
                    width: trailing.size.width,
                    height: trailing.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        combined.isTemplate = true
        return combined
    }

    @objc
    private func handleClick() {
        guard let button = statusItem.button else { return }
        onClick?(button)
    }
}
