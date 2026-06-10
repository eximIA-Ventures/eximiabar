import Foundation

/// 429 rate-limit gate (AC12).
///
/// Background refresh short-circuits while the gate is active (returns the last cached
/// snapshot). User-initiated refresh ignores the gate. After a persistent 429 the gate
/// persists until `Retry-After` elapses.
///
/// Ported from
/// `_reference_codexbar/.../ClaudeOAuth/ClaudeOAuthUsageRateLimitGate.swift`.
public enum ClaudeOAuthUsageRateLimitGate {
    private static let blockedUntilKey = "claudeOAuthUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5

    private static var defaults: UserDefaults { .standard }

    /// The blocked-until date that applies to a *background* attempt (nil for user-initiated).
    public static func blockedUntil(
        phase: RefreshPhase,
        now: Date = Date()) -> Date?
    {
        guard phase != .userInitiated else { return nil }
        return self.currentBlockedUntil(now: now)
    }

    /// The current blocked-until date regardless of phase (expired entries are cleared).
    public static func currentBlockedUntil(now: Date = Date()) -> Date? {
        guard let raw = self.defaults.object(forKey: self.blockedUntilKey) as? Double else {
            return nil
        }
        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            self.defaults.removeObject(forKey: self.blockedUntilKey)
            return nil
        }
        return blockedUntil
    }

    public static func recordRateLimit(retryAfter: Date?, now: Date = Date()) {
        let blockedUntil: Date = if let retryAfter, retryAfter > now {
            retryAfter
        } else {
            now.addingTimeInterval(self.defaultCooldown)
        }
        self.defaults.set(blockedUntil.timeIntervalSince1970, forKey: self.blockedUntilKey)
    }

    public static func recordSuccess() {
        self.defaults.removeObject(forKey: self.blockedUntilKey)
    }

    #if DEBUG
    public static func resetForTesting() {
        self.defaults.removeObject(forKey: self.blockedUntilKey)
    }
    #endif
}
