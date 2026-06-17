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
/// before trusting it. If the CLI read is empty, unparseable, or expired, the caller falls back
/// to the no-UI `SecItemCopyMatching` enumeration (which selects the newest item by
/// modification date and never prompts). See `CredentialsStore.loadFromClaudeKeychain`.
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
                self.log.warning("Claude keychain security CLI output invalid; falling back")
                return nil
            }

            // Selection guard: the `-w` read may surface an older/expired renewal. Only trust a
            // live token here; an expired one routes the caller to the no-UI candidate enumeration.
            guard !credentials.isExpired else {
                self.log.debug("Claude keychain security CLI returned an expired token; falling back")
                return nil
            }

            self.log.debug("Claude keychain security CLI read succeeded")
            return credentials
        } catch {
            self.log.warning("Claude keychain security CLI read failed; falling back")
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
        guard FileManager.default.isExecutableFile(atPath: self.securityBinaryPath) else {
            throw SecurityCLIReadError.binaryUnavailable
        }

        let arguments = [
            "find-generic-password",
            "-s",
            self.claudeKeychainService,
            "-w",
        ]

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
    #endif
}
