import AppKit
import ClaudeBarCore
import Testing
@testable import ClaudeBar

/// Tests for the stateless `IconRenderer` (EXB-1.2 AC3, AC5, AC10, AC12, AC14/15).
struct IconRendererTests {
    private func window(remaining: Double, windowMinutes: Int) -> RateWindow {
        RateWindow(utilization: 100 - remaining, resetsAt: nil, windowMinutes: windowMinutes)
    }

    /// AC3: the rendered image is an 18×18 pt template backed by a 36×36 px bitmap.
    @Test
    func rendersTemplateImageAtExpectedSize() {
        let image = IconRenderer.render(
            session: window(remaining: 87.5, windowMinutes: 300),
            weekly: window(remaining: 60, windowMinutes: 10080),
            isStale: false,
            hasError: false)

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))

        let rep = image.representations.first as? NSBitmapImageRep
        #expect(rep != nil)
        #expect(rep?.pixelsWide == 36)
        #expect(rep?.pixelsHigh == 36)
    }

    /// AC12: identical quantized state returns the *same* cached `NSImage` instance (no re-render).
    @Test
    func cacheReturnsSameInstanceForIdenticalState() {
        let session = window(remaining: 42.3, windowMinutes: 300)
        let weekly = window(remaining: 71.9, windowMinutes: 10080)

        let first = IconRenderer.render(session: session, weekly: weekly, isStale: false, hasError: false)
        let second = IconRenderer.render(session: session, weekly: weekly, isStale: false, hasError: false)

        #expect(first === second)
    }

    /// AC12: state quantized to 0.1% — a difference below the step shares a cache slot, while a
    /// difference above it does not.
    @Test
    func cacheQuantizesToTenthOfAPercent() {
        let weekly = window(remaining: 50, windowMinutes: 10080)
        // 42.30% and 42.34% both quantize to 423 → same instance.
        let a = IconRenderer.render(
            session: window(remaining: 42.30, windowMinutes: 300), weekly: weekly,
            isStale: false, hasError: false)
        let b = IconRenderer.render(
            session: window(remaining: 42.34, windowMinutes: 300), weekly: weekly,
            isStale: false, hasError: false)
        #expect(a === b)

        // 42.30% vs 42.50% differ by more than 0.1% → distinct instances.
        let c = IconRenderer.render(
            session: window(remaining: 42.50, windowMinutes: 300), weekly: weekly,
            isStale: false, hasError: false)
        #expect(a !== c)
    }

    /// AC7/AC8: stale and error states key the cache differently from the active state.
    @Test
    func staleAndErrorStatesAreDistinctCacheEntries() {
        let session = window(remaining: 80, windowMinutes: 300)
        let weekly = window(remaining: 80, windowMinutes: 10080)

        let active = IconRenderer.render(session: session, weekly: weekly, isStale: false, hasError: false)
        let stale = IconRenderer.render(session: session, weekly: weekly, isStale: true, hasError: false)
        let error = IconRenderer.render(session: session, weekly: weekly, isStale: false, hasError: true)

        #expect(active !== stale)
        #expect(active !== error)
        #expect(stale !== error)
    }

    /// AC10: a nil weekly window still renders successfully (dimmed bottom track).
    @Test
    func rendersWithAbsentWeekly() {
        let image = IconRenderer.render(
            session: window(remaining: 90, windowMinutes: 300),
            weekly: nil,
            isStale: false,
            hasError: false)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    /// AC5: extreme fills (0% and 100% remaining) render without crashing.
    @Test
    func rendersBoundaryFills() {
        let empty = IconRenderer.render(
            session: window(remaining: 0, windowMinutes: 300),
            weekly: window(remaining: 0, windowMinutes: 10080),
            isStale: false, hasError: false)
        let full = IconRenderer.render(
            session: window(remaining: 100, windowMinutes: 300),
            weekly: window(remaining: 100, windowMinutes: 10080),
            isStale: false, hasError: false)
        #expect(empty.size == NSSize(width: 18, height: 18))
        #expect(full.size == NSSize(width: 18, height: 18))
    }

    /// AC14/AC15: `render` is callable concurrently from background tasks without crashing or
    /// data races (the cache is internally locked). Run many concurrent renders over a spread of
    /// states and assert every call returns a valid image.
    @Test
    func renderIsConcurrencySafe() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let remaining = Double(i % 100)
                    let image = IconRenderer.render(
                        session: self.window(remaining: remaining, windowMinutes: 300),
                        weekly: self.window(remaining: 100 - remaining, windowMinutes: 10080),
                        isStale: i % 2 == 0,
                        hasError: i % 3 == 0)
                    return image.isTemplate && image.size == NSSize(width: 18, height: 18)
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
    }

    /// AC11/T5: the incident overlay image stub is always nil for P0/P1.
    @Test
    func incidentOverlayStubIsNil() {
        #expect(IconRenderer.renderIncidentOverlay(minor: true, major: false) == nil)
        #expect(IconRenderer.renderIncidentOverlay(minor: false, major: true) == nil)
    }
}
