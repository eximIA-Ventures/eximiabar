import Foundation

/// Component-wise semantic-version comparison (EXB-2.4 AC3).
///
/// Versions are compared by splitting on `"."` and comparing each component as an `Int`
/// (major, then minor, then patch). A version with *more* numeric components than another — all
/// shared components being equal — is considered newer (e.g. `1.1.0` > `1.1`). Non-numeric / build
/// suffixes (`1.1.0-beta`) are ignored after the first non-`Int` component, matching the story's
/// simple `compactMap { Int($0) }` contract.
///
/// Pure and stateless — lives in the UI-free core so AC3 is unit-testable without AppKit.
public enum SemanticVersion {
    /// Split `"1.2.3"` into `[1, 2, 3]`, stopping at the first non-numeric component.
    static func components(_ version: String) -> [Int] {
        var result: [Int] = []
        for part in version.split(separator: ".") {
            guard let value = Int(part) else { break }
            result.append(value)
        }
        return result
    }

    /// `true` iff `remote` is strictly newer than `local` (AC3 — "remote > local → update available").
    ///
    /// Shared components are compared in order; the first difference decides. If every shared
    /// component is equal, the version with more components wins (so `1.1.0` > `1.1`, and
    /// `1.1` == `1.1.0` is *not* "newer" in the reverse direction).
    public static func isNewer(remote: String, than local: String) -> Bool {
        let r = components(remote)
        let l = components(local)
        for (rv, lv) in zip(r, l) where rv != lv {
            return rv > lv
        }
        return r.count > l.count
    }
}
