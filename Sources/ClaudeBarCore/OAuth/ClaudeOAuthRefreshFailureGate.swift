import Foundation

#if os(macOS)
import os.lock

/// Refresh-failure backoff gate (AC14).
///
/// - `invalid_grant` (HTTP 400/401 on refresh) → terminal block. No further refresh
///   attempts until the keychain fingerprint changes.
/// - other failures → exponential backoff, base 5 min, ceiling 6 h.
///
/// Ported and simplified from
/// `_reference_codexbar/.../ClaudeOAuth/ClaudeOAuthRefreshFailureGate.swift`. The
/// fingerprint source is injected so the gate is decoupled from the credentials store.
public enum ClaudeOAuthRefreshFailureGate {
    public enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String?, failures: Int)
        case transient(until: Date, failures: Int)
    }

    private struct State {
        var loaded = false
        var terminalFailureCount = 0
        var transientFailureCount = 0
        var isTerminalBlocked = false
        var transientBlockedUntil: Date?
        var fingerprintAtFailure: String?
        var lastCredentialsRecheckAt: Date?
        var terminalReason: String?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let terminalFailureCountKey = "claudeOAuthRefreshTerminalFailureCountV1"
    private static let fingerprintKey = "claudeOAuthRefreshFingerprintV2"
    private static let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"
    private static let terminalReasonKey = "claudeOAuthRefreshTerminalReasonV1"
    private static let transientBlockedUntilKey = "claudeOAuthRefreshTransientBlockedUntilV1"
    private static let transientFailureCountKey = "claudeOAuthRefreshTransientFailureCountV1"

    private static let minimumCredentialsRecheckInterval: TimeInterval = 15
    private static let transientBaseInterval: TimeInterval = 60 * 5
    private static let transientMaxInterval: TimeInterval = 60 * 60 * 6

    /// Supplies the current keychain fingerprint. Injected so the gate stays decoupled.
    /// Defaults to nil so the gate works in environments without a fingerprint source.
    /// Lock-backed to remain `Sendable` without suppressions.
    private static let fingerprintProviderLock =
        OSAllocatedUnfairLock<(@Sendable () -> String?)?>(initialState: nil)

    public static func setFingerprintProvider(_ provider: (@Sendable () -> String?)?) {
        self.fingerprintProviderLock.withLock { $0 = provider }
    }

    public static func shouldAttempt(now: Date = Date()) -> Bool {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)

            if state.isTerminalBlocked {
                guard self.shouldRecheckCredentials(now: now, state: state) else { return false }
                state.lastCredentialsRecheckAt = now
                if self.hasCredentialsChangedSinceFailure(state) {
                    self.resetState(&state)
                    self.persist(state)
                    return true
                }
                return false
            }

            if let blockedUntil = state.transientBlockedUntil {
                if blockedUntil <= now {
                    self.clearTransientState(&state)
                    state.fingerprintAtFailure = nil
                    state.lastCredentialsRecheckAt = nil
                    self.persist(state)
                    return true
                }
                if self.shouldRecheckCredentials(now: now, state: state) {
                    state.lastCredentialsRecheckAt = now
                    if self.hasCredentialsChangedSinceFailure(state) {
                        self.resetState(&state)
                        self.persist(state)
                        return true
                    }
                }
                return false
            }

            return true
        }
    }

    public static func currentBlockStatus(now: Date = Date()) -> BlockStatus? {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if state.isTerminalBlocked {
                return .terminal(reason: state.terminalReason, failures: state.terminalFailureCount)
            }
            if let blockedUntil = state.transientBlockedUntil, blockedUntil > now {
                return .transient(until: blockedUntil, failures: state.transientFailureCount)
            }
            return nil
        }
    }

    /// Records a terminal `invalid_grant` failure (AC14).
    public static func recordTerminalAuthFailure(now: Date = Date()) {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.terminalFailureCount += 1
            state.isTerminalBlocked = true
            state.terminalReason = "invalid_grant"
            state.fingerprintAtFailure = self.currentFingerprint()
            state.lastCredentialsRecheckAt = now
            self.clearTransientState(&state)
            self.persist(state)
        }
    }

    /// Records a non-terminal failure → exponential backoff.
    public static func recordTransientFailure(now: Date = Date()) {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            // Keep terminal blocking monotonic: do not downgrade a known-bad auth.
            guard !state.isTerminalBlocked else { return }
            self.clearTerminalState(&state)
            state.transientFailureCount += 1
            let interval = self.transientCooldownInterval(failures: state.transientFailureCount)
            state.transientBlockedUntil = now.addingTimeInterval(interval)
            state.fingerprintAtFailure = self.currentFingerprint()
            state.lastCredentialsRecheckAt = now
            self.persist(state)
        }
    }

    public static func recordSuccess() {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            self.resetState(&state)
            self.persist(state)
        }
    }

    private static func shouldRecheckCredentials(now: Date, state: State) -> Bool {
        guard let last = state.lastCredentialsRecheckAt else { return true }
        return now.timeIntervalSince(last) >= self.minimumCredentialsRecheckInterval
    }

    private static func hasCredentialsChangedSinceFailure(_ state: State) -> Bool {
        guard let current = self.currentFingerprint() else { return false }
        guard let prior = state.fingerprintAtFailure else { return false }
        return current != prior
    }

    private static func currentFingerprint() -> String? {
        let provider = self.fingerprintProviderLock.withLock { $0 }
        return provider?()
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        let defaults = UserDefaults.standard
        state.terminalFailureCount = defaults.integer(forKey: self.terminalFailureCountKey)
        state.transientFailureCount = defaults.integer(forKey: self.transientFailureCountKey)
        state.isTerminalBlocked = defaults.bool(forKey: self.terminalBlockedKey)
        state.terminalReason = defaults.string(forKey: self.terminalReasonKey)
        if let raw = defaults.object(forKey: self.transientBlockedUntilKey) as? Double {
            state.transientBlockedUntil = Date(timeIntervalSince1970: raw)
        }
        state.fingerprintAtFailure = defaults.string(forKey: self.fingerprintKey)
    }

    private static func persist(_ state: State) {
        let defaults = UserDefaults.standard
        defaults.set(state.terminalFailureCount, forKey: self.terminalFailureCountKey)
        defaults.set(state.isTerminalBlocked, forKey: self.terminalBlockedKey)
        if let reason = state.terminalReason {
            defaults.set(reason, forKey: self.terminalReasonKey)
        } else {
            defaults.removeObject(forKey: self.terminalReasonKey)
        }
        defaults.set(state.transientFailureCount, forKey: self.transientFailureCountKey)
        if let blockedUntil = state.transientBlockedUntil {
            defaults.set(blockedUntil.timeIntervalSince1970, forKey: self.transientBlockedUntilKey)
        } else {
            defaults.removeObject(forKey: self.transientBlockedUntilKey)
        }
        if let fingerprint = state.fingerprintAtFailure {
            defaults.set(fingerprint, forKey: self.fingerprintKey)
        } else {
            defaults.removeObject(forKey: self.fingerprintKey)
        }
    }

    private static func transientCooldownInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(failures - 1))
        return min(self.transientBaseInterval * factor, self.transientMaxInterval)
    }

    private static func clearTerminalState(_ state: inout State) {
        state.terminalFailureCount = 0
        state.isTerminalBlocked = false
        state.terminalReason = nil
    }

    private static func clearTransientState(_ state: inout State) {
        state.transientFailureCount = 0
        state.transientBlockedUntil = nil
    }

    private static func resetState(_ state: inout State) {
        self.clearTerminalState(&state)
        self.clearTransientState(&state)
        state.fingerprintAtFailure = nil
        state.lastCredentialsRecheckAt = nil
    }

    #if DEBUG
    public static func resetForTesting() {
        self.lock.withLock { state in
            state = State(loaded: true)
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: self.terminalFailureCountKey)
            defaults.removeObject(forKey: self.fingerprintKey)
            defaults.removeObject(forKey: self.terminalBlockedKey)
            defaults.removeObject(forKey: self.terminalReasonKey)
            defaults.removeObject(forKey: self.transientBlockedUntilKey)
            defaults.removeObject(forKey: self.transientFailureCountKey)
        }
    }
    #endif
}
#else
public enum ClaudeOAuthRefreshFailureGate {
    public enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String?, failures: Int)
        case transient(until: Date, failures: Int)
    }

    public static func setFingerprintProvider(_: (@Sendable () -> String?)?) {}
    public static func shouldAttempt(now _: Date = Date()) -> Bool { true }
    public static func currentBlockStatus(now _: Date = Date()) -> BlockStatus? { nil }
    public static func recordTerminalAuthFailure(now _: Date = Date()) {}
    public static func recordTransientFailure(now _: Date = Date()) {}
    public static func recordSuccess() {}
    #if DEBUG
    public static func resetForTesting() {}
    #endif
}
#endif
