import Foundation
import os

/// Thin wrapper around `os.Logger` for `ClaudeBarCore`.
///
/// Subsystem is fixed to `com.eximia.eximiabar`; callers pass a per-module category.
/// No global mutable state — each call site creates a value-typed `Logger`.
public enum CoreLog {
    public static let subsystem = "com.eximia.eximiabar"

    public enum Category {
        public static let credentials = "credentials"
        public static let usage = "usage"
        public static let refresh = "refresh"
        public static let planner = "planner"
        public static let http = "http"
        public static let keychain = "keychain"
        public static let cli = "cli"
    }

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
