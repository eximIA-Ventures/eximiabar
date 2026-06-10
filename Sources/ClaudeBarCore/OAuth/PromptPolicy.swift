import Foundation

/// When a keychain prompt is permitted.
///
/// AC4: a prompt is only triggered when the policy permits it for the active phase. All other
/// reads use the no-UI keychain query.
public enum PromptPolicy: String, Sendable, Equatable, CaseIterable {
    /// Never raise a keychain prompt (background-only, fully silent).
    case never
    /// Raise a prompt only when the call is user-initiated.
    case onUserAction
    /// Raise a prompt in any phase (EXB-1.5 AC11). Use with care — background polls may prompt.
    case always

    /// Whether a keychain dialog may be raised for the given refresh phase.
    public func allowsPrompt(phase: RefreshPhase) -> Bool {
        switch self {
        case .never: false
        case .onUserAction: phase == .userInitiated
        case .always: true
        }
    }
}

/// The phase of a refresh / fetch — distinguishes app-launch, background polling and a user click.
///
/// Controls (AC4 of EXB-1.4): (a) whether keychain prompts are allowed, (b) whether the 429
/// rate-limit gate is bypassed (user-initiated only), (c) whether quota notifications are posted.
public enum RefreshPhase: Sendable, Equatable {
    /// The very first refresh triggered at app launch.
    case startup
    /// A timer-driven background poll.
    case background
    /// An explicit user action (popover open, ⌘R). Bypasses the 429 gate and keychain cooldowns.
    case userInitiated

    /// The fetch mode this phase maps to. Only `.userInitiated` ignores the 429 gate (AC12).
    public var fetchMode: FetchMode {
        self == .userInitiated ? .userInitiated : .auto
    }

    /// Whether quota notifications may be posted for this phase. Startup seeds baseline state
    /// silently (no spurious "depleted/restored" on first launch), so only background and
    /// user-initiated refreshes post notifications.
    public var allowsNotifications: Bool {
        self != .startup
    }
}

/// TaskLocal carrying the active `RefreshPhase` through the fetch call tree (AC4).
///
/// Defaults to `.background`; `AppState` binds it per refresh so downstream gates and the
/// notifier can read the originating phase without threading it through every signature.
public enum RefreshContext {
    @TaskLocal public static var phase: RefreshPhase = .background
}

/// Mode for a fetch attempt — controls gate behavior (AC12).
public enum FetchMode: Sendable, Equatable {
    case auto
    case userInitiated
}
