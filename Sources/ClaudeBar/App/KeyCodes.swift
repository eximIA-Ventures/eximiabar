import AppKit

/// Minimal virtual-key-code helpers for the global hotkey (EXB-4.4 AC4).
///
/// We deliberately avoid Carbon's `kVK_*` constants and any `RegisterEventHotKey` machinery — the
/// hotkey is delivered through `NSEvent.addGlobalMonitorForEvents` (AC10), so all we need is a way to
/// name a key for the Settings capture field. This is a small, dependency-free lookup of the common
/// keys; anything unmapped falls back to a generic `"Key N"` label rather than crashing.
enum KeyCodes {
    /// Virtual key code for the `C` key (the `⌥⌘C` default).
    static let c: UInt16 = 8

    /// A short, human-readable name for a virtual key code (used in the capture field label).
    ///
    /// Covers letters, digits, and the handful of named keys a user is likely to bind. Unknown codes
    /// return `"Key \(code)"` so the binding is still legible and never produces an empty label.
    static func displayName(for code: UInt16) -> String {
        if let named = namedKeys[code] { return named }
        if let letter = letters[code] { return letter }
        if let digit = digits[code] { return digit }
        return "Key \(code)"
    }

    // MARK: - Tables

    private static let letters: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    ]

    private static let digits: [UInt16: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    private static let namedKeys: [UInt16: String] = [
        49: "Space",
        36: "↩",
        48: "⇥",
        51: "⌫",
        53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
