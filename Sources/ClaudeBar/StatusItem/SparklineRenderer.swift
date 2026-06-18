import AppKit

/// Renders the compact menu-bar sparkline of recent session utilization (EXB-4.4 AC2).
///
/// Design — same anti-freeze contract as `IconRenderer` (EXB-1.2):
/// - **Stateless / pure per call.** No `@MainActor` state, no instance state — safe to call from a
///   background `Task.detached` (the drawing happens off-main; only the resulting `NSImage` is
///   handed back to the MainActor to assign to `button.image`).
/// - Output is a template image (`isTemplate = true`) drawn into an off-screen `NSBitmapImageRep`,
///   so AppKit tints it with `labelColor` automatically in light and dark mode — matching the meter
///   icon's appearance.
/// - Total size ≤ 32×18 pt (AC2 §5). The bitmap is 2× for crisp lines.
///
/// **Honest fallback (AC2 §6):** with ≤ 1 sample there is no slope to show, so a neutral flat line is
/// drawn at the vertical mid-point — never a crash, never an empty/blank image.
enum SparklineRenderer {
    /// The maximum number of trailing samples the sparkline plots (AC2 §4 — "últimas 6–8 amostras").
    /// `AppState` reads back at most this many session utilizations from the predictor.
    static let maxSamples = 8

    // MARK: Geometry

    /// Logical sparkline size in points (≤ 32×18, AC2 §5).
    static let outputSize = NSSize(width: 28, height: 14)
    private static let outputScale: CGFloat = 2
    /// Inset (pt) on every edge so the stroke never clips at the bitmap boundary.
    private static let inset: CGFloat = 1.5
    /// Line width (pt) of the plotted path.
    private static let lineWidth: CGFloat = 1.4
    /// Minimum dot/segment height (pt) so a near-zero run still reads as a line, not a gap.
    private static let minVisibleHeight: CGFloat = 1

    // MARK: Public API

    /// Render the sparkline for `samples` (utilization values 0–100, oldest-first) at `size`.
    ///
    /// - Parameters:
    ///   - samples: recent session utilizations, oldest-first. `[]` or a single value draws the
    ///     neutral flat line (AC2 §6). More than `maxSamples` are tail-trimmed.
    ///   - size: the logical image size; defaults to `outputSize`.
    /// - Returns: a template `NSImage` AppKit tints automatically.
    static func render(samples: [Double], size: NSSize = outputSize) -> NSImage {
        let trimmed = Array(samples.suffix(maxSamples))
        return renderImage(size: size) { rect in
            if trimmed.count <= 1 {
                drawFlatLine(in: rect)
            } else {
                drawSparkline(samples: trimmed, in: rect)
            }
        }
    }

    // MARK: Drawing

    /// A flat, mid-height neutral line — the "not enough data" state (AC2 §6).
    private static func drawFlatLine(in rect: CGRect) {
        let y = rect.midY
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + inset, y: y))
        path.line(to: CGPoint(x: rect.maxX - inset, y: y))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        // A dimmed tint for the neutral state so it reads as "idle", not as a real reading.
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    /// Plot `samples` (utilization 0–100) as a polyline. Y is scaled so the run's own max sits near
    /// the top of the plot area; a flat run collapses to a mid-height line.
    private static func drawSparkline(samples: [Double], in rect: CGRect) {
        let plot = rect.insetBy(dx: inset, dy: inset)
        guard plot.width > 0, plot.height > 0 else { return }

        // Scale Y by the run's own maximum (AC2 §4) so low-but-varying usage is still legible. Clamp
        // the denominator away from zero; a fully-flat run then renders at the mid-height baseline.
        let clamped = samples.map { min(100, max(0, $0)) }
        let maxValue = clamped.max() ?? 0
        let denom = maxValue > 0 ? maxValue : 1

        let count = clamped.count
        let stepX = count > 1 ? plot.width / CGFloat(count - 1) : 0

        let path = NSBezierPath()
        for (index, value) in clamped.enumerated() {
            let x = plot.minX + stepX * CGFloat(index)
            let normalized = maxValue > 0 ? CGFloat(value) / CGFloat(denom) : 0.5
            // Floor the visible height so a near-zero column still draws on the baseline.
            let height = max(minVisibleHeight, normalized * plot.height)
            let y = plot.minY + height
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.labelColor.setStroke()
        path.stroke()
    }

    // MARK: Bitmap context (mirrors IconRenderer.renderImage)

    /// Render a closure into a fresh 2× bitmap and return a template `NSImage`. All drawing happens in
    /// an off-screen `NSBitmapImageRep`, so the caller may be off-main.
    private static func renderImage(size: NSSize, _ draw: (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        let rect = CGRect(origin: .zero, size: size)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * outputScale),
            pixelsHigh: Int(size.height * outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = size
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.cgContext.setShouldAntialias(true)
                draw(rect)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            draw(rect)
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}
