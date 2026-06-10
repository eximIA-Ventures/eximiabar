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
            button.setAccessibilityTitle("exímIABar")
            button.toolTip = "exímIABar"
            button.target = self
            button.action = #selector(handleClick)
        }
    }

    /// Update the status item to reflect a new snapshot (or the empty placeholder when `nil`).
    ///
    /// Rendering is dispatched to a detached background task (off-main). When it completes, the
    /// image and optional title are applied on the main actor — and only if no newer update has
    /// since been requested.
    func update(snapshot: DisplaySnapshot?) {
        renderGeneration &+= 1
        let generation = renderGeneration
        let mode = settings.displayMode

        // Snapshot the immutable, Sendable values the renderer needs so nothing UI/main-actor
        // bound is captured by the detached task.
        let session = snapshot?.session
        let weekly = snapshot?.weekly
        let pace = snapshot?.pace
        let isStale = snapshot?.isStale ?? false
        let hasError = snapshot?.hasError ?? false

        switch mode {
        case .meterIcon:
            Task.detached(priority: .userInitiated) {
                let image = IconRenderer.render(
                    session: session,
                    weekly: weekly,
                    isStale: isStale,
                    hasError: hasError)
                await self.applyMeter(image: image, generation: generation)
            }

        case .brandIconPercent:
            // The brand icon and title both live on the main actor; build the text here and apply.
            let title = MenuBarDisplayText.displayText(session: session, pace: pace)
            applyBrand(title: title, generation: generation)
        }
    }

    private func applyMeter(image: NSImage, generation: UInt64) {
        guard generation == renderGeneration, let button = statusItem.button else { return }
        button.image = image
        button.title = ""
    }

    private func applyBrand(title: String?, generation: UInt64) {
        guard generation == renderGeneration, let button = statusItem.button else { return }
        button.image = ProviderBrandIcon.image()
        button.title = title ?? ""
    }

    @objc
    private func handleClick() {
        guard let button = statusItem.button else { return }
        onClick?(button)
    }
}
