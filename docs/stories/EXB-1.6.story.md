# Story EXB-1.6: CLI Source + Watchdog (P1)

**ID:** EXB-1.6
**Status:** Ready
**Depends on:** EXB-1.1 (CredentialsStore, FetchPipeline, SourcePlanner), EXB-1.4 (AppState, RefreshPhase)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user whose OAuth token is unavailable (expired, missing, or scope-limited),
**I want** exímIABar to fall back to scraping the `claude` CLI for usage data,
**so that** I still see rate limit info even when OAuth is broken.

---

## Acceptance Criteria

1. `PTYRunner` is a Swift `class` (NOT actor, NOT async function) that spawns the `claude` process in a PTY of size 160×50. The run loop runs on a **dedicated `Thread`** (not the Swift cooperative thread pool). External callers get an `async` interface via `withCheckedContinuation` + `DispatchSource.makeReadSource` for fd I/O. No `usleep`, no `waitUntilExit`, no `Foundation.Process.waitUntilExit` in any `async` context.
2. `CLISession` is an `actor` that serializes usage: at most ONE `claude` process is alive at any time. `CLISession` holds a reference to the current `PTYRunner` and cancels it before starting a new one.
3. CLI probe flow for `/usage`:
   a. PTY spawns `claude --allowed-tools ""` with environment scrubbed (`ANTHROPIC_*` variables removed), workdir `~/Library/Application Support/com.eximia.eximiabar/ClaudeProbe/`.
   b. Wait for the `claude` prompt (detect `>` or `❯` or any non-spinner terminal line).
   c. Type `/usage\n` into the PTY.
   d. Read output until the usage panel appears (detect labels `"Current session"` and `"Current week"` in the raw terminal buffer).
   e. Parse: extract percent values (e.g., `45%`) appearing on the same line as the label, then `remaining = 100 - percent`.
   f. Respond to trust prompts automatically: detect prompt text containing `"Do you trust"` or `"Allow"` → type `1\n` or `y\n` per format.
   g. Type `/exit\n` to close the session.
   h. Total timeout: 45 s hard limit. Any timeout → kill process, return `UsageError.timeout`.
4. Delegated refresh (from S1 §4.1, `owner == .claudeCLI`) — **CRITICAL GUARDRAIL:** when the credential owner is `.claudeCLI`, the app MUST NEVER POST to the OAuth refresh endpoint directly — consuming Claude Code's rotating refresh token breaks the user's `claude` login (regression #1161; epic risk R6, CERTAIN if violated). Refresh is ONLY ever delegated: `RefreshCoordinator` uses `CLISession` to run `claude /status` (same flow, detect status output), then polls keychain fingerprint at 0.2/0.5/0.8 s intervals to detect if a new token was written by the CLI, and re-reads the keychain without prompt. Cooldown: 5 min on success, 20 s on failure. Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift`.
5. `ClaudeProbeSessionArtifactCleaner`: after each CLI probe, delete any JSONL files created by the probe in the workdir (`~/Library/Application Support/com.eximia.eximiabar/ClaudeProbe/`). Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeProbeSessionArtifactCleaner.swift`.
6. **Anti-freeze (CRITICAL):** PTY I/O MUST NOT occur on the Swift cooperative thread pool. Implementation pattern:
   ```
   Thread { self.runPTYLoop() }.start()
   // runPTYLoop: uses DispatchSource.makeReadSource(fileDescriptor:) with DispatchQueue.init(label:)
   // bridges result back to async caller via CheckedContinuation
   ```
   Verified by: at no point is `Process.waitUntilExit()` called on an actor or `async` function.
7. **Watchdog process (F16):** `ClaudeBarWatchdog` binary (already copied in S1 T1 from `_reference_codexbar/Sources/CodexBarClaudeWatchdog/main.swift`) is embedded in the app bundle at `Contents/Helpers/ClaudeBarWatchdog`. The watchdog's role: the `claude` PTY subprocess is `posix_spawnp`'d into a separate process group; the watchdog monitors it with `waitpid(WNOHANG)` every 200 ms; on SIGTERM/SIGINT/SIGHUP from parent or when reparented to launchd, it sends SIGTERM to the process group, waits 500 ms, then sends SIGKILL.
8. `package_app.sh` (to be completed in S8) must copy `ClaudeBarWatchdog` to `Contents/Helpers/` and set `+x` permissions. In this story, verify it is present in the built `.app` bundle structure after `swift build`.
9. Error handling: if `claude` binary not found (not on PATH, not at custom path from Settings) → `UsageError.cliNotFound`. If parse fails (output format changed) → `UsageError.parseError` with raw snippet for debugging. If process exits non-zero → `UsageError.cliExited(code:)`.
10. Parser positional fallback: if labels `"Current session"` / `"Current week"` are not found (TUI format changed), fall back to positional parsing — take the first two percentage values (`\d+%`) in the raw output buffer as session and weekly respectively.
11. `ClaudeStatusProbe.parseUsage(rawOutput: String) -> (session: Double, weekly: Double)?` is a pure function, testable without a process.
12. `swift build` succeeds for all targets with zero new warnings.

---

## Tasks

- [ ] **T1 — PTYRunner** (`Sources/ClaudeBarCore/CLI/PTYRunner.swift`)
  - [ ] Low-level PTY spawn: `posix_openpt`, `grantpt`, `unlockpt`, `ptsname` → slave fd; fork via `posix_spawnp` with `STDIN_FILENO`/`STDOUT_FILENO` set to slave fd
  - [ ] Dedicated `Thread` running read loop using `DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: ioQueue)`
  - [ ] Write function: `func write(_ text: String)` — writes to master fd
  - [ ] `async func run() -> PTYResult` — bridges via `withCheckedThrowingContinuation`; timeout via `Task.sleep` race
  - [ ] Hard kill: `SIGTERM` → 500 ms → `SIGKILL` to process group
  - [ ] **NO** `usleep`, **NO** `waitUntilExit`, **NO** `Foundation.Process` in async context — use raw `posix_spawnp` + `waitpid(WNOHANG)` in the dedicated thread

- [ ] **T2 — CLISession actor** (`Sources/ClaudeBarCore/CLI/CLISession.swift`)
  - [ ] `actor CLISession`
  - [ ] `func fetchUsage(claudePath: String, workdir: URL) async throws -> (session: Double, weekly: Double)` — calls `PTYRunner`, handles trust prompts, parses output
  - [ ] Serializes: if previous runner is alive, cancel it first
  - [ ] Sets up workdir if absent: `FileManager.default.createDirectory(...)`
  - [ ] Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeCLISession.swift`

- [ ] **T3 — StatusProbe parser** (`Sources/ClaudeBarCore/CLI/ClaudeStatusProbe.swift`)
  - [ ] `static func parseUsage(rawOutput: String) -> (session: Double, weekly: Double)?` — label-based parser (AC3d-AC3e)
  - [ ] Positional fallback (AC10)
  - [ ] Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift:152-253`

- [ ] **T4 — ArtifactCleaner** (`Sources/ClaudeBarCore/CLI/ClaudeProbeSessionArtifactCleaner.swift`)
  - [ ] `func clean(workdir: URL) async` — removes `.jsonl` files created by probe
  - [ ] Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeProbeSessionArtifactCleaner.swift`

- [ ] **T5 — CLI fetch strategy** (`Sources/ClaudeBarCore/FetchPlan/CLIFetchStrategy.swift`)
  - [ ] `struct CLIFetchStrategy: FetchStrategy`
  - [ ] `func fetch(phase: RefreshPhase) async throws -> UsageSnapshot` — invokes `CLISession`, maps result to snapshot
  - [ ] Detects `claude` binary: check `SettingsStore.claudeBinaryPath` first, then `PATH` search (`which claude`)
  - [ ] Sets `snapshot.source = .cli`

- [ ] **T6 — Wire into FetchPipeline** (`Sources/ClaudeBarCore/FetchPlan/FetchPipeline.swift`)
  - [ ] `SourcePlanner` already returns `.cli` in auto mode after OAuth failure
  - [ ] Ensure `FetchPipeline` instantiates `CLIFetchStrategy` and routes to it on `shouldFallback`

- [ ] **T7 — Watchdog bundle integration**
  - [ ] Confirm `ClaudeBarWatchdog` target in `Package.swift` produces an executable
  - [ ] In `package_app.sh` (stub for S8): add `cp .build/release/ClaudeBarWatchdog ExímIABar.app/Contents/Helpers/`
  - [ ] Verify `Contents/Helpers/ClaudeBarWatchdog` exists after a manual `swift build -c release` + manual copy

- [ ] **T8 — Tests** (`Tests/ClaudeBarCoreTests/CLITests.swift`)
  - [ ] `ClaudeStatusProbeTests`: feed sample raw output strings (with/without fractional seconds, with trust prompt) → verify parsed percentages
  - [ ] Positional fallback test: malformed output → first two `\d+%` extracted
  - [ ] `ArtifactCleanerTests`: create temp JSONL files in workdir → clean → verify removed

---

## Dev Notes

### Why dedicated Thread (NOT async/await) for PTY
Swift's cooperative thread pool has a width equal to the number of CPU cores. `waitUntilExit()` or `usleep()` inside an `async` function permanently occupies one thread from the pool until the process exits. If the `claude` CLI takes 20+ seconds (which it can, especially on first run), this blocks the pool — all other async work in the app stalls.

The fix: wrap PTY I/O in a raw `Thread`:
```swift
final class PTYRunner {
    func start() -> AsyncStream<PTYEvent> {
        let (stream, continuation) = AsyncStream<PTYEvent>.makeStream()
        let thread = Thread {
            // run DispatchSource read loop here
            // send events to continuation
            // continuation.finish() when process exits
        }
        thread.start()
        return stream
    }
}
```

### Workdir path
`~/Library/Application Support/com.eximia.eximiabar/ClaudeProbe/`
Created on first run. Isolated to prevent contaminating the user's real Claude sessions.

### Environment scrubbing
Before `posix_spawnp`, remove all `ANTHROPIC_*` environment variables from the inherited environment. This prevents the probe from interfering with any existing API key configurations.

### Trust prompt detection
The `claude` CLI may display "Do you trust the files in this directory?" on first run in a new workdir. Detect substrings:
- `"Do you trust"` → type `1\n`
- `"Allow"` followed by `"(y/n)"` → type `y\n`

This must be handled before `/usage` is typed. The parser should consume and skip trust prompts.

### Parser — reference
`_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift:152-253`
Key parsing logic: find lines containing `"Current session"` → extract `\d+%` on that line → value is **percent used** (`remaining = 100 - percent`).

### Watchdog: copy verbatim
`_reference_codexbar/Sources/CodexBarClaudeWatchdog/main.swift` — 3.3 KB, 1 file. It uses `posix_spawnp` + process group + `waitpid(WNOHANG)` every 200 ms. Copy as-is, rename bundle ID comments if needed.

### Delegated refresh flow
When `RefreshCoordinator.delegatedRefresh()` is called:
1. Call `CLISession.fetchStatus(claudePath:)` — runs `claude /status`, not `claude --allowed-tools ""`
2. Wait for PTY output containing a status indicator
3. After PTY exits, poll keychain fingerprint: read `ClaudeOAuthCredentials.fingerprint()` at 0.2/0.5/0.8 s
4. If fingerprint changed → re-read credentials, return new `ClaudeOAuthCredentials`
5. If no change after 0.8 s → return `RefreshResult.noChange`
Reference: `_reference_codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift`

---

## Definition of Done

- [ ] `swift build` succeeds with zero new warnings across all targets
- [ ] `ClaudeBarWatchdog` binary present in `.build/release/`
- [ ] `CLISession.fetchUsage` returns a valid snapshot when `claude` binary is on PATH
- [ ] Running under Thread Sanitizer: no data races in PTY read loop
- [ ] `ClaudeStatusProbe.parseUsage` unit tests pass (5+ test cases including positional fallback)
- [ ] Artifact cleaner removes probe-generated JSONL files
- [ ] If `claude` binary is absent, `UsageError.cliNotFound` is returned and app continues on OAuth

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. AC4 hardened with explicit "NEVER POST to OAuth refresh endpoint when owner==.claudeCLI" guardrail (epic risk R6 / regression #1161). | @po Pax |
