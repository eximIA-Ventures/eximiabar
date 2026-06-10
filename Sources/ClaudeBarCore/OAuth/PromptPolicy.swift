import Foundation

/// When a keychain prompt is permitted.
///
/// AC4: a prompt is only triggered when `promptPolicy == .onUserAction` AND the call is
/// user-initiated. All background reads use the no-UI keychain query.
public enum PromptPolicy: String, Sendable, Equatable, CaseIterable {
    /// Never raise a keychain prompt (background-only, fully silent).
    case never
    /// Raise a prompt only when the call is user-initiated.
    case onUserAction
}

/// The phase of a refresh / fetch — distinguishes background polling from a user click.
public enum RefreshPhase: Sendable, Equatable {
    case background
    case userInitiated
}

/// Mode for a fetch attempt — controls gate behavior (AC12).
public enum FetchMode: Sendable, Equatable {
    case auto
    case userInitiated
}
