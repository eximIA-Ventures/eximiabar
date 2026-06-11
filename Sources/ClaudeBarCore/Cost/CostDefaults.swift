import Foundation

/// A `Sendable` wrapper around `UserDefaults` for the cost subsystem (EXB-1.7).
///
/// `UserDefaults` is documented thread-safe but is not marked `Sendable`, so passing an instance
/// into the `Pricing` / `CostScanner` actors trips Swift 6's `sending` data-race diagnostic. This
/// box carries it across isolation boundaries safely: every operation forwards to the underlying,
/// thread-safe `UserDefaults`. The `@unchecked` is sound because `UserDefaults` synchronizes its own
/// access. Tests inject a per-suite store so the offset / aggregate caches stay isolated.
public struct CostDefaults: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? { self.defaults.data(forKey: key) }
    func double(forKey key: String) -> Double { self.defaults.double(forKey: key) }
    func dictionary(forKey key: String) -> [String: Any]? { self.defaults.dictionary(forKey: key) }
    func set(_ value: Any?, forKey key: String) { self.defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { self.defaults.removeObject(forKey: key) }
}
