import Foundation

/// The subset of `~/.codex/auth.json` this app reads (EXB-5.4 AC2).
///
/// Note what is **absent**: the file's `tokens.refresh_token` is never decoded into this record,
/// because nothing in this module is allowed to renew anything (see `CodexAuthStore` docs and
/// EXB-5.4 AC3). A field that cannot be used is a field better left unread.
public struct CodexAuthRecord: Sendable, Equatable {
    /// The bearer token sent to `wham/usage`.
    public let accessToken: String
    /// The identity assertion — carries e-mail, plan and account id in its claims.
    public let idToken: String?
    /// `tokens.account_id`, used for the `ChatGPT-Account-Id` header when present.
    public let accountID: String?
}

/// Failure modes of reading `~/.codex/auth.json`. Absence is **not** one of them — a missing file
/// means "the user does not use Codex", which is a normal state, not an error (AC4.12).
public enum CodexAuthError: Error, Sendable, Equatable {
    case unreadable(String)
    case malformed(String)
}

extension CodexAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadable(message): "~/.codex/auth.json não pôde ser lido: \(message)"
        case let .malformed(message): "~/.codex/auth.json inválido: \(message)"
        }
    }
}

/// Reads the Codex CLI's OAuth file — `$CODEX_HOME/auth.json`, else `~/.codex/auth.json` —
/// with the same mtime fingerprint gate `CredentialsStore` and `ClaudeIdentityResolver` use.
///
/// Three properties are load-bearing:
///
/// - **Zero keychain, zero prompt.** The file is plain text, mode `0600`. Reading it can never
///   raise an Allow/Deny dialog, which is the whole reason the Codex provider stays this small.
/// - **Fingerprint gate.** The file is re-parsed only when its `(mtime, size)` changes. A 60 s
///   refresh cycle must not re-decode JSON it already holds.
/// - **Read-only, forever.** This actor never writes the file and never renews the tokens in it.
///   The file belongs to the `codex` CLI exactly as `.credentials.json` belongs to `claude`
///   (R6, by analogy). If the token is dead, the answer is `codex login` — run by the user, in
///   their terminal, not a renewal request smuggled out of a menu-bar app. This is a deliberate
///   divergence from the reference implementation, which does renew.
///
/// All I/O happens inside the actor, so nothing touches the main thread (anti-freeze invariant).
public actor CodexAuthStore {
    public static let authFileName = "auth.json"
    public static let codexDirectoryName = ".codex"
    public static let codexHomeEnvironmentKey = "CODEX_HOME"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let log = CoreLog.logger(CoreLog.Category.credentials)

    // MARK: Fingerprint-gated cache

    private var cachedFingerprint: String?
    private var cachedRecord: CodexAuthRecord?
    private var hasCachedResult = false

    /// How many times the file was actually read and decoded.
    ///
    /// The gate is invisible from the outside — two `load()` calls look identical whether or not
    /// the file was re-parsed. This counter is the only way to assert the gate holds, so it is
    /// public on purpose (same rationale as `ClaudeIdentityResolver.parseCount`).
    public private(set) var parseCount = 0

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// `$CODEX_HOME/auth.json` when the variable is set and non-empty, else `~/.codex/auth.json`.
    public nonisolated var authFileURL: URL {
        let codexHome = self.environment[Self.codexHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL = if let codexHome, !codexHome.isEmpty {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            self.homeDirectory.appendingPathComponent(Self.codexDirectoryName, isDirectory: true)
        }
        return root.appendingPathComponent(Self.authFileName)
    }

    // MARK: Public API

    /// Loads the auth record.
    ///
    /// - Returns: `nil` when the file does not exist — the provider is simply absent (AC4.12),
    ///   which is silence, not an error.
    /// - Throws: `CodexAuthError` when the file exists but cannot be read or decoded.
    public func load() throws -> CodexAuthRecord? {
        let fingerprint = self.currentFingerprint()
        if self.hasCachedResult, fingerprint == self.cachedFingerprint {
            return self.cachedRecord
        }

        guard FileManager.default.fileExists(atPath: self.authFileURL.path) else {
            self.cachedFingerprint = fingerprint
            self.cachedRecord = nil
            self.hasCachedResult = true
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: self.authFileURL)
        } catch {
            throw CodexAuthError.unreadable(error.localizedDescription)
        }
        self.parseCount += 1

        let record = try Self.parse(data)
        self.cachedFingerprint = fingerprint
        self.cachedRecord = record
        self.hasCachedResult = true
        self.log.debug("Parsed ~/.codex/auth.json (parseCount=\(self.parseCount, privacy: .public))")
        return record
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> CodexAuthRecord {
        guard let envelope = try? JSONDecoder().decode(CodexAuthEnvelope.self, from: data) else {
            throw CodexAuthError.malformed("JSON de topo ilegível")
        }
        guard let accessToken = Self.nonEmpty(envelope.tokens?.accessToken) else {
            throw CodexAuthError.malformed("tokens.access_token ausente")
        }
        return CodexAuthRecord(
            accessToken: accessToken,
            idToken: Self.nonEmpty(envelope.tokens?.idToken),
            accountID: Self.nonEmpty(envelope.tokens?.accountID))
    }

    /// File fingerprint = (mtime ms, size) — the same shape as
    /// `CredentialsStore.currentFileFingerprint` and `ClaudeIdentityResolver.currentFingerprint`.
    private func currentFingerprint() -> String? {
        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: self.authFileURL.path)
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtimeMs = (attrs[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return "\(mtimeMs):\(size)"
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

// MARK: - Tolerant decoding

/// The observed shape of `~/.codex/auth.json`. Every field is optional: the file is undocumented
/// and the `codex` CLI may add, drop or rename keys without notice.
private struct CodexAuthEnvelope: Decodable {
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case tokens
        // `last_refresh` is in the file and is not declared here: this app never acts on how
        // stale the CLI's own renewal is, so reading it would only invite someone to.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokens = try? container.decodeIfPresent(Tokens.self, forKey: .tokens)
    }

    /// `tokens.refresh_token` exists in the file and is **intentionally not declared here**:
    /// decoding it would create the temptation to use it, and using it is forbidden (AC3).
    struct Tokens: Decodable {
        let idToken: String?
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case accountID = "account_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.idToken = try? container.decodeIfPresent(String.self, forKey: .idToken)
            self.accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
            self.accountID = try? container.decodeIfPresent(String.self, forKey: .accountID)
        }
    }
}
