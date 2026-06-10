import Foundation

#if os(macOS)
import os.lock

/// Wraps the keychain prompt-policy cooldown (AC4).
///
/// When a keychain prompt is denied/cancelled, the gate backs off for a cooldown window
/// so background probes don't re-trigger Allow/Deny storms. User-initiated repairs can
/// clear the cooldown.
///
/// Ported from
/// `_reference_codexbar/.../ClaudeOAuth/ClaudeOAuthKeychainAccessGate.swift`.
public enum ClaudeOAuthKeychainAccessGate {
    private struct State {
        var loaded = false
        var deniedUntil: Date?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "claudeOAuthKeychainDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6

    public static func shouldAllowPrompt(now: Date = Date()) -> Bool {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if let deniedUntil = state.deniedUntil {
                if deniedUntil > now {
                    return false
                }
                state.deniedUntil = nil
                self.persist(state)
            }
            return true
        }
    }

    public static func recordDenied(now: Date = Date()) {
        let deniedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntil = deniedUntil
            self.persist(state)
        }
    }

    /// Clears the cooldown so the next attempt can proceed. Intended for user-initiated repairs.
    /// - Returns: `true` if a cooldown was present and cleared.
    @discardableResult
    public static func clearDenied(now: Date = Date()) -> Bool {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard let deniedUntil = state.deniedUntil, deniedUntil > now else {
                state.deniedUntil = nil
                self.persist(state)
                return false
            }
            state.deniedUntil = nil
            self.persist(state)
            return true
        }
    }

    #if DEBUG
    public static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = true
            state.deniedUntil = nil
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }
    #endif

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        if let raw = UserDefaults.standard.object(forKey: self.defaultsKey) as? Double {
            state.deniedUntil = Date(timeIntervalSince1970: raw)
        }
    }

    private static func persist(_ state: State) {
        if let deniedUntil = state.deniedUntil {
            UserDefaults.standard.set(deniedUntil.timeIntervalSince1970, forKey: self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }
}
#else
public enum ClaudeOAuthKeychainAccessGate {
    public static func shouldAllowPrompt(now _: Date = Date()) -> Bool { true }
    public static func recordDenied(now _: Date = Date()) {}
    @discardableResult
    public static func clearDenied(now _: Date = Date()) -> Bool { false }
    #if DEBUG
    public static func resetForTesting() {}
    #endif
}
#endif
