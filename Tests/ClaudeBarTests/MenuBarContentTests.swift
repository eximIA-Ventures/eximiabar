import AppKit
import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

/// Tests for EXB-4.4: the `MenuBarContent` / `HotkeyBinding` model, the sparkline renderer's
/// fallbacks, the trailing-text helpers, and the new `SettingsStore` persistence.
@MainActor
struct MenuBarContentTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "exb.menubar.\(UUID().uuidString)")!
    }

    // MARK: - AC6 required: menuBarContentRoundtrip (Codable)

    @Test
    func menuBarContentRoundtrip() throws {
        for content in MenuBarContent.allCases {
            let data = try JSONEncoder().encode(content)
            let decoded = try JSONDecoder().decode(MenuBarContent.self, from: data)
            #expect(decoded == content)
        }
        // Raw values are the stable persisted form — assert they are the documented strings.
        #expect(MenuBarContent.none.rawValue == "none")
        #expect(MenuBarContent.percentRemaining.rawValue == "percentRemaining")
        #expect(MenuBarContent.timeUntilReset.rawValue == "timeUntilReset")
        #expect(MenuBarContent.costToday.rawValue == "costToday")
        #expect(MenuBarContent.sparkline.rawValue == "sparkline")
        #expect(MenuBarContent.allCases.count == 5)
    }

    // MARK: - AC6 required: hotkeyBindingCodable

    @Test
    func hotkeyBindingCodable() throws {
        let binding = HotkeyBinding(modifiers: [.option, .command], keyCode: KeyCodes.c)
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        #expect(decoded == binding)
        // The decoded modifier flags survive the round-trip as the device-independent set.
        #expect(decoded.modifierFlags == [.option, .command])
        #expect(decoded.keyCodeValue == KeyCodes.c)
        // The default binding is the documented ⌥⌘C.
        #expect(HotkeyBinding.defaultBinding.modifierFlags == [.option, .command])
        #expect(HotkeyBinding.defaultBinding.keyCodeValue == KeyCodes.c)
        #expect(HotkeyBinding.defaultBinding.displayString == "⌥⌘C")
    }

    /// Capture-time pollution (Caps Lock, keypad bit) must not change the stored modifiers.
    @Test
    func hotkeyBindingNormalizesModifiers() {
        let polluted: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .numericPad]
        let binding = HotkeyBinding(modifiers: polluted, keyCode: 0)
        #expect(binding.modifierFlags == [.command, .shift])
    }

    // MARK: - AC6 required: sparklineEmptyFallback (empty → flat line, no crash)

    @Test
    func sparklineEmptyFallback() {
        let image = SparklineRenderer.render(samples: [])
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        // A single point also collapses to the neutral flat line.
        let one = SparklineRenderer.render(samples: [42])
        #expect(one.isTemplate)
        #expect(one.size.width > 0)
    }

    // MARK: - AC6 required: sparklineMinPoints (2 points → no crash)

    @Test
    func sparklineMinPoints() {
        let two = SparklineRenderer.render(samples: [10, 90])
        #expect(two.isTemplate)
        #expect(two.size.width > 0)
        #expect(two.size.height > 0)

        // A full run, an all-equal run, and out-of-range values must all render without crashing.
        let full = SparklineRenderer.render(samples: [5, 20, 35, 50, 65, 80, 95, 100])
        #expect(full.size.width > 0)
        let flat = SparklineRenderer.render(samples: [50, 50, 50, 50])
        #expect(flat.size.width > 0)
        let outOfRange = SparklineRenderer.render(samples: [-10, 0, 150, 50])
        #expect(outOfRange.size.width > 0)
        // More than the max is tail-trimmed, not crashed.
        let many = SparklineRenderer.render(samples: Array(stride(from: 0.0, to: 100.0, by: 1.0)))
        #expect(many.size.width > 0)
    }

    @Test
    func sparklineRespectsSizeBudget() {
        // AC2 §5 — total size ≤ 32×18 pt.
        #expect(SparklineRenderer.outputSize.width <= 32)
        #expect(SparklineRenderer.outputSize.height <= 18)
    }

    // MARK: - Trailing-text helpers (AC1)

    @Test
    func percentRemainingText() {
        let session = RateWindow(utilization: 13, resetsAt: nil, windowMinutes: 300)
        #expect(MenuBarContentText.percentRemaining(session: session) == "87%")
        #expect(MenuBarContentText.percentRemaining(session: nil) == nil)
    }

    @Test
    func costTodayText() {
        let cost = ProviderCost(today: 1.234, last30Days: 9, todayTokens: 1, last30DaysTokens: 2)
        #expect(MenuBarContentText.costToday(cost: cost) == "$1.23")
        #expect(MenuBarContentText.costToday(cost: nil) == nil)
    }

    @Test
    func timeUntilResetText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 2h34m ahead → "2h34".
        let session = RateWindow(
            utilization: 50,
            resetsAt: now.addingTimeInterval((2 * 60 + 34) * 60),
            windowMinutes: 300)
        #expect(MenuBarContentText.timeUntilReset(session: session, now: now) == "2h34")

        // 5 minutes ahead → "5min".
        let soon = RateWindow(utilization: 50, resetsAt: now.addingTimeInterval(5 * 60), windowMinutes: 300)
        #expect(MenuBarContentText.timeUntilReset(session: soon, now: now) == "5min")

        // Minute zero-padding: 2h04, not 2h4.
        let padded = RateWindow(
            utilization: 50,
            resetsAt: now.addingTimeInterval((2 * 60 + 4) * 60),
            windowMinutes: 300)
        #expect(MenuBarContentText.timeUntilReset(session: padded, now: now) == "2h04")

        // Past reset / unknown → nil.
        let past = RateWindow(utilization: 50, resetsAt: now.addingTimeInterval(-60), windowMinutes: 300)
        #expect(MenuBarContentText.timeUntilReset(session: past, now: now) == nil)
        #expect(MenuBarContentText.timeUntilReset(session: nil, now: now) == nil)
    }

    // MARK: - Compositing (AC3)

    @Test
    func compositeHandlesMissingPieces() {
        let a = NSImage(size: NSSize(width: 10, height: 10))
        let b = NSImage(size: NSSize(width: 8, height: 6))
        // Both present → a wider combined image (icon + gap + trailing).
        let combined = StatusItemController.composite(icon: a, trailing: b)
        #expect(combined != nil)
        #expect((combined?.size.width ?? 0) >= a.size.width + b.size.width)
        #expect(combined?.isTemplate == true)
        // One missing → the other passes through.
        #expect(StatusItemController.composite(icon: nil, trailing: b) === b)
        #expect(StatusItemController.composite(icon: a, trailing: nil) === a)
        #expect(StatusItemController.composite(icon: nil, trailing: nil) == nil)
    }

    // MARK: - SettingsStore persistence (AC1 §2 / AC4 §13)

    @Test
    func menuBarSettingsSurviveRestart() {
        let suite = defaults()
        let first = SettingsStore(defaults: suite)
        first.menuBarContent = .sparkline
        first.globalHotkey = HotkeyBinding(modifiers: [.control, .shift], keyCode: 15) // ⌃⇧R
        first.flush()

        let second = SettingsStore(defaults: suite)
        #expect(second.menuBarContent == .sparkline)
        #expect(second.globalHotkey == HotkeyBinding(modifiers: [.control, .shift], keyCode: 15))
    }

    @Test
    func menuBarContentDefaultsAndFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.menuBarContent == .none)
        #expect(store.globalHotkey == .defaultBinding)

        var count = 0
        store.onMenuBarContentChange = { count += 1 }
        store.menuBarContent = .costToday
        store.menuBarContent = .costToday // no-op
        store.menuBarContent = .none
        #expect(count == 2)
    }

    @Test
    func globalHotkeyChangeFiresCallback() {
        let store = SettingsStore(defaults: defaults())
        var bindings: [HotkeyBinding?] = []
        store.onGlobalHotkeyChange = { bindings.append($0) }

        let newBinding = HotkeyBinding(modifiers: [.command], keyCode: 49) // ⌘Space
        store.globalHotkey = newBinding
        store.globalHotkey = nil
        #expect(bindings == [newBinding, nil])
    }

    /// A cleared hotkey (→ nil) must survive a restart as nil, not resurrect the ⌥⌘C default.
    @Test
    func clearedHotkeyStaysClearedAfterRestart() {
        let suite = defaults()
        let first = SettingsStore(defaults: suite)
        first.globalHotkey = nil
        first.flush()

        let second = SettingsStore(defaults: suite)
        #expect(second.globalHotkey == nil)
    }
}
