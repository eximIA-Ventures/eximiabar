import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Layer (e) PRIMARY reader: reads the Claude OAuth secret via the `/usr/bin/security`
/// command-line tool instead of `SecItemCopyMatching`.
///
/// ## Why this exists (the recurring-prompt bug)
///
/// The `"Claude Code-credentials"` keychain item is created by the Claude Code CLI (Node)
/// with a partition list that trusts `/usr/bin/security` (`apple-tool:`) but **not** our app.
/// Reading the secret bytes through `SecItemCopyMatching` therefore requires our app to be in
/// the item's ACL — which it is not — so the OS raises an Allow/Deny prompt. Worse, the CLI
/// **recreates** the item on every token renewal, which zeroes the ACL again → the prompt
/// returns "periodically".
///
/// `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` reads the same
/// secret with exit code 0 and **no prompt**, because that tool *is* in the trusted partition
/// list. This reader replicates the approach used by the upstream CodexBar
/// (`.securityCLIExperimental` is its production default).
///
/// ## Multiple-item selection
///
/// The Claude CLI leaves several generic-password items behind (one per renewal). We do **not**
/// pass `-a` (account) in the background path: the `security` tool returns the keychain's
/// canonical match for the service, and we then *parse* the payload and verify it is non-expired
/// before trusting it. If the CLI read is empty, unparseable, or expired, layer (e) yields nothing
/// (there is no `SecItem` fallback any more; see `CredentialsStore.loadFromClaudeKeychain`).
///
/// The fingerprint used for change detection comes from the same tool **without** `-w`: that
/// prints the item's attributes (account, creation and modification dates) and never the secret.
extension CredentialsStore {
    static let securityBinaryPath = "/usr/bin/security"
    static let securityCLIReadTimeout: TimeInterval = 1.5

    #if DEBUG
    /// Test seam mirroring the reference's `securityCLIReadOverride`. When set, the subprocess is
    /// not launched and this value drives the result instead.
    enum SecurityCLIReadOverride: Sendable {
        /// Return this stdout payload (or `nil`/empty to simulate "no data").
        case data(Data?)
        /// Simulate the subprocess exceeding the timeout.
        case timedOut
        /// Simulate a non-zero exit (e.g. item-not-found / not-trusted).
        case nonZeroExit
    }
    #endif

    #if os(macOS)
    enum SecurityCLIReadError: Error, Equatable {
        case binaryUnavailable
        case launchFailed
        case timedOut
        case nonZeroExit(status: Int32, stderrLength: Int)
    }

    struct SecurityCLIReadResult {
        let stdout: Data
        let status: Int32
        let stderrLength: Int
        let durationMs: Double
    }

    /// Reads the Claude keychain secret via `/usr/bin/security` and returns the parsed,
    /// **non-expired** credentials. Returns `nil` (never throws to the caller) on any failure so
    /// layer (e) can fall back to the no-UI Security.framework path.
    ///
    /// - Important: This path is prompt-free by construction. It never raises a keychain dialog.
    func loadFromClaudeKeychainViaSecurityCLI() -> ClaudeOAuthCredentials? {
        do {
            let result: SecurityCLIReadResult
            #if DEBUG
            if let override = self.securityCLIReadOverride {
                switch override {
                case let .data(data):
                    result = SecurityCLIReadResult(
                        stdout: data ?? Data(), status: 0, stderrLength: 0, durationMs: 0)
                case .timedOut:
                    throw SecurityCLIReadError.timedOut
                case .nonZeroExit:
                    throw SecurityCLIReadError.nonZeroExit(status: 44, stderrLength: 0)
                }
            } else if self.securityCLIAttributesOverride != nil {
                // A test drove only the attributes probe; never fall through to the real binary.
                return nil
            } else {
                result = try Self.runClaudeSecurityCLIRead(timeout: Self.securityCLIReadTimeout)
            }
            #else
            result = try Self.runClaudeSecurityCLIRead(timeout: Self.securityCLIReadTimeout)
            #endif

            let sanitized = Self.sanitizeSecurityCLIOutput(result.stdout)
            guard !sanitized.isEmpty else { return nil }

            let credentials: ClaudeOAuthCredentials
            do {
                credentials = try ClaudeOAuthCredentials.parse(data: sanitized)
            } catch {
                self.log.warning("Claude keychain security CLI output invalid")
                return nil
            }

            // Selection guard: the `-w` read may surface an older/expired renewal. Only trust a
            // live token here; an expired one makes layer (e) yield nothing.
            guard !credentials.isExpired else {
                self.log.debug("Claude keychain security CLI returned an expired token")
                return nil
            }

            self.log.debug("Claude keychain security CLI read succeeded")
            return credentials
        } catch {
            self.log.warning("Claude keychain security CLI read failed")
            return nil
        }
    }

    static func sanitizeSecurityCLIOutput(_ data: Data) -> Data {
        var sanitized = data
        while let last = sanitized.last, last == 0x0A || last == 0x0D {
            sanitized.removeLast()
        }
        return sanitized
    }

    /// Launches `/usr/bin/security find-generic-password -s "<service>" -w`, off-main, with a hard
    /// timeout. The whole process group is terminated on timeout so a stuck `security` never wedges
    /// the actor. Mirrors `ClaudeOAuthCredentials+SecurityCLIReader.runClaudeSecurityCLIRead`.
    static func runClaudeSecurityCLIRead(timeout: TimeInterval) throws -> SecurityCLIReadResult {
        try self.runSecurityCLI(
            arguments: ["find-generic-password", "-s", self.claudeKeychainService, "-w"],
            timeout: timeout)
    }

    /// Attribute-only probe (no `-w`, no `-g`): the output never contains the secret.
    static func runClaudeSecurityCLIAttributes(timeout: TimeInterval) throws -> SecurityCLIReadResult {
        try self.runSecurityCLI(
            arguments: ["find-generic-password", "-s", self.claudeKeychainService],
            timeout: timeout)
    }

    /// Change-detection fingerprint of the Claude item: a hash of its account and date attributes
    /// as printed by `/usr/bin/security`. `nil` when the item is absent or the probe fails.
    func claudeKeychainFingerprint() -> String? {
        let output: Data
        #if DEBUG
        if let override = self.securityCLIAttributesOverride {
            output = override
        } else if self.securityCLIReadOverride != nil {
            return nil
        } else {
            guard let result = try? Self.runClaudeSecurityCLIAttributes(timeout: Self.securityCLIReadTimeout)
            else { return nil }
            output = result.stdout
        }
        #else
        guard let result = try? Self.runClaudeSecurityCLIAttributes(timeout: Self.securityCLIReadTimeout)
        else { return nil }
        output = result.stdout
        #endif
        return Self.fingerprint(fromAttributesOutput: output)
    }

    /// Keeps only the `acct`, `cdat` and `mdat` lines, so a renewal (new dates) or a different
    /// login (new account) changes the fingerprint and nothing else does.
    static func fingerprint(fromAttributesOutput output: Data) -> String? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let relevant = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"acct\"") || $0.hasPrefix("\"cdat\"") || $0.hasPrefix("\"mdat\"") }
        guard !relevant.isEmpty else { return nil }
        return Self.sha256Prefix(Data(relevant.joined(separator: "\n").utf8))
    }

    static func runSecurityCLI(arguments: [String], timeout: TimeInterval) throws -> SecurityCLIReadResult {
        RealKeychainTripwire.check("/usr/bin/security subprocess")
        guard FileManager.default.isExecutableFile(atPath: self.securityBinaryPath) else {
            throw SecurityCLIReadError.binaryUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.securityBinaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try process.run()
        } catch {
            throw SecurityCLIReadError.launchFailed
        }

        // Put the child in its own process group so we can SIGTERM/SIGKILL the whole group.
        var processGroup: pid_t?
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            Self.terminate(process: process, processGroup: processGroup)
            throw SecurityCLIReadError.timedOut
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let status = process.terminationStatus
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000.0
        guard status == 0 else {
            throw SecurityCLIReadError.nonZeroExit(status: status, stderrLength: stderr.count)
        }

        return SecurityCLIReadResult(
            stdout: stdout,
            status: status,
            stderrLength: stderr.count,
            durationMs: durationMs)
    }

    private static func terminate(process: Process, processGroup: pid_t?) {
        guard process.isRunning else { return }
        process.terminate()
        if let processGroup {
            kill(-processGroup, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            usleep(50000)
        }
        if process.isRunning {
            if let processGroup {
                kill(-processGroup, SIGKILL)
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }
    #else
    func loadFromClaudeKeychainViaSecurityCLI() -> ClaudeOAuthCredentials? { nil }
    func claudeKeychainFingerprint() -> String? { nil }
    #endif
}
