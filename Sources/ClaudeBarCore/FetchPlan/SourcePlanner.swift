import Foundation

/// A single planned fetch step.
public struct FetchStrategy: Sendable, Equatable {
    public let dataSource: DataSource
    /// Whether this source is plausibly available given the inputs.
    public let isPlausiblyAvailable: Bool

    public init(dataSource: DataSource, isPlausiblyAvailable: Bool) {
        self.dataSource = dataSource
        self.isPlausiblyAvailable = isPlausiblyAvailable
    }
}

/// Inputs that determine source ordering and availability.
public struct SourcePlanningInput: Sendable, Equatable {
    /// Explicit source selection, or `nil` for `auto` mode.
    public let selectedSource: DataSource?
    public let hasOAuthCredentials: Bool
    public let hasCLI: Bool
    public let hasWebSession: Bool

    public init(
        selectedSource: DataSource?,
        hasOAuthCredentials: Bool,
        hasCLI: Bool,
        hasWebSession: Bool)
    {
        self.selectedSource = selectedSource
        self.hasOAuthCredentials = hasOAuthCredentials
        self.hasCLI = hasCLI
        self.hasWebSession = hasWebSession
    }
}

/// Pure source-ordering function — no side effects (AC15).
///
/// In `auto` mode the order is OAuth → CLI → Web. Web is returned by the planner but
/// `FetchPipeline` guards against executing it in P0/P1 scope. Copy-adapted from
/// `_reference_codexbar/.../Claude/ClaudeSourcePlanner.swift`.
public enum SourcePlanner {
    /// Returns the ordered list of strategies for the given input.
    public static func plan(input: SourcePlanningInput) -> [FetchStrategy] {
        if let selected = input.selectedSource {
            return [FetchStrategy(
                dataSource: selected,
                isPlausiblyAvailable: self.isPlausiblyAvailable(selected, input: input))]
        }
        // auto mode: OAuth → CLI → Web.
        return [DataSource.oauth, .cli, .web].map { source in
            FetchStrategy(
                dataSource: source,
                isPlausiblyAvailable: self.isPlausiblyAvailable(source, input: input))
        }
    }

    /// Whether `auto` mode should fall through to the next source on this error.
    /// Auth and scope errors fall through; rate-limit / network / parse / blocked do not.
    public static func shouldFallback(error: UsageError) -> Bool {
        error.isAuthOrScope
    }

    private static func isPlausiblyAvailable(
        _ source: DataSource,
        input: SourcePlanningInput) -> Bool
    {
        switch source {
        case .oauth: input.hasOAuthCredentials
        case .cli: input.hasCLI
        case .web: input.hasWebSession
        }
    }
}
