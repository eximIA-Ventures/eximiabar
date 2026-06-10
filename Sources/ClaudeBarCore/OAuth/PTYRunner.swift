import Foundation
import os.lock

/// Minimal PTY-style subprocess runner used by the delegated refresh path.
///
/// EXB-1.1 only needs `claude /status` to be invokable off the cooperative thread pool
/// (anti-freeze rule). The full PTY/TUI machinery — watchdog wiring, output parsing —
/// lands in EXB-1.6 (CLI Source + Watchdog). This runner spawns the process on a
/// dedicated `Thread` and bridges completion via a `CheckedContinuation` with a timeout,
/// so it never blocks the main thread or saturates Swift's cooperative pool.
enum PTYRunner {
    /// Runs `claude /status` to nudge the CLI into refreshing its own OAuth token.
    /// Returns `true` if the process launched and exited (regardless of exit code — the
    /// caller decides success by observing the keychain fingerprint).
    static func runClaudeStatus(timeout: TimeInterval) async -> Bool {
        await self.run(
            binary: "claude",
            arguments: ["/status"],
            timeout: timeout)
    }

    /// Spawns `binary` with `arguments` on a dedicated thread and waits up to `timeout`.
    static func run(
        binary: String,
        arguments: [String],
        timeout: TimeInterval) async -> Bool
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Dedicated thread keeps subprocess management off the cooperative pool.
            let thread = Thread {
                let resolved = Self.resolveBinaryPath(binary) ?? binary
                let process = Process()
                process.executableURL = URL(fileURLWithPath: resolved)
                process.arguments = arguments
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice

                let box = ContinuationBox(continuation)

                do {
                    try process.run()
                } catch {
                    box.resumeOnce(false)
                    return
                }

                // Watchdog timer: terminate and resume if the process overruns.
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() >= deadline {
                        process.terminate()
                        box.resumeOnce(false)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                box.resumeOnce(true)
            }
            thread.name = "com.eximia.eximiabar.pty"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Resolves `claude` from common install locations + `PATH`. Returns nil if not found.
    private static func resolveBinaryPath(_ binary: String) -> String? {
        if binary.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
        }
        let env = ProcessInfo.processInfo.environment
        var searchPaths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        searchPaths.append(contentsOf: [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(env["HOME"] ?? "")/.local/bin",
        ])
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once, even across the dedicated
/// thread's branches. `Sendable` without suppression — the only mutable state is the
/// `resumed` flag, guarded by an `OSAllocatedUnfairLock`. The continuation itself is
/// `Sendable`.
private final class ContinuationBox: Sendable {
    private let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: Bool) {
        let shouldResume = self.resumed.withLock { alreadyResumed -> Bool in
            if alreadyResumed { return false }
            alreadyResumed = true
            return true
        }
        if shouldResume {
            self.continuation.resume(returning: value)
        }
    }
}
