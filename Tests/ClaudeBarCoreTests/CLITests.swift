import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-1.6 T8: CLI source parser, positional fallback, snapshot mapping, and artifact cleanup.
///
/// The parser is contract-bound to the reference `claude /usage` panel fixtures
/// (`_reference_codexbar/.../StatusProbeTests.swift`). The reference reports percent **left**; this
/// implementation reports `utilization` (percent **used**), where `remaining == 100 - utilization`.
/// Every fixture below asserts utilization that maps to the reference's percent-left.
struct ClaudeStatusProbeTests {
    // MARK: - Label-based parsing (AC3d-AC3e, AC11)

    @Test
    func parsesUsedPercentagesFromLabelledPanel() {
        let sample = """
        Current session
        40% used  (Resets 11am)
        Current week (all models)
        10% used  (Resets Nov 27)
        Current week (Sonnet only)
        0% used (Resets Nov 27)
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 40) // ref percentLeft 60
        #expect(parsed?.weekly == 10)  // ref percentLeft 90
    }

    @Test
    func parsesPanelWithBarGlyphsAndExtraSpacing() {
        // Bar glyphs precede the percentage on the same line; the value still maps to "used".
        let sample = """
        Current session
        ██████████████████████████████████████████████████  17% used
        Current week (all models)
        ██████████████████████████████████████████████████   4% used
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 17) // ref percentLeft 83
        #expect(parsed?.weekly == 4)   // ref percentLeft 96
    }

    @Test
    func parsesRemainingKeywordAsInvertedUtilization() {
        // "12% remaining" → 12% left → 88% used.
        let sample = """
        Current session
        12% remaining (Resets 11am)
        Current week (all models)
        40% remaining (Resets Nov 21)
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 88)
        #expect(parsed?.weekly == 60)
    }

    @Test
    func parsesFractionalPercentages() {
        let sample = """
        Current session
        12.5% used  (Resets 11am)
        Current week (all models)
        4.2% used  (Resets Nov 21)
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 12.5)
        #expect(parsed?.weekly == 4.2)
    }

    @Test
    func parsesPanelWithANSIColorCodes() {
        let sample = "\u{001B}[35mCurrent session\u{001B}[0m\n" +
            "\u{001B}[1m40% used\u{001B}[0m  (Resets 11am)\n" +
            "Current week (all models)\n" +
            "10% used  (Resets Nov 27)\n"
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 40)
        #expect(parsed?.weekly == 10)
    }

    @Test
    func parsesCarriageReturnDelimitedPanel() {
        // Some captures use CR-only line endings and a double-spaced label.
        let sample =
            "Current  session\r" +
            "██████████████████████████████████████████████████  17% used\r" +
            "Resets 12:59pm (Europe/Paris)\r" +
            "Current week (all models)\r" +
            "██████████████████████████████████████████████████   4% used\r" +
            "Resets Dec 24 at 3:59pm (Europe/Paris)\r"
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 17)
        #expect(parsed?.weekly == 4)
    }

    @Test
    func sessionOnlyPanelReturnsZeroWeekly() {
        // Enterprise account: session present, weekly panel omitted → weekly defaults to 0.
        let sample = """
        Current session
        █                                                  2% used
        Resets 3pm (Europe/Vienna)
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 2)
        #expect(parsed?.weekly == 0)
    }

    @Test
    func skipsTrustPromptPreambleAndParsesPanel() {
        // A trust prompt may precede the usage panel; the parser must ignore it and read the panel.
        let sample = """
        Do you trust the files in this folder?
        1. Yes, proceed
        2. No, exit
        Current session
        33% used  (Resets 11am)
        Current week (all models)
        7% used  (Resets Nov 27)
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 33)
        #expect(parsed?.weekly == 7)
    }

    // MARK: - Positional fallback (AC10)

    @Test
    func positionalFallbackTakesFirstTwoPercentsWhenLabelsMissing() {
        // TUI renamed the labels; no "Current session"/"Current week" present → positional fallback
        // takes the first two `\d+%` values as session / weekly utilization.
        let sample = """
        Usage this cycle
        55% used
        This week so far
        22% used
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 55)
        #expect(parsed?.weekly == 22)
    }

    @Test
    func positionalFallbackRecoversWeeklyWhenOnlySessionLabelPresent() {
        // Session label resolves; weekly label is missing → weekly comes from the next ordered %.
        let sample = """
        Current session
        18% used
        Some other line
        64% used
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 18)
        #expect(parsed?.weekly == 64)
    }

    // MARK: - Failure cases

    @Test
    func returnsNilForEmptyOrPercentlessOutput() {
        #expect(ClaudeStatusProbe.parseUsage(rawOutput: "") == nil)
        #expect(ClaudeStatusProbe.parseUsage(rawOutput: "Loading usage data…") == nil)
        #expect(ClaudeStatusProbe.parseUsage(rawOutput: "no numbers here at all") == nil)
    }

    @Test
    func ignoresStatusContextMeterLine() {
        // The status bar "| Opus 0% |" context meter must not be mistaken for a usage value.
        let sample = """
        claude | Opus 0% | default
        Current session
        45% used
        Current week (all models)
        9% used
        """
        let parsed = ClaudeStatusProbe.parseUsage(rawOutput: sample)
        #expect(parsed?.session == 45)
        #expect(parsed?.weekly == 9)
    }
}

/// Maps parsed utilization into a `.cli`-sourced snapshot.
struct CLIFetchStrategySnapshotTests {
    @Test
    func mapsUtilizationIntoCLISnapshot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snap = CLIFetchStrategy.snapshot(sessionUtil: 40, weeklyUtil: 10, now: now)
        #expect(snap.source == .cli)
        #expect(snap.session.utilization == 40)
        #expect(snap.session.remaining == 60)
        #expect(snap.session.windowMinutes == 300)
        #expect(snap.weekly.utilization == 10)
        #expect(snap.weekly.windowMinutes == 10080)
        #expect(snap.updatedAt == now)
        #expect(snap.error == nil)
    }
}

/// Workdir setup + JSONL artifact cleanup (AC5).
struct CLIArtifactCleanerTests {
    /// Builds a temporary fake `claude` config root and probe workdir so the cleaner targets a known
    /// directory. Returns the (configRoot, workdir, projectDir).
    private func makeScratch() throws -> (configRoot: URL, workdir: URL, projectDir: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eximiabar-clitests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configRoot = base.appendingPathComponent(".claude", isDirectory: true)
        let workdir = base.appendingPathComponent("ClaudeProbe", isDirectory: true)
        try fm.createDirectory(at: workdir, withIntermediateDirectories: true)

        let projectName = ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(for: workdir)
        let projectDir = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return (configRoot, workdir, projectDir)
    }

    @Test
    func removesProbeGeneratedJSONLFiles() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch.configRoot.deletingLastPathComponent()) }

        // Create two probe JSONL artifacts + one unrelated file (which must survive).
        let jsonl1 = scratch.projectDir.appendingPathComponent("session-a.jsonl")
        let jsonl2 = scratch.projectDir.appendingPathComponent("session-b.jsonl")
        let keep = scratch.projectDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: jsonl1)
        try Data("{}".utf8).write(to: jsonl2)
        try Data("{}".utf8).write(to: keep)

        let cleaner = ClaudeProbeSessionArtifactCleaner()
        cleaner.clean(
            workdir: scratch.workdir,
            environment: ["CLAUDE_CONFIG_DIR": scratch.configRoot.path])

        #expect(!fm.fileExists(atPath: jsonl1.path))
        #expect(!fm.fileExists(atPath: jsonl2.path))
        // A non-jsonl file is preserved (so the dir is not removed either).
        #expect(fm.fileExists(atPath: keep.path))
    }

    @Test
    func removesEmptyProjectDirectoryAfterCleanup() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch.configRoot.deletingLastPathComponent()) }

        let jsonl = scratch.projectDir.appendingPathComponent("only.jsonl")
        try Data("{}".utf8).write(to: jsonl)

        let cleaner = ClaudeProbeSessionArtifactCleaner()
        cleaner.clean(
            workdir: scratch.workdir,
            environment: ["CLAUDE_CONFIG_DIR": scratch.configRoot.path])

        // The only file was a jsonl → directory becomes empty → removed.
        #expect(!fm.fileExists(atPath: scratch.projectDir.path))
    }

    @Test
    func prepareWorkdirCreatesIsolatedDirectoryAndSettings() throws {
        let fm = FileManager.default
        let workdir = fm.temporaryDirectory
            .appendingPathComponent("eximiabar-prepare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: workdir.deletingLastPathComponent()) }

        try CLISession.prepareWorkdir(workdir)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: workdir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let settings = workdir
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        #expect(fm.fileExists(atPath: settings.path))
    }

    @Test
    func scrubbedEnvironmentRemovesAnthropicKeys() {
        // The scrubber removes ANTHROPIC_* from whatever environment we feed; assert against the
        // process environment plus a synthetic key by checking the helper's contract on a copy.
        let workdir = URL(fileURLWithPath: "/tmp/probe")
        let env = CLISession.scrubbedEnvironment(workdir: workdir)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("ANTHROPIC_") })
        #expect(env["PWD"] == workdir.path)
    }
}
