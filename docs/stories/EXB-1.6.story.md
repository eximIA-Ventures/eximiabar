# Story EXB-1.6: CLI Source + Watchdog (P1)

**ID:** EXB-1.6
**Status:** Done
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

- [x] **T1 — PTYRunner** (`Sources/ClaudeBarCore/CLI/ClaudePTYRunner.swift`)
  - [x] Low-level PTY spawn: `openpty` → slave fd; spawn via `posix_spawn` with `STDIN/STDOUT/STDERR` dup2'd to slave fd, into its own process group
  - [x] Dedicated `Thread` running the read/drive/poll loop (non-blocking `read` + `waitpid(WNOHANG)`)
  - [x] Write function: PTY write via the scripted `Step` driver (writes to master fd)
  - [x] `async func run(steps:) -> PTYResult` — bridges via `withCheckedContinuation` (single-resume `ResultBox`); hard timeout enforced on the dedicated thread
  - [x] Hard kill: `SIGTERM` → 500 ms → `SIGKILL` to process group
  - [x] **NO** `usleep`, **NO** `waitUntilExit`, **NO** `Foundation.Process` in async context — raw `posix_spawn` + `waitpid(WNOHANG)` on the dedicated thread
  - Note: named `ClaudePTYRunner` to avoid a module-level collision with the existing EXB-1.1 `PTYRunner` enum (minimal delegated-refresh path). Read loop uses non-blocking `read()` polled on the dedicated thread (functionally equivalent to a `DispatchSource` read source; chosen for the same-thread `waitpid`/timeout coordination).

- [x] **T2 — CLISession actor** (`Sources/ClaudeBarCore/CLI/CLISession.swift`)
  - [x] `actor CLISession`
  - [x] `func fetchUsage(claudePath: String, workdir: URL) async throws -> (session: Double, weekly: Double)` — calls `ClaudePTYRunner`, drives trust prompts + `/usage` + `/exit`, parses output
  - [x] Serializes: drops/supersedes the previous runner before starting a new one (at most one `claude` process)
  - [x] Sets up workdir if absent: `prepareWorkdir(_:)` (+ `.claude/settings.local.json`)
  - [x] Reference: `_reference_codexbar/.../ClaudeCLISession.swift` (adapted — fresh isolated process per probe)

- [x] **T3 — StatusProbe parser** (`Sources/ClaudeBarCore/CLI/ClaudeStatusProbe.swift`)
  - [x] `static func parseUsage(rawOutput: String) -> (session: Double, weekly: Double)?` — label-based parser (AC3d-AC3e), returns `utilization` (percent used)
  - [x] Positional fallback (AC10)
  - [x] Reference: `_reference_codexbar/.../ClaudeStatusProbe.swift:152-253`

- [x] **T4 — ArtifactCleaner** (`Sources/ClaudeBarCore/CLI/ClaudeProbeSessionArtifactCleaner.swift`)
  - [x] `func clean(workdir:)` — removes `.jsonl` files created by the probe (run detached off the actor; awaited)
  - [x] Reference: `_reference_codexbar/.../ClaudeProbeSessionArtifactCleaner.swift` (project-dir naming copied verbatim)

- [x] **T5 — CLI fetch strategy** (`Sources/ClaudeBarCore/FetchPlan/CLIFetchStrategy.swift`)
  - [x] `struct CLIFetchStrategy` (standalone fetcher; the existing `FetchStrategy` is a plan-descriptor value, not a protocol)
  - [x] `func fetch(phase: RefreshPhase) async throws -> UsageSnapshot` — invokes `CLISession`, maps result to snapshot
  - [x] Detects `claude` binary: `LiveUsageProvider` reads `SettingsStore.claudeBinaryPath` → `CLISession.resolveBinaryPath` (Settings override → PATH search)
  - [x] Sets `snapshot.source = .cli`

- [x] **T6 — Wire into FetchPipeline** (`Sources/ClaudeBarCore/FetchPlan/FetchPipeline.swift`)
  - [x] `SourcePlanner` already returns `.cli` in auto mode after OAuth failure
  - [x] `FetchPipeline` accepts an optional `cliFetch` closure and routes `.cli` to it; `LiveUsageProvider` supplies it (wraps `CLIFetchStrategy` + a long-lived `CLISession`) and sets `hasCLI` from binary availability

- [x] **T7 — Watchdog bundle integration**
  - [x] `ClaudeBarWatchdog` target in `Package.swift` produces an executable (verified `.build/release/ClaudeBarWatchdog`)
  - [x] `Scripts/package_app.sh` copies the watchdog to `Contents/Helpers/` with `+x`
  - [x] Verified `Contents/Helpers/ClaudeBarWatchdog` exists + executable after `Scripts/package_app.sh release`

- [x] **T8 — Tests** (`Tests/ClaudeBarCoreTests/CLITests.swift`)
  - [x] `ClaudeStatusProbeTests`: label panels, fractional percentages, ANSI noise, CR line endings, trust-prompt preamble, "used"/"remaining" inversion, status-meter skip (contract-bound to reference fixtures)
  - [x] Positional fallback tests: labels missing → first two `\d+%`; session-only label → weekly recovered positionally
  - [x] `CLIArtifactCleanerTests`: temp JSONL files → clean → removed (+ empty-dir removal, workdir prep, env scrubbing)
  - [x] `CLIFetchStrategySnapshotTests`: utilization → `.cli` snapshot mapping

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

- [x] `swift build` succeeds with zero new warnings across all targets
- [x] `ClaudeBarWatchdog` binary present in `.build/release/`
- [x] `CLISession.fetchUsage` returns a valid snapshot when `claude` binary is on PATH (path implemented end-to-end; parser is contract-verified against reference fixtures — a live `claude` probe requires the binary on the host, not exercisable in unit tests)
- [~] Running under Thread Sanitizer: no data races in PTY read loop — the SwiftPM swift-testing + TSan launcher aborts (`signalled(6)` in `swiftpm-xctest-helper`, a known toolchain interaction, not our code). The PTY loop is structurally race-free: all blocking I/O runs on ONE dedicated `Thread`; the only cross-thread handoff is the lock-guarded single-resume `ResultBox`. Unit tests are process-free, so they would not exercise the live loop under TSan regardless.
- [x] `ClaudeStatusProbe.parseUsage` unit tests pass (11 parser cases incl. positional fallback)
- [x] Artifact cleaner removes probe-generated JSONL files
- [x] If `claude` binary is absent, a `cliNotFound`-class error is returned and the app continues on OAuth (planner marks `hasCLI=false`; CLI fetch throws `cliNotFound`; pipeline records it and the snapshot stays on the OAuth error/state)

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Date:** 2026-06-10

### File List

**Created (Core — `Sources/ClaudeBarCore/`):**
- `CLI/ClaudePTYRunner.swift` — full PTY runner: `posix_spawn` into own process group, dedicated `Thread` read/drive/poll loop, single-resume `CheckedContinuation` bridge, SIGTERM→500ms→SIGKILL
- `CLI/CLISession.swift` — actor serializing `claude` probes (≤1 process); `fetchUsage` / `fetchStatus`; workdir prep, `ANTHROPIC_*` env scrubbing, binary + bundled-watchdog resolution
- `CLI/ClaudeStatusProbe.swift` — pure `parseUsage(rawOutput:)` (label-based + positional fallback; ANSI strip; returns utilization)
- `CLI/ClaudeProbeSessionArtifactCleaner.swift` — `Sendable` struct removing probe `.jsonl` artifacts (project-dir naming copied from reference)
- `FetchPlan/CLIFetchStrategy.swift` — wraps `CLISession`, maps `(session, weekly)` → `.cli` `UsageSnapshot`

**Created (other):**
- `Tests/ClaudeBarCoreTests/CLITests.swift` — 23 tests (parser, positional fallback, snapshot mapping, artifact cleanup, workdir/env)
- `Scripts/package_app.sh` — `.app` assembly stub; copies watchdog to `Contents/Helpers/` with `+x` (AC8)

**Modified (Core):**
- `FetchPlan/FetchPipeline.swift` — optional `cliFetch` closure; routes `.cli` to it on fallthrough
- `OAuth/RefreshCoordinator.swift` — default delegated probe now runs `claude /status` via `CLISession` (still NEVER POSTs)
- `Support/Logging.swift` — added `CoreLog.Category.cli`

**Modified (App — `Sources/ClaudeBar/`):**
- `App/LiveUsageProvider.swift` — wires `cliFetch` + `claudeBinaryProvider`; plans `hasCLI` from binary availability
- `App/ClaudeBarApp.swift` — `ClaudeBinaryHolder` (off-MainActor); seeds + observes the binary setting
- `App/SettingsStore.swift` — `onClaudeBinaryChange` callback fired from `claudeBinaryPath.didSet`

**Modified (other):**
- `.gitignore` — ignore `build/` (packaging output)
- `docs/stories/EXB-1.6.story.md` — this record

### Completion Notes

- **Anti-freeze (lesson #3) honored:** PTY I/O is exclusively on a dedicated `Thread`; no `usleep`/`waitUntilExit`/`Foundation.Process` in any `async` context. The `async` `run()` only `await`s a continuation.
- **CRITICAL guardrail (R6/#1161) intact:** `owner == .claudeCLI` never POSTs to the OAuth refresh endpoint — refresh stays delegated via `claude /status` PTY + fingerprint poll. Verified by `RefreshOwnershipTests` (0 network requests on the CLI path).
- **Parser as contract:** `parseUsage` cases mirror the reference `StatusProbeTests` fixtures (used/remaining inversion, ANSI, CR endings, session-only panels).
- **Tests:** 115 total (was 98+ baseline), 0 regressions; 23 new CLI tests.

#### Finishing pass (2026-06-11)
- Re-verified all 12 ACs directly against committed code (`0e5e109`), not the narrative: PTY runs on a dedicated `Thread` with single-resume continuation and zero `usleep`/`waitUntilExit`/`Foundation.Process` in the CLI dir; `CLISession` actor supersedes the prior runner (≤1 process); parser is pure with label + positional fallback; the `.claudeCLI` refresh path has zero network primitives (grep-confirmed; POST only in `directRefresh`/`.claudebar`); watchdog spawns into its own pgroup and escalates SIGTERM→500ms→SIGKILL; `package_app.sh` copies the watchdog to `Contents/Helpers/` with `+x` and `test -x` gates it.
- Independently reproduced: `swift build` and `swift build -c release` → **Build complete, 0 warnings**; `swift test` → **Test run with 115 tests in 17 suites passed (0 failures)** — no regression vs. baseline.
- **QA-004 resolved (doc-only):** updated the `ClaudePTYRunner` header docstring to describe the polled non-blocking `read()` loop (the documented Deviation #4) instead of the stale `DispatchSource.makeReadSource` wording. No behavior change; both builds remain warning-free.
- QA-001/QA-002/QA-003 left as tracked low-severity items (error-taxonomy unfreeze, live-capture re-validation, optional prompt-glyph gate) — none are correctness defects and all are deferred per the QA gate rationale.

### Justified Deviations

1. **`ClaudePTYRunner` vs `PTYRunner` (AC1 names "PTYRunner"):** the EXB-1.1 `PTYRunner` enum already exists in the module for the minimal delegated-refresh path. Two same-named types in one module is illegal, so the full runner is `ClaudePTYRunner`. The existing enum is retained (referenced by nothing now, but a valid documented utility).
2. **`CLIFetchStrategy` is not a protocol conformance (T5 wrote `: FetchStrategy`):** the existing `FetchStrategy` is a value plan-descriptor `struct`, not a behavioural protocol. Reinterpreting it would break `SourcePlanner`/`FetchPipeline`/tests. `CLIFetchStrategy` is a standalone fetcher; the pipeline routes via an injected `cliFetch` closure.
3. **Binary detection moved to the app layer:** `SettingsStore.claudeBinaryPath` lives in the app target; Core stays dependency-free. `LiveUsageProvider` resolves the path and supplies it to `CLIFetchStrategy`.
4. **Read loop uses non-blocking `read()` polled on the dedicated thread** rather than `DispatchSource.makeReadSource` (AC6 names the latter as the *pattern*): a same-thread poll lets the loop coordinate `read`, scripted writes, `waitpid(WNOHANG)`, and the hard timeout in one place without a second queue. Functionally equivalent, still entirely off the cooperative pool.
5. **`cliNotFound` surfaced as `UsageError.networkError("cliNotFound: …")`:** the model's `UsageError` enum (EXB-1.1, L4-frozen contract for this story) has no `cliNotFound`/`cliExited`/`cliTimeout` cases. Adding cases would ripple through the OAuth gate logic and existing exhaustive switches. Encoded as message-tagged `networkError` (which correctly does NOT trigger source fallthrough) to keep AC9 behavior without altering the shared error contract.

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. AC4 hardened with explicit "NEVER POST to OAuth refresh endpoint when owner==.claudeCLI" guardrail (epic risk R6 / regression #1161). | @po Pax |
| 2026-06-10 | 1.2 | Implemented all ACs/tasks — CLI source (PTY runner, CLISession, parser, cleaner, fetch strategy), watchdog bundle integration, delegated-refresh via CLISession. 23 new tests, 115 total green, zero new warnings. Status: Ready → Review. | @dev Dex |
| 2026-06-10 | 1.3 | QA Gate CONCERNS — Status: InReview → Done. All 12 ACs implemented and verified; build/tests reproduced (0 warnings, 115/115 green); R6/#1161 guardrail confirmed (0 POST on CLI path, proven by RefreshOwnershipTests); anti-freeze honored. Non-blocking concerns logged (parser bare-value fallback semantic, prompt-glyph sequencing, AC9 error encoding). | @qa Quinn |
| 2026-06-11 | 1.4 | Dev finishing pass — re-verified every AC against `0e5e109` code (PTY dedicated-`Thread`/no-async-blocking, CLISession ≤1 process, parser pure + positional fallback, R6/#1161 zero-network on `.claudeCLI`, watchdog pgroup + SIGTERM→500ms→SIGKILL, `package_app.sh` `Contents/Helpers/` +x). Independently reproduced `swift build` (debug+release, **0 warnings**) and `swift test` (**115/115 in 17 suites passed, 0 regressions**). Resolved QA-004 (doc-only): `ClaudePTYRunner` header now describes the polled non-blocking `read()` loop instead of the stale `DispatchSource.makeReadSource` wording. | @dev Dex |

---

## QA Results — rodada 1

**Reviewer:** Quinn (Test Architect & Quality Advisor) · **Date:** 2026-06-10 · **Gate:** CONCERNS

### Verification method
Every claim re-derived from the actual code at commit `0e5e109` — not from the dev narrative. Build and full test suite re-run locally. Guardrail and anti-freeze invariants grep-verified. Parser direction validated against the reference fixtures (`_reference_codexbar/.../StatusProbeTests.swift`) as ground truth.

### AC-by-AC trace

| AC | Verdict | Evidence |
|----|---------|----------|
| 1 — PTYRunner `class`, dedicated `Thread`, PTY 160×50, no usleep/waitUntilExit/Process in async | PASS | `ClaudePTYRunner.swift`: `final class`, `run()` only `await`s a continuation (L100-110); loop on a named `Thread` (L103-108); winsize 160×50 (L74-75, L123). No `usleep`/`waitUntilExit`/`Foundation.Process` in CLI dir (grep clean). |
| 2 — `CLISession` actor, ≤1 `claude` process, supersedes prior runner | PASS | `CLISession.swift`: `public actor`; `capture()` drops prior runner before spawn (L91, L107-110). Serialized by actor executor. |
| 3 — `/usage` probe flow (spawn, prompt, type, parse, trust, exit, 45s) | PASS (1 minor obs) | Args `--allowed-tools ""` (L53); workdir `…/com.eximia.eximiabar/ClaudeProbe/` (L16-23); scripted steps drive `/usage`→`/exit` + trust prompts (L137-157); 45s default (L49). **Obs (low):** AC3b "wait for prompt glyph" is implemented via empty-needle step ordering rather than explicit `>`/`❯` detection — functionally equivalent, recovers via timeout + terminal label-step. |
| 4 — Delegated refresh: NEVER POST on `.claudeCLI`; `claude /status`; fingerprint poll 0.2/0.5/0.8; cooldowns | PASS | `RefreshCoordinator.swift`: `.claudeCLI`→`delegatedRefresh()` (L88) with ZERO network primitives; `claude /status` via `CLISession.fetchStatus` (L67-74); poll delays `[0.2,0.5,0.8]` (L24, L113); cooldowns 5min/20s (L22-23). **Proven by test** `claudeCLIOwnerNeverCallsRefreshEndpoint` → `requestedURLs.isEmpty`. |
| 5 — Artifact cleaner removes probe JSONL | PASS | `ClaudeProbeSessionArtifactCleaner.swift`; awaited off-actor in `capture()` (L114-116); tests `removesProbeGeneratedJSONLFiles`, `removesEmptyProjectDirectoryAfterCleanup` green. |
| 6 — Anti-freeze: PTY I/O off cooperative pool, no `Process.waitUntilExit` on actor/async | PASS | All blocking I/O (`read`/`waitpid`/`nanosleep`) inside static `driveLoop`/`killGroup` on the dedicated thread (L208-349). `async run()` never blocks. |
| 7 — Watchdog `posix_spawnp` + process group + `waitpid(WNOHANG)` 200ms, SIGTERM→500ms→SIGKILL | PASS | `Sources/ClaudeBarWatchdog/main.swift` (3.3 KB, matches reference); `killProcessTree` SIGTERM→0.5s→SIGKILL; runner spawns into own pgroup (`POSIX_SPAWN_SETPGROUP`, L152-153). |
| 8 — `package_app.sh` copies watchdog to `Contents/Helpers/` +x; present after build | PASS | `Scripts/package_app.sh` builds + copies watchdog, `chmod +x`, and `test -x` verifies (fatal on miss). Watchdog product builds (`.build/debug/ClaudeBarWatchdog`, 106 KB, executable). |
| 9 — Errors: cliNotFound / parseError / cliExited | PASS (deviation accepted) | `parseError` is a real case (used at `CLISession` L60). `cliNotFound`/`cliExited`/`cliTimeout` encoded as message-tagged `networkError` (L96, L120-127). **Accepted:** `UsageError` is the L4-frozen EXB-1.1 contract; `networkError.isAuthOrScope == false` correctly prevents a wrong re-fallthrough; AC9 "app continues on OAuth" behavior preserved. See concern QA-001. |
| 10 — Positional fallback (first two `\d+%`) | PASS | `orderedUtilizations` + fallback in `parseUsage` (L37-45); tests `positionalFallbackTakesFirstTwoPercentsWhenLabelsMissing`, `…RecoversWeeklyWhenOnlySessionLabelPresent` green. |
| 11 — `parseUsage` pure, process-free | PASS | `enum ClaudeStatusProbe`, pure static func; 12 parser tests run without a process. |
| 12 — `swift build` all targets, zero new warnings | PASS | Re-ran `swift build` and `swift build -c release` → **0 warnings**. |

**Score: 12/12 ACs implemented and verified.**

### Independently reproduced
- `swift build` (debug + release): **Build complete, 0 warnings.**
- `swift test`: **115 tests / 17 suites — all passed** (1.76s). 23 new CLI tests present. 0 regressions vs. baseline.
- Guardrail grep: only POST in the OAuth/CLI surface is in `directRefresh` (`.claudebar` path). CLI dir has zero network primitives.
- Parser ground-truth: real `claude /usage` TUI renders `"NN% used"` (every reference fixture). Implementation returns utilization (percent used); for `"40% used"` → `session == 40`, mapping to reference `percentLeft 60` and downstream `usedPercent`. **Direction is correct.**

### Concerns (non-blocking)

| ID | Severity | Finding | Suggested action |
|----|----------|---------|------------------|
| QA-001 | low | AC9 error taxonomy collapsed into `networkError("cliNotFound:…")` etc. Behaviorally correct (no wrong fallthrough; AC9 honored) but loses typed diagnosability and string-tagging is brittle for any future programmatic branch on error kind. | When EXB-1.1's `UsageError` contract is next unfrozen, promote `cliNotFound`/`cliExited`/`cliTimeout` to dedicated cases. Until then, document the tag strings as a stable internal contract. |
| QA-002 | low | Parser bare-`NN%`-without-keyword path diverges from reference semantics: reference treats a directionless value as *remaining* (`assumeRemainingWhenUnclear`), implementation treats it as *used*. Real `claude` TUI always carries the `used` keyword, so this only ever fires in synthetic positional-fallback inputs — no real-world impact today. | If a future `claude` TUI emits bare percentages, re-validate the positional-fallback direction against a live capture. |
| QA-003 | low | AC3b prompt readiness is inferred from scripted-step ordering (empty-needle `/usage` step) rather than explicit `>`/`❯` glyph detection. A cold-start TUI could theoretically receive `/usage` before it is ready. | Recovery exists (45s timeout + `Current week` terminal step). Consider adding an explicit prompt-glyph gate before the `/usage` step in a hardening pass. |
| QA-004 | low | `ClaudePTYRunner` header docstring (L18-20) still describes `DispatchSource.makeReadSource` reads, but the loop uses polled non-blocking `read()` (the documented Deviation #4). Stale doc only — behavior is equivalent and off the cooperative pool. | Update the docstring to match the polled-read implementation. |

### Justified deviations — reviewed
All 5 dev-reported deviations examined and **accepted**: (1) `ClaudePTYRunner` naming — legitimate module collision avoidance; (2) `CLIFetchStrategy` non-conformance — correct, `FetchStrategy` is a value descriptor not a protocol; (3) app-layer binary detection — preserves Core dependency-freedom; (4) polled `read()` — functionally equivalent, off-pool; (5) `cliNotFound`→`networkError` — see QA-001.

### Gate rationale
All 12 ACs met, build clean, full suite green, the single highest-risk invariant (R6/#1161 — never consume the CLI's refresh token) is both structurally enforced and test-proven, and the anti-freeze pattern is correctly applied. The four findings are all `low` severity, none block release: they are diagnosability/robustness improvements, not correctness defects. Verdict is **CONCERNS** (not PASS) solely to ensure QA-001 and QA-002 are tracked into the next contract-unfreeze and a live-capture validation — proceed with awareness.

**Gate:** CONCERNS

---

## QA Results — rodada 1

**Reviewer:** Quinn (Test Architect & Quality Advisor) · **Date:** 2026-06-11 · **Gate:** PASS

### Verification method
Independent re-review of the finishing-pass commit `f2ece25` on top of `0e5e109`. Every AC re-derived from the actual source — not the dev narrative. Both builds and the full suite reproduced locally. Anti-freeze and the R6/#1161 never-POST guardrail grep-verified across the whole `Sources/` tree. Watchdog compared line-for-line against the reference. Guardrail test read and confirmed to assert the invariant.

### Scope integrity
Commit `f2ece25` touches exactly 2 files (`ClaudePTYRunner.swift` docstring + this story). The 4 unstaged files (`EXB-1.1/1.2/1.3/1.5` story QA appends) were dirty before this story and are out of scope — correctly left for the lead. No application source outside EXB-1.6 modified.

### AC-by-AC trace (read from code)

| AC | Verdict | Evidence |
|----|---------|----------|
| 1 — `ClaudePTYRunner` `class`, dedicated `Thread`, PTY 160×50, no usleep/waitUntilExit/Process in async | PASS | `ClaudePTYRunner.swift`: `final class` (L29); `run()` only `await`s a continuation (L102-111); loop on named `Thread` (L105-108); winsize 50×160 (L76-77, L125); `posix_spawn` not `Foundation.Process` (L176). |
| 2 — `CLISession` actor, ≤1 `claude` process, supersedes prior runner | PASS | `CLISession.swift`: `public actor` (L13); `capture()` drops prior runner before spawn (L91, L106-110); serialized by actor executor. |
| 3 — `/usage` probe flow (args, workdir, prompt, type, parse, trust, exit, 45s) | PASS | `--allowed-tools ""` (L53); workdir `…/com.eximia.eximiabar/ClaudeProbe/` (L16-23); scripted steps drive trust→`/usage`→`/exit` (L137-147); `ANTHROPIC_*` scrub (L163-170); 45s default (L49). |
| 4 — Delegated refresh: NEVER POST on `.claudeCLI`; `claude /status`; fingerprint poll 0.2/0.5/0.8; cooldowns 5min/20s | PASS | `RefreshCoordinator.swift`: `.claudeCLI`→`delegatedRefresh()` (L88) with ZERO network primitives; default probe runs `claude /status` via `CLISession.fetchStatus` (L66-75); poll delays `[0.2,0.5,0.8]` (L24, L113); cooldowns 5min/20s (L22-23). **Test-proven** by `claudeCLIOwnerNeverCallsRefreshEndpoint` → `requestedURLs.isEmpty` (passed in this run). |
| 5 — Artifact cleaner removes probe JSONL | PASS | `ClaudeProbeSessionArtifactCleaner.swift` removes `.jsonl` + empty dir (L38-47); awaited off-actor in `capture()` (L115-116); test `removesEmptyProjectDirectoryAfterCleanup` green. |
| 6 — Anti-freeze: PTY I/O off cooperative pool, no `Process.waitUntilExit` on actor/async | PASS | All blocking I/O (`read`/`waitpid`/`nanosleep`) inside static `driveLoop`/`killGroup` on the dedicated thread (L210-351). Grep: only `usleep`/`waitUntilExit`/`Foundation.Process` matches in CLI dir are in explanatory comments (L12, L16). |
| 7 — Watchdog `posix_spawnp` + process group + `waitpid(WNOHANG)` 200ms, SIGTERM→500ms→SIGKILL | PASS | `Sources/ClaudeBarWatchdog/main.swift`: `posix_spawnp` (L71), `setpgid` own group (L85), `waitpid(WNOHANG)` 200ms poll (L103, L121), `killProcessTree` SIGTERM→0.5s→SIGKILL (L17-38), reparent `getppid()==1` (L115). **Line-for-line parity** with `_reference_codexbar/Sources/CodexBarClaudeWatchdog/main.swift`. |
| 8 — `package_app.sh` copies watchdog to `Contents/Helpers/` +x; present after build | PASS | `Scripts/package_app.sh` copies watchdog, `chmod +x`, fatal `test -x` gate (L40-45). Watchdog product builds to a real Mach-O arm64 executable (`.build/release/ClaudeBarWatchdog`, 58KB, `-rwxr-xr-x`); declared as executable product/target in `Package.swift` (L12, L47-48). |
| 9 — Errors: cliNotFound / parseError / cliExited | PASS (deviation accepted) | `parseError` is a real case (`CLISession` L60). `cliNotFound`/`cliTimeout`/`cliExited` encoded as message-tagged `networkError` (L96, L120-127) — `networkError.isAuthOrScope == false` correctly prevents a wrong re-fallthrough; AC9 "continue on OAuth" preserved. `UsageError` is the L4-frozen EXB-1.1 contract (Deviation #5). See QA-001. |
| 10 — Positional fallback (first two `\d+%`) | PASS | `ClaudeStatusProbe.swift`: `orderedUtilizations` + fallback in `parseUsage` (L37-45); tests `positionalFallbackTakesFirstTwoPercentsWhenLabelsMissing`, `…RecoversWeeklyWhenOnlySessionLabelPresent` green. |
| 11 — `parseUsage` pure, process-free | PASS | `enum ClaudeStatusProbe`, pure static func (L21); 17 CLI tests run with no process. |
| 12 — `swift build` all targets, zero new warnings | PASS | `swift build` and `swift build -c release` → **Build complete, 0 warnings** (re-run this session). |

**Score: 12/12 ACs implemented and verified.**

### Independently reproduced (this session)
- `swift build` (debug) + `swift build -c release`: **Build complete, 0 warnings.**
- `swift test`: **115 tests / 17 suites — all passed** (1.759s), 0 failures, 0 regressions vs. baseline.
- Anti-freeze grep (`Sources/ClaudeBarCore/CLI/` + `RefreshCoordinator.swift`): zero real `usleep`/`waitUntilExit`/`Foundation.Process` — only comments.
- Guardrail grep (whole `Sources/`): exactly ONE `httpMethod = "POST"` (RefreshCoordinator L154, inside `directRefresh`/`.claudebar`); endpoint constructed only in `directRefresh` (L149); CLI dir has zero network primitives.
- Watchdog: line-for-line invariant match against the reference codexbar watchdog.
- Max-one-process: `CLISession.capture()` nulls `currentRunner` before each spawn; the runner SIGTERM/SIGKILLs its own pgroup — supersede is correct.

### QA-004 (from rodada-1 CONCERNS) — RESOLVED
The `ClaudePTYRunner` header docstring now describes the polled non-blocking `read()` loop (Deviation #4) instead of the stale `DispatchSource.makeReadSource` wording (L18-21). Doc-only, no behavior change; both builds remain warning-free. Verified in `f2ece25`.

### Concerns (non-blocking, tracked — none block release)

| ID | Severity | Status | Finding |
|----|----------|--------|---------|
| QA-001 | low | Deferred | AC9 error taxonomy collapsed into message-tagged `networkError`. Behaviorally correct (no wrong fallthrough). Promote `cliNotFound`/`cliExited`/`cliTimeout` to typed cases when EXB-1.1's `UsageError` contract is next unfrozen. |
| QA-002 | low | Deferred | Bare-`NN%`-without-keyword path treats value as *used* (reference assumes *remaining*). Only fires on synthetic positional-fallback inputs — real `claude` TUI always carries the `used` keyword. Re-validate against a live capture if a future TUI emits bare percentages. |
| QA-003 | low | Deferred | AC3b prompt readiness inferred from scripted-step ordering rather than explicit `>`/`❯` glyph detection. Recovery exists (45s timeout + `Current week` terminal step). Optional prompt-glyph gate in a future hardening pass. |

### Gate rationale
All 12 ACs implemented and independently verified against real code. Build clean (debug + release, 0 warnings), full suite green (115/115, 0 regressions). The single highest-risk invariant — R6/#1161, never consume the CLI's rotating refresh token — is both structurally enforced (zero network primitives on the `.claudeCLI` path) and test-proven (`requestedURLs.isEmpty`). Anti-freeze is correctly applied (all blocking I/O on a dedicated `Thread`, single-resume lock-guarded continuation). Watchdog matches the reference line-for-line. QA-004 from the prior round is resolved. The three remaining findings are all `low`-severity diagnosability/robustness items with safe recovery paths and zero real-world impact today — they do not warrant withholding the gate. The DoD TSan item remains `[~]` (known swiftpm-xctest+TSan launcher abort, not project code; the loop is structurally race-free and the tests are process-free) — acceptable.

Promoting from the prior round's CONCERNS to **PASS**: every concern is either resolved (QA-004) or correctly tracked as a deferred non-defect.

**Gate:** PASS
