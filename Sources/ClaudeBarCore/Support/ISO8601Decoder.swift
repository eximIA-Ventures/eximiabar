import Foundation

/// Two-format ISO8601 date decoder.
///
/// Anthropic's `resets_at` fields use ISO8601 with fractional seconds and a `Z` suffix
/// (e.g. `2025-12-25T12:00:00.000Z`) but occasionally omit fractional seconds. This
/// decoder tries the fractional-seconds format first, then falls back.
///
/// Mirrors `ClaudeOAuthUsageFetcher.parseISO8601Date` from the reference.
public enum ISO8601Decoder {
    public static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
