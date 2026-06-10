import Foundation

/// Serializes `claude` CLI probes so at most ONE process is alive at any time (AC2).
///
/// The actor holds a reference to the in-flight ``ClaudePTYRunner`` and a generation counter; a new
/// probe supersedes any older one (the previous run is allowed to finish/kill itself via its own
/// timeout — the runner already SIGTERM/SIGKILLs its process group). Serialization here means: only
/// one `fetchUsage` body advances at a time, guarded by the actor's executor.
///
/// Reference: `_reference_codexbar/.../ClaudeCLISession.swift` (adapted — the reference reuses a
/// long-lived warm session; we spawn a fresh, fully-isolated process per probe for simplicity and
/// to avoid the cooperative-pool hazards the reference works around).
public actor CLISession {
    /// The probe working directory: isolated so it never contaminates the user's real Claude
    /// sessions (AC3a). `~/Library/Application Support/com.eximia.eximiabar/ClaudeProbe/`.
    public static func defaultWorkdir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("com.eximia.eximiabar", isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
    }

    private let log = CoreLog.logger(CoreLog.Category.cli)
    private let cleaner: ClaudeProbeSessionArtifactCleaner
    private let watchdogLocator: @Sendable () -> String?

    /// The currently in-flight runner, if any. A new probe cancels (kills) it before starting.
    private var currentRunner: ClaudePTYRunner?

    public init(
        cleaner: ClaudeProbeSessionArtifactCleaner = ClaudeProbeSessionArtifactCleaner(),
        watchdogLocator: @escaping @Sendable () -> String? = CLISession.locateBundledWatchdog)
    {
        self.cleaner = cleaner
        self.watchdogLocator = watchdogLocator
    }

    /// Runs the `/usage` probe and returns `(session, weekly)` utilization percentages (0–100).
    ///
    /// - Parameters:
    ///   - claudePath: resolved `claude` binary (absolute path or name on PATH).
    ///   - workdir: isolated probe workdir (created if absent).
    ///   - timeout: hard limit; default 45 s (AC3h).
    public func fetchUsage(
        claudePath: String,
        workdir: URL = CLISession.defaultWorkdir(),
        timeout: TimeInterval = 45) async throws -> (session: Double, weekly: Double)
    {
        let raw = try await self.capture(
            claudePath: claudePath,
            arguments: ["--allowed-tools", ""],
            drive: Self.usageSteps(),
            workdir: workdir,
            timeout: timeout)

        guard let parsed = ClaudeStatusProbe.parseUsage(rawOutput: raw) else {
            let snippet = String(raw.suffix(400))
            throw UsageError.parseError("CLI /usage parse failed. Tail: \(snippet)")
        }
        return parsed
    }

    /// Runs `claude /status` (used by the delegated-refresh path) and returns the raw buffer.
    /// Does NOT parse usage; the caller observes the keychain fingerprint for change detection.
    public func fetchStatus(
        claudePath: String,
        workdir: URL = CLISession.defaultWorkdir(),
        timeout: TimeInterval = 12) async throws -> String
    {
        try await self.capture(
            claudePath: claudePath,
            arguments: ["--allowed-tools", ""],
            drive: Self.statusSteps(),
            workdir: workdir,
            timeout: timeout)
    }

    // MARK: - Core capture

    private func capture(
        claudePath: String,
        arguments: [String],
        drive: [ClaudePTYRunner.Step],
        workdir: URL,
        timeout: TimeInterval) async throws -> String
    {
        // AC2: cancel any previous runner before starting a new one. The runner kills its process
        // group on the next loop tick; we simply drop our reference and supersede it.
        self.currentRunner = nil

        try Self.prepareWorkdir(workdir)

        let resolved = Self.resolveBinaryPath(claudePath)
        guard let resolved else { throw UsageError.networkError("cliNotFound: \(claudePath)") }

        let config = ClaudePTYRunner.Configuration(
            binary: resolved,
            arguments: arguments,
            environment: Self.scrubbedEnvironment(workdir: workdir),
            workdir: workdir,
            watchdogPath: self.watchdogLocator(),
            timeout: timeout)

        let runner = ClaudePTYRunner(configuration: config)
        self.currentRunner = runner

        let result = await runner.run(steps: drive)
        self.currentRunner = nil

        // Best-effort cleanup of probe-generated JSONL artifacts (AC5). The filesystem work runs
        // off the actor (detached) so it never blocks the serialized probe path, and we await it so
        // the workdir is clean before the next probe can start.
        let cleaner = self.cleaner
        await Task.detached { cleaner.clean(workdir: workdir) }.value

        switch result.termination {
        case .spawnFailed:
            throw UsageError.networkError("cliNotFound: spawn failed for \(resolved)")
        case .timedOut:
            throw UsageError.networkError("cliTimeout")
        case .killed:
            throw UsageError.networkError("cliKilled")
        case let .exited(code):
            if code != 0, result.output.isEmpty {
                throw UsageError.networkError("cliExited: \(code)")
            }
            return result.output
        }
    }

    // MARK: - Scripted interaction steps

    /// Steps for the `/usage` probe (AC3b–AC3g):
    /// auto-answer trust prompts → type `/usage` → (panel renders) → type `/exit`.
    static func usageSteps() -> [ClaudePTYRunner.Step] {
        [
            // Trust prompt variants (AC3f). Normalized matching ignores spacing/case.
            ClaudePTYRunner.Step(whenSees: "Do you trust", send: "1\r"),
            ClaudePTYRunner.Step(whenSees: "Yes, proceed", send: "\r"),
            // Drive into the usage panel.
            ClaudePTYRunner.Step(whenSees: "", send: "/usage\r"),
            // Once the panel has rendered (labels present), close the session.
            ClaudePTYRunner.Step(whenSees: "Current week", send: "/exit\r", isTerminal: true),
        ]
    }

    /// Steps for `claude /status` — answer trust prompts, type `/status`, then `/exit`.
    static func statusSteps() -> [ClaudePTYRunner.Step] {
        [
            ClaudePTYRunner.Step(whenSees: "Do you trust", send: "1\r"),
            ClaudePTYRunner.Step(whenSees: "Yes, proceed", send: "\r"),
            ClaudePTYRunner.Step(whenSees: "", send: "/status\r"),
            ClaudePTYRunner.Step(whenSees: "Account", send: "/exit\r", isTerminal: true),
        ]
    }

    // MARK: - Environment + workdir

    /// Inherited environment with all `ANTHROPIC_*` keys removed (Dev Notes: environment scrubbing),
    /// PWD pinned to the isolated probe workdir, and deep-link registration disabled.
    static func scrubbedEnvironment(workdir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("ANTHROPIC_") {
            env.removeValue(forKey: key)
        }
        env["PWD"] = workdir.path
        return env
    }

    /// Creates the workdir (and a `.claude/settings.local.json` that disables deep-link
    /// registration) if absent (AC3a).
    static func prepareWorkdir(_ workdir: URL, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: workdir, withIntermediateDirectories: true)
        let claudeDir = workdir.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.local.json")
        if !fm.fileExists(atPath: settingsURL.path) {
            let settings = ["disableDeepLinkRegistration": "disable"]
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - Binary + watchdog resolution

    /// Resolves `claude` from an absolute path, common install locations, or `PATH`. Returns `nil`
    /// when no executable is found (→ the caller surfaces `cliNotFound`). Public so the app layer can
    /// resolve the configured binary for `hasCLI` planning and the delegated-refresh probe.
    public static func resolveBinaryPath(_ binary: String) -> String? {
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
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Locates the bundled `ClaudeBarWatchdog` helper at `Contents/Helpers/ClaudeBarWatchdog`
    /// relative to the running executable / app bundle. Returns `nil` (degrade to direct spawn) if
    /// not found — e.g. when running under `swift test` rather than the packaged `.app`.
    public static func locateBundledWatchdog() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        // Packaged app: …/ExímIABar.app/Contents/Helpers/ClaudeBarWatchdog
        if let resourceURL = Bundle.main.resourceURL {
            // resourceURL → Contents/Resources; helper sits in Contents/Helpers.
            let helpers = resourceURL
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("ClaudeBarWatchdog")
            candidates.append(helpers.path)
        }
        // Alongside the executable (SwiftPM `.build/...` layout or ad-hoc copy).
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("ClaudeBarWatchdog").path)

        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        return nil
    }
}
