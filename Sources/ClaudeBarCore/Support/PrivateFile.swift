import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Owner-only file persistence for the app's own secrets (OAuth cache, archived account tokens).
///
/// ## Why not the keychain (EXB keychain-prompt root cause)
///
/// A generic-password item the app creates carries an ACL bound to the app's *code signature*.
/// The installed app is signed ad-hoc unless `EXIMIA_SIGN_IDENTITY` is available at build time, so
/// its designated requirement is a bare `cdhash` that changes on every rebuild. After each
/// reinstall the new binary is no longer in the item's ACL, and the `SecItemDelete` + `SecItemAdd`
/// the cache did on every fetch made macOS ask for the login password ("wants to use / change the
/// keychain"). Even with a stable identity the item would prompt again the moment the identity is
/// rotated. A `0600` file under `~/Library/Application Support` has no ACL to fall out of: the same
/// user can always read it, and no one else can. It is the same at-rest protection the Claude CLI
/// itself uses for `~/.claude/.credentials.json` and the Codex CLI for `~/.codex/auth.json`.
enum PrivateFile {
    static let filePermissions: Int16 = 0o600
    static let directoryPermissions: Int16 = 0o700

    /// Writes `data` to `url` atomically with mode `0600`, creating the parent with mode `0700`.
    ///
    /// The bytes are written into a temp file that is created `0600` *before* any content lands
    /// in it, then `rename(2)`d over the destination — so there is no instant in which the secret
    /// sits in a world-readable file (an `.atomic` `Data.write` would inherit the umask first).
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Self.directoryPermissions)])

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temp.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Self.filePermissions)])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Belt and braces: `createFile` honours the attribute, but re-assert it before the rename.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Self.filePermissions)],
            ofItemAtPath: temp.path)
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Test tripwire: when `EXIMIABAR_FORBID_REAL_KEYCHAIN=1` (exported by `Scripts/run-tests.sh`),
/// any code path that would reach the real keychain — the `/usr/bin/security` subprocess or a
/// legacy `SecItem` read — crashes the test process instead of silently touching the user's
/// keychain. A test that needs layer (e) must inject a test double; a silent `nil` would let a
/// leak pass as green.
enum RealKeychainTripwire {
    static let environmentKey = "EXIMIABAR_FORBID_REAL_KEYCHAIN"

    static var isArmed: Bool {
        ProcessInfo.processInfo.environment[Self.environmentKey] == "1"
    }

    static func check(_ what: StaticString) {
        if Self.isArmed {
            preconditionFailure("Real keychain access attempted under test: \(what)")
        }
    }
}
