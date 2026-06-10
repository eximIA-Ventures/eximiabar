import Foundation

/// Where a `UsageSnapshot` was sourced from.
public enum DataSource: String, Sendable, Equatable, CaseIterable {
    case oauth
    case cli
    case web
}
