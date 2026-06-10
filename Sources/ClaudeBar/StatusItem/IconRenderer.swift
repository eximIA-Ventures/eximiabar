import AppKit
import ClaudeBarCore

/// Renders the exímIABar menu-bar meter icon — a faithful, Claude-only port of CodexBar's
/// `IconRenderer` (Peter Steinberger, MIT). It draws the two-bar "crab" critter: a session bar
/// and a weekly bar with lateral arms, four legs, and vertical eye cutouts.
///
/// Design constraints (per EXB-1.2):
/// - **Stateless / pure per call.** No `@MainActor` state, no instance state. The only stored
///   state is the LRU image cache, which is internally locked and `Sendable`, so `render` is safe
///   to call from a background thread (anti-freeze: drawing happens off-main).
/// - Output is an 18×18 pt template image backed by a 36×36 px bitmap (2×). `isTemplate = true`
///   lets AppKit tint it with `labelColor` automatically in light and dark mode.
/// - All coordinates are pixels in the 36×36 bitmap, snapped to the pixel grid; bars have
///   corner radius 0 (Claude blocky style).
enum IconRenderer {
    // MARK: Geometry

    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2
    /// Canvas side in pixels (36).
    private static let canvasPx = Int(outputSize.width * outputScale)

    /// Bar width in pixels (15 pt at 2×) — uses the slot well without touching the edges.
    private static let barWidthPx = 30
    /// Horizontal origin so the bar is centred in the 36 px canvas → (36 − 30) / 2 = 3.
    private static let barXPx = (canvasPx - barWidthPx) / 2

    /// Session bar: origin (3, 19), size 30×12 px.
    private static let sessionRectPx = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
    /// Weekly bar: origin (3, 5), size 30×8 px.
    private static let weeklyRectPx = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)

    private struct PixelGrid {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat { CGFloat(px) / self.scale }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }
    }

    private static let grid = PixelGrid(scale: outputScale)

    private struct RectPx: Hashable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        var midXPx: Int { self.x + self.w / 2 }

        func rect() -> CGRect { IconRenderer.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h) }
    }

    // MARK: LRU cache (AC12)

    private struct IconCacheKey: Hashable {
        let session: Int
        let weekly: Int
        let stale: Bool
        let error: Bool
    }

    /// Thread-safe LRU store. `@unchecked Sendable` is sound because every access is guarded by
    /// `lock`, mirroring the reference implementation.
    private final class IconCacheStore: @unchecked Sendable {
        private var cache: [IconCacheKey: NSImage] = [:]
        private var order: [IconCacheKey] = []
        private let lock = NSLock()

        func cachedIcon(for key: IconCacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let image = self.cache[key] else { return nil }
            if let idx = self.order.firstIndex(of: key) {
                self.order.remove(at: idx)
                self.order.append(key)
            }
            return image
        }

        func storeIcon(_ image: NSImage, for key: IconCacheKey, limit: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.cache[key] = image
            self.order.removeAll { $0 == key }
            self.order.append(key)
            while self.order.count > limit {
                let oldest = self.order.removeFirst()
                self.cache.removeValue(forKey: oldest)
            }
        }
    }

    private static let iconCacheStore = IconCacheStore()
    private static let iconCacheLimit = 64

    /// Quantize a percentage (0–100) to 0.1% steps for the cache key; `nil` → a sentinel of -1.
    private static func quantizedPercent(_ value: Double?) -> Int {
        guard let value else { return -1 }
        return Int((value * 10).rounded())
    }

    // MARK: Public API (AC5, AC6, AC10, AC12, AC14)

    /// Render the meter icon for the given windows and state.
    ///
    /// - Parameters:
    ///   - session: the 5-hour session window (its `remaining` drives the top bar fill).
    ///   - weekly: the 7-day window; `nil` renders the bottom bar dimmed (AC10).
    ///   - isStale: when `true`, alphas are reduced to the stale palette (AC7).
    ///   - hasError: when `true`, the icon dims to the stale palette too (AC8).
    /// - Returns: an `NSImage` template tinted automatically by AppKit.
    static func render(
        session: RateWindow?,
        weekly: RateWindow?,
        isStale: Bool,
        hasError: Bool) -> NSImage
    {
        // Error dims to the stale alphas (AC8): treat error like stale for the palette.
        let dimmed = isStale || hasError

        let key = IconCacheKey(
            session: quantizedPercent(session?.remaining),
            weekly: quantizedPercent(weekly?.remaining),
            stale: isStale,
            error: hasError)

        if let cached = iconCacheStore.cachedIcon(for: key) {
            return cached
        }

        let image = renderImage {
            drawMeter(
                sessionRemaining: session?.remaining,
                weeklyRemaining: weekly?.remaining,
                hasWeekly: weekly != nil,
                dimmed: dimmed)
        }
        iconCacheStore.storeIcon(image, for: key, limit: iconCacheLimit)
        return image
    }

    // MARK: Drawing

    /// Draw the two bars and the crab adornments into the current graphics context.
    private static func drawMeter(
        sessionRemaining: Double?,
        weeklyRemaining: Double?,
        hasWeekly: Bool,
        dimmed: Bool)
    {
        let baseFill = NSColor.labelColor
        // Visual layer alphas (AC6 active / AC7 stale).
        let trackFillAlpha: CGFloat = dimmed ? 0.18 : 0.28
        let trackStrokeAlpha: CGFloat = dimmed ? 0.28 : 0.44
        let progressColor = baseFill.withAlphaComponent(dimmed ? 0.55 : 1.0)

        // Session bar (top) carries the crab adornments.
        drawBar(
            rectPx: sessionRectPx,
            remaining: sessionRemaining,
            baseFill: baseFill,
            progressColor: progressColor,
            trackFillAlpha: trackFillAlpha,
            trackStrokeAlpha: trackStrokeAlpha,
            alpha: 1.0,
            addCrab: true)

        if hasWeekly {
            drawBar(
                rectPx: weeklyRectPx,
                remaining: weeklyRemaining,
                baseFill: baseFill,
                progressColor: progressColor,
                trackFillAlpha: trackFillAlpha,
                trackStrokeAlpha: trackStrokeAlpha,
                alpha: 1.0,
                addCrab: false)
        } else {
            // Weekly absent (AC10): render the bottom bar as a dimmed empty track.
            drawBar(
                rectPx: weeklyRectPx,
                remaining: nil,
                baseFill: baseFill,
                progressColor: progressColor,
                trackFillAlpha: trackFillAlpha,
                trackStrokeAlpha: trackStrokeAlpha,
                alpha: 0.45,
                addCrab: false)
        }

        // Incident overlay shape is present but disabled for P0/P1 (AC11).
        drawIncidentOverlay(minor: false, major: false)
    }

    /// Draw a single bar: track fill (α0.28), 1 pt stroke (α0.44), progress fill (α1.0), and —
    /// for the session bar — the crab cutouts (arms, legs, eyes). Mirrors the reference Claude
    /// branch, with all twists/blink/face removed.
    // swiftlint:disable:next function_body_length function_parameter_count
    private static func drawBar(
        rectPx: RectPx,
        remaining: Double?,
        baseFill: NSColor,
        progressColor: NSColor,
        trackFillAlpha: CGFloat,
        trackStrokeAlpha: CGFloat,
        alpha: CGFloat,
        addCrab: Bool)
    {
        let rect = rectPx.rect()
        // Corner radius 0 — Claude blocky style (AC4).
        let trackPath = NSBezierPath(rect: rect)

        baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
        trackPath.fill()

        // Crisp outline: stroke an inset path so the 1 pt (2 px) line stays within pixel bounds.
        let strokeWidthPx = 2 // 1 pt == 2 px at 2×
        let insetPx = strokeWidthPx / 2
        let strokeRect = grid.rect(
            x: rectPx.x + insetPx,
            y: rectPx.y + insetPx,
            w: max(0, rectPx.w - insetPx * 2),
            h: max(0, rectPx.h - insetPx * 2))
        let strokePath = NSBezierPath(rect: strokeRect)
        strokePath.lineWidth = CGFloat(strokeWidthPx) / outputScale
        baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
        strokePath.stroke()

        // Progress fill: clip to the bar, paint a left-to-right rect (AC5 — proportional fill).
        if let remaining {
            let clamped = max(0, min(remaining / 100, 1))
            let fillWidthPx = max(0, min(rectPx.w, Int((CGFloat(rectPx.w) * CGFloat(clamped)).rounded())))
            if fillWidthPx > 0 {
                NSGraphicsContext.current?.cgContext.saveGState()
                trackPath.addClip()
                progressColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(rect: grid.rect(
                    x: rectPx.x,
                    y: rectPx.y,
                    w: fillWidthPx,
                    h: rectPx.h)).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }

        guard addCrab else { return }

        // Crab adornments (AC9). Arms/legs are filled; eyes are `.clear` cutouts ("holes").
        let ctx = NSGraphicsContext.current?.cgContext
        progressColor.withAlphaComponent(alpha).setFill()

        // Arms/claws: 3 px wide mid-height protrusions either side of the bar.
        let armWidthPx = 3
        let armHeightPx = max(0, rectPx.h - 6)
        let armYPx = rectPx.y + 3
        let leftArm = grid.rect(x: rectPx.x - armWidthPx, y: armYPx, w: armWidthPx, h: armHeightPx)
        let rightArm = grid.rect(x: rectPx.x + rectPx.w, y: armYPx, w: armWidthPx, h: armHeightPx)
        NSBezierPath(rect: leftArm).fill()
        NSBezierPath(rect: rightArm).fill()

        // Legs: 4 little 2×3 px pixels underneath the bar.
        let legCount = 4
        let legWidthPx = 2
        let legHeightPx = 3
        let legYPx = rectPx.y - legHeightPx
        let stepPx = max(1, rectPx.w / (legCount + 1))
        for idx in 0..<legCount {
            let cx = rectPx.x + stepPx * (idx + 1)
            let leg = grid.rect(x: cx - legWidthPx / 2, y: legYPx, w: legWidthPx, h: legHeightPx)
            NSBezierPath(rect: leg).fill()
        }

        // Eyes: tall 2×5 px vertical cutouts near the top, cut with `.clear` (transparent holes).
        let eyeWidthPx = 2
        let eyeHeightPx = 5
        let eyeOffsetPx = 6
        let eyeYPx = rectPx.y + rectPx.h - eyeHeightPx - 2
        ctx?.saveGState()
        ctx?.setShouldAntialias(false)
        ctx?.clear(grid.rect(
            x: rectPx.midXPx - eyeOffsetPx - eyeWidthPx / 2,
            y: eyeYPx,
            w: eyeWidthPx,
            h: eyeHeightPx))
        ctx?.clear(grid.rect(
            x: rectPx.midXPx + eyeOffsetPx - eyeWidthPx / 2,
            y: eyeYPx,
            w: eyeWidthPx,
            h: eyeHeightPx))
        ctx?.restoreGState()
    }

    // MARK: Incident overlay (AC11 — shapes present, toggled off for P0/P1)

    /// Draw the incident overlay glyph. For P0/P1 callers always pass `false`/`false`, so nothing
    /// is drawn; the shape code is kept so a later story can toggle it on without a re-port.
    /// - minor: a 4 pt filled circle in the lower-right corner.
    /// - major: a "!" glyph (a 2×6 rect plus a 2×2 dot).
    private static func drawIncidentOverlay(minor: Bool, major: Bool) {
        let color = NSColor.labelColor
        color.setFill()
        if major {
            // "!" glyph: a 2×6 rect (the stem) plus a 2×2 dot beneath it.
            let lineRect = snapRect(x: outputSize.width - 6, y: 4, width: 2.0, height: 6)
            NSBezierPath(rect: lineRect).fill()
            let dotRect = snapRect(x: outputSize.width - 6, y: 2, width: 2.0, height: 2.0)
            NSBezierPath(ovalIn: dotRect).fill()
        } else if minor {
            // 4 pt filled circle in the lower-right corner.
            let size: CGFloat = 4
            let rect = snapRect(x: outputSize.width - size - 2, y: 2, width: size, height: size)
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Stub for incident overlay imagery (T5). Always returns `nil` for P0/P1 — the overlay is
    /// composited inline by `drawIncidentOverlay` once a future story enables it.
    static func renderIncidentOverlay(minor: Bool, major: Bool) -> NSImage? {
        nil
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * outputScale).rounded() / outputScale
    }

    private static func snapRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: snap(x), y: snap(y), width: snap(width), height: snap(height))
    }

    // MARK: Bitmap context (AC3, AC15)

    /// Render a closure into a fresh 36×36 px bitmap and return an 18×18 pt template `NSImage`.
    /// All drawing happens here in an off-screen `NSBitmapImageRep`; the caller may be off-main.
    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: outputSize)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outputSize.width * outputScale),
            pixelsHigh: Int(outputSize.height * outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = outputSize // points
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.cgContext.setShouldAntialias(true)
                ctx.cgContext.interpolationQuality = .none
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Fallback if the bitmap rep allocation fails for any reason.
            image.lockFocus()
            draw()
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}
