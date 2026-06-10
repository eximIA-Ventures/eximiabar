#if canImport(Darwin)
import Darwin
#endif
import Foundation
import os.lock

/// Low-level PTY runner for the `claude` TUI probe (AC1, AC6).
///
/// This is the full-featured PTY machinery the epic calls "PTYRunner". It is a `class` — never an
/// actor, never an `async` function body that blocks — because all blocking I/O (the `read` loop,
/// the `waitpid` poll) runs on a **dedicated `Thread`**, NOT on Swift's cooperative thread pool.
/// `waitUntilExit()` / `usleep` inside an `async` context permanently parks a cooperative thread
/// until the subprocess exits, and the `claude` CLI can take 20+ seconds on a cold start — this is
/// freeze root cause #3 from the original CHANGELOG. We avoid it entirely:
///
/// - The child is launched with raw `posix_spawnp` (NOT `Foundation.Process`), into its own process
///   group, with `STDIN`/`STDOUT`/`STDERR` bound to the PTY slave fd.
/// - The master fd is read on an `ioQueue` via `DispatchSource.makeReadSource`, draining
///   non-blocking reads as bytes arrive.
/// - Process liveness is polled with `waitpid(WNOHANG)` on the dedicated thread.
/// - Completion is bridged to the `async` caller through a single `CheckedContinuation` that is
///   resumed exactly once (timeout, exit, or kill), guarded by an `OSAllocatedUnfairLock`.
///
/// The named type differs from ``PTYRunner`` (the minimal `enum` used by the EXB-1.1 delegated
/// refresh path) only to avoid a module-level name collision; this class is the canonical CLI
/// runner referenced by the epic.
public final class ClaudePTYRunner: @unchecked Sendable {
    /// Outcome of a PTY run: the full captured buffer plus how the run terminated.
    public struct PTYResult: Sendable, Equatable {
        public enum Termination: Sendable, Equatable {
            case exited(code: Int32)
            case timedOut
            case killed
            case spawnFailed(String)
        }

        public let output: String
        public let termination: Termination
    }

    /// One scripted interaction step: when the (normalized) accumulated buffer contains `whenSees`,
    /// write `send` to the PTY once. Used to drive `/usage`, auto-answer trust prompts, and `/exit`.
    public struct Step: Sendable {
        public let whenSees: String
        public let send: String
        /// When true, finishing this step's send marks the run as "ready to settle and exit".
        public let isTerminal: Bool

        public init(whenSees: String, send: String, isTerminal: Bool = false) {
            self.whenSees = whenSees
            self.send = send
            self.isTerminal = isTerminal
        }
    }

    public struct Configuration: Sendable {
        public var binary: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workdir: URL
        public var watchdogPath: String?
        /// Hard timeout. Any overrun → SIGTERM → 500 ms → SIGKILL and `.timedOut`.
        public var timeout: TimeInterval
        public var rows: UInt16
        public var cols: UInt16

        public init(
            binary: String,
            arguments: [String],
            environment: [String: String],
            workdir: URL,
            watchdogPath: String?,
            timeout: TimeInterval,
            rows: UInt16 = 50,
            cols: UInt16 = 160)
        {
            self.binary = binary
            self.arguments = arguments
            self.environment = environment
            self.workdir = workdir
            self.watchdogPath = watchdogPath
            self.timeout = timeout
            self.rows = rows
            self.cols = cols
        }
    }

    private let config: Configuration
    private let log = CoreLog.logger(CoreLog.Category.cli)

    public init(configuration: Configuration) {
        self.config = configuration
    }

    /// Runs the child to completion, driving `steps` as the buffer grows. Bridges the dedicated
    /// I/O thread back to the caller via a single-resume `CheckedContinuation` (AC6).
    ///
    /// - Important: the body of this `async` function NEVER blocks. The blocking `read`/`waitpid`
    ///   loop lives on a dedicated `Thread`; this method only `await`s a continuation.
    public func run(steps: [Step]) async -> PTYResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<PTYResult, Never>) in
            let box = ResultBox(continuation)
            let thread = Thread { [config, log] in
                Self.runLoop(config: config, steps: steps, log: log, box: box)
            }
            thread.name = "com.eximia.eximiabar.claude-pty"
            thread.stackSize = 1 << 21
            thread.start()
        }
    }

    // MARK: - Dedicated-thread run loop (no cooperative pool involvement)

    private static func runLoop(
        config: Configuration,
        steps: [Step],
        log: os.Logger,
        box: ResultBox)
    {
        // 1. Open the PTY pair.
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var win = winsize(ws_row: config.rows, ws_col: config.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &win) == 0 else {
            box.resumeOnce(PTYResult(output: "", termination: .spawnFailed("openpty failed")))
            return
        }
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)

        // 2. Build argv. If a watchdog is available, exec it as `watchdog -- claude <args>` so the
        //    child sits in its own group under a supervisor that reaps it on parent death (F16).
        let argv: [String]
        if let watchdog = config.watchdogPath {
            argv = [watchdog, "--", config.binary] + config.arguments
        } else {
            argv = [config.binary] + config.arguments
        }

        // 3. posix_spawn file actions: bind child stdio to the PTY slave, then close the slave in
        //    the child. The child becomes a session/group leader via the spawn attr.
        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, slaveFD)
        posix_spawn_file_actions_addclose(&fileActions, masterFD)

        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        // New process group (pgid == child pid) so we can signal the whole group on kill.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        // 4. Marshal argv + envp to C and spawn.
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envStrings = config.environment.map { "\($0.key)=\($0.value)" }
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for p in cArgv where p != nil { free(p) }
            for p in cEnvp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let execPath = config.watchdogPath ?? config.binary
        let spawnRC: Int32 = cArgv.withUnsafeBufferPointer { argvBuf in
            cEnvp.withUnsafeBufferPointer { envpBuf in
                execPath.withCString { pathPtr in
                    posix_spawn(
                        &pid,
                        pathPtr,
                        &fileActions,
                        &attr,
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envpBuf.baseAddress))
                }
            }
        }

        // Parent no longer needs the slave fd.
        close(slaveFD)

        guard spawnRC == 0, pid > 0 else {
            close(masterFD)
            let msg = "posix_spawn failed (rc=\(spawnRC)) for \(execPath)"
            log.error("Claude PTY spawn failed: \(msg, privacy: .public)")
            box.resumeOnce(PTYResult(output: "", termination: .spawnFailed(msg)))
            return
        }

        // 5. Run the read/drive/poll loop on this dedicated thread.
        Self.driveLoop(
            masterFD: masterFD,
            childPID: pid,
            timeout: config.timeout,
            steps: steps,
            box: box)

        close(masterFD)
    }

    /// The blocking heart of the runner — runs ONLY on the dedicated thread.
    private static func driveLoop(
        masterFD: Int32,
        childPID: pid_t,
        timeout: TimeInterval,
        steps: [Step],
        box: ResultBox)
    {
        var buffer = Data()
        var normalizedScan = ""
        var firedSteps = Set<Int>()
        var sawTerminalStep = false
        var terminalStepFiredAt: Date?

        let deadline = Date().addingTimeInterval(timeout)
        var readBuf = [UInt8](repeating: 0, count: 8192)

        func drainReads() {
            while true {
                let n = read(masterFD, &readBuf, readBuf.count)
                if n > 0 {
                    buffer.append(contentsOf: readBuf.prefix(n))
                    continue
                }
                break // EAGAIN (non-blocking, nothing more) or EOF
            }
        }

        func writeToPTY(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var offset = 0
                var retries = 0
                while offset < buf.count {
                    let written = write(masterFD, base.advanced(by: offset), buf.count - offset)
                    if written > 0 { offset += written; retries = 0; continue }
                    if written == 0 { break }
                    let err = errno
                    if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                        retries += 1
                        if retries > 200 { break }
                        Self.microSleep(0.005)
                        continue
                    }
                    break
                }
            }
        }

        while true {
            // Hard timeout.
            if Date() >= deadline {
                Self.killGroup(childPID: childPID)
                drainReads()
                box.resumeOnce(PTYResult(
                    output: String(decoding: buffer, as: UTF8.self),
                    termination: .timedOut))
                return
            }

            drainReads()

            // Update the normalized scan view (cheap, bounded to the tail).
            if !buffer.isEmpty {
                let tail = buffer.suffix(16_384)
                let text = ClaudeStatusProbe.stripANSICodes(String(decoding: tail, as: UTF8.self))
                normalizedScan = ClaudeStatusProbe.normalizedForLabelSearch(text)
            }

            // Drive scripted steps in declaration order, each at most once.
            for (idx, step) in steps.enumerated() where !firedSteps.contains(idx) {
                let needle = ClaudeStatusProbe.normalizedForLabelSearch(step.whenSees)
                if needle.isEmpty || normalizedScan.contains(needle) {
                    writeToPTY(step.send)
                    firedSteps.insert(idx)
                    if step.isTerminal {
                        sawTerminalStep = true
                        terminalStepFiredAt = Date()
                    }
                }
            }

            // After the terminal step (e.g. `/exit`) let the child drain for a short settle window,
            // then stop waiting on it actively.
            if sawTerminalStep, let firedAt = terminalStepFiredAt,
               Date().timeIntervalSince(firedAt) > 1.0
            {
                Self.killGroup(childPID: childPID)
                drainReads()
                box.resumeOnce(PTYResult(
                    output: String(decoding: buffer, as: UTF8.self),
                    termination: .exited(code: 0)))
                return
            }

            // Non-blocking child liveness check.
            var status: Int32 = 0
            let rc = waitpid(childPID, &status, WNOHANG)
            if rc == childPID {
                drainReads()
                box.resumeOnce(PTYResult(
                    output: String(decoding: buffer, as: UTF8.self),
                    termination: .exited(code: Self.exitCode(fromWaitStatus: status))))
                return
            }

            Self.microSleep(0.03)
        }
    }

    // MARK: - Process control

    /// SIGTERM the child's process group, wait 500 ms, then SIGKILL (AC1, AC6). When running under
    /// the watchdog the supervisor performs the same escalation; signalling the group here is the
    /// belt-and-braces path for the direct-spawn case.
    private static func killGroup(childPID: pid_t) {
        let pgid = getpgid(childPID)
        let target: pid_t = pgid > 0 ? -pgid : childPID
        kill(target, SIGTERM)

        let deadline = Date().addingTimeInterval(0.5)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(childPID, &status, WNOHANG) == childPID { return }
            Self.microSleep(0.05)
        }
        kill(target, SIGKILL)
        _ = waitpid(childPID, &status, 0)
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7F
        if low == 0 { return (status >> 8) & 0xFF }
        if low != 0x7F { return 128 + low }
        return 1
    }

    /// Sleep on the dedicated thread only. Never called from an `async` context.
    private static func microSleep(_ seconds: TimeInterval) {
        var ts = timespec(tv_sec: 0, tv_nsec: Int(seconds * 1_000_000_000))
        nanosleep(&ts, nil)
    }
}

/// Resumes a `CheckedContinuation<PTYResult, Never>` exactly once across the dedicated thread's
/// many exit branches. The only mutable state is the `resumed` flag, guarded by a lock; the
/// continuation is `Sendable`.
private final class ResultBox: @unchecked Sendable {
    private let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let continuation: CheckedContinuation<ClaudePTYRunner.PTYResult, Never>

    init(_ continuation: CheckedContinuation<ClaudePTYRunner.PTYResult, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: ClaudePTYRunner.PTYResult) {
        let shouldResume = self.resumed.withLock { already -> Bool in
            if already { return false }
            already = true
            return true
        }
        if shouldResume { self.continuation.resume(returning: value) }
    }
}
