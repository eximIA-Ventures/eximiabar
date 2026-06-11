# Story EXB-1.7: Cost Scan Local (P1)

**ID:** EXB-1.7
**Status:** Review
**Depends on:** EXB-1.1 (ClaudeBarCore lib, ProviderCost model), EXB-1.4 (AppState/DisplaySnapshot)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user who wants to track spending on Claude API,
**I want** exímIABar to scan my local Claude Code JSONL session logs and show today's and last 30 days' estimated cost and token count in the popover,
**so that** I have a local cost estimate without needing to visit the Anthropic dashboard.

---

## Acceptance Criteria

1. Scanner searches JSONL files in these directories (all must be checked):
   - `~/.claude/projects/**/*.jsonl`
   - `~/.config/claude/projects/**/*.jsonl`
   - `$CLAUDE_CONFIG_DIR/projects/**/*.jsonl` (if env var set)
   - Optional: `~/.pi/agent/sessions/**/*.jsonl` (if path exists)
2. Pre-filter for efficiency (byte-level scan before JSON parse): only parse lines that contain both the byte sequence `"type":"assistant"` AND `"usage"`. Lines failing this pre-filter are skipped without JSON decoding.
3. Deduplication key: `(message.id, requestId)` — the **last chunk** for a given key wins (later byte offset in file overrides earlier). This handles streaming: the final chunk contains the total token count.
4. Incremental scan: for each file, store the last scanned byte offset and file size in a cache (`UserDefaults` key `"costScanner.fileOffsets"` as `[String: Int64]`). On next scan, only parse bytes after the stored offset. If file size decreased (truncation), re-scan from 0.
5. Pricing: use models.dev pricing API to fetch cost per input/output token per model. Cache the result for 24 h (UserDefaults or file cache). Fallback: if network unavailable or cache cold, use hardcoded fallback prices for `claude-3-5-sonnet`, `claude-opus-4`, `claude-sonnet-4`, `claude-haiku-3-5` from the reference file.
6. Aggregation: for each JSONL line passing dedup, extract `model`, `usage.input_tokens`, `usage.output_tokens`, `timestamp` (ISO8601 from message metadata). Aggregate by (day, model): `{ date: Date, model: String, inputTokens: Int, outputTokens: Int, costUSD: Double }`.
7. Output (`ProviderCost` model): `today: Double` (USD), `last30Days: Double` (USD), `todayTokens: Int`, `last30DaysTokens: Int`, `byModel: [ModelCostEntry]` (for submenu detail).
8. `byModel` is used to populate the cost detail submenu in the popover: each entry shows `"claude-sonnet-4: $0.04 · 12K tokens"`.
9. `costDays` setting from `SettingsStore` (default 30) controls the window. Days are calendar days in the user's local time zone.
10. Scanner runs entirely off MainActor (`Task.detached(priority: .background)`). Result is folded into `DisplaySnapshot.cost` by `AppState` after each refresh cycle.
11. If `SettingsStore.costEnabled == false`, the scanner is not invoked and `DisplaySnapshot.cost = nil` (cost section hidden in popover).
12. Scan failure (permissions, parse errors): silently skip the offending file/line; never crash. Log errors via `os.Logger`.
13. **Anti-freeze:** file I/O (`FileManager.enumerator`, `Data(contentsOf:)`) MUST NOT run on MainActor.
14. Tests:
    a. Pre-filter test: line without `"type":"assistant"` is not decoded.
    b. Dedup test: two lines with same `(message.id, requestId)` → only the second (higher offset) is counted.
    c. Aggregation test: 3 lines from today + 2 from 31 days ago → only today's 3 appear in `today`, all 5 in `last30Days`.
    d. Pricing fallback test: with no network mock, hardcoded prices are used.
    e. Incremental scan test: process file once, add a line, scan again → only new line is parsed.

---

## Tasks

- [x] **T1 — ProviderCost model** (already stubbed in S1; complete here)
  - [x] `struct ModelCostEntry { model: String; date: Date; inputTokens: Int; outputTokens: Int; cost: Double }`
  - [x] `struct ProviderCost { today: Double; last30Days: Double; todayTokens: Int; last30DaysTokens: Int; byModel: [ModelCostEntry] }`

- [x] **T2 — Pricing** (`Sources/ClaudeBarCore/Cost/Pricing.swift`)
  - [x] `actor Pricing`
  - [x] `func costPerToken(model: String) async -> (input: Double, output: Double)` — cache 24 h, fetch from models.dev fallback on miss/error
  - [x] Hardcoded fallback table (prices in USD per token) — exactly as specified
  - [x] Unknown model → fallback to `claude-sonnet-4` prices
  - [x] Reference adapted: `CostUsagePricing.swift` normalization + `CostUsageFetcher` fetch/cache flow (via injectable `HTTPTransport`)

- [x] **T3 — Scanner** (`Sources/ClaudeBarCore/Cost/CostScanner.swift`)
  - [x] `actor CostScanner` (+ shared singleton so incremental caches survive refresh cycles)
  - [x] `func scan(directories: [URL]?, costDays: Int, now: Date) async -> ProviderCost`
  - [x] `FileManager.enumerator(at:includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey], options:[.skipsHiddenFiles])` — enumerate `.jsonl` recursively
  - [x] Byte-level pre-filter (`Data.containsAsciiSubsequence`): both `"type":"assistant"` and `"usage"` required before JSON decode (`JSONLByteScanner.swift`)
  - [x] JSON decode passing lines via `JSONSerialization` (matches reference's robust-to-drift approach)
  - [x] Dedup: `keyed["messageId:requestId"]` keeps the highest byte offset (last chunk wins); ID-less lines treated as distinct
  - [x] Aggregation per `(day, model)` via `Pricing.costPerToken`, accumulated into `[DayModelKey: Totals]`
  - [x] Incremental offset cache: `[filePath: lastOffset]` in `UserDefaults` (`costScanner.fileOffsets`) + persisted per-`(day,model)` aggregate

- [x] **T4 — Directory enumeration helper** (`Sources/ClaudeBarCore/Cost/CostScanner.swift`)
  - [x] Directory list from `~/.claude/projects`, `~/.config/claude/projects`, `$CLAUDE_CONFIG_DIR/projects` (comma-split), `~/.pi/agent/sessions` (if exists)
  - [x] Path resolution via `FileManager.homeDirectoryForCurrentUser`; de-duplicated

- [x] **T5 — Wire into AppState** (`Sources/ClaudeBar/App/LiveUsageProvider.swift`)
  - [x] Cost scan folded into the `AppState.Fetch` closure after each fetch (the closure runs in `AppState`'s `Task.detached`, off-main — AC10/AC13); gated by live `costEnabled`
  - [x] `DisplaySnapshot.cost = cost` on success and on failure (local estimate survives a usage error)
  - [x] If disabled: `cost = nil` (section hidden)

- [x] **T6 — Wire into popover** (`Sources/ClaudeBar/Popover/UsageCardView.swift`)
  - [x] Real data from `snapshot.cost`; whole section hidden when `cost == nil` (AC11)
  - [x] Cost detail submenu: expandable disclosure over `cost.byModel` (`"model: $X · NK tokens"`)

- [x] **T7 — Tests** (`Tests/ClaudeBarCoreTests/CostScannerTests.swift`)
  - [x] Temp JSONL fixtures with known content + isolated `UserDefaults` suites per test
  - [x] Tests for AC14a–AC14e (+ normalization, nested enumeration, truncation, missing-dir robustness)

---

## Dev Notes

### JSONL line format
Each line in Claude Code's JSONL logs is a JSON object. The important fields:
```json
{
  "type": "assistant",
  "message": {
    "id": "msg_01ABC",
    "model": "claude-sonnet-4-5",
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_read_input_tokens": 0,
      "cache_creation_input_tokens": 0
    }
  },
  "requestId": "req_01XYZ",
  "timestamp": "2025-12-25T10:00:00.000Z"
}
```
Streaming: Claude Code writes multiple chunks per request, each with partial token counts. The **last chunk** has the final total. The dedup by `(message.id, requestId)` with "higher offset wins" correctly takes the last chunk.

### Pre-filter rationale
Files can be large (hundreds of MB). Parsing every line as JSON would be slow. The pre-filter checks raw bytes before JSON decode:
```swift
let line = Data(rawLine) // raw bytes
let hasAssistant = line.contains(contentsOf: [UInt8]("\"type\":\"assistant\"".utf8))
let hasUsage = line.contains(contentsOf: [UInt8]("\"usage\"".utf8))
guard hasAssistant && hasUsage else { continue }
// only now: JSONDecoder().decode(...)
```
Reference: `_reference_codexbar/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift:27-53`

### Incremental scan offset cache
```swift
// Key: absolute file path
// Value: last byte offset processed
UserDefaults.standard.set(offsets as NSDictionary, forKey: "costScanner.fileOffsets")
```
On scan: read offset for each file. If current file size < stored offset → reset to 0 (truncation). Seek to offset before reading.

### Models.dev pricing API
`GET https://models.dev/api/models.json` — returns a JSON array with price fields. Parse `inputTokenPrice` and `outputTokenPrice` per model ID. Cache in memory + UserDefaults for 24 h.

Reference: `_reference_codexbar/Sources/CodexBarCore/CostUsageModels.swift`, `CostUsageFetcher.swift`, and `_reference_codexbar/Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift` (pricing sections).

### Reference implementation
`_reference_codexbar/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift:27-53,132-158,211-219`
Adapt: remove multi-provider logic, keep Claude-specific path scanning and dedup logic.

### Off-main enforcement
```swift
// CORRECT
Task.detached(priority: .background) {
    let cost = await CostScanner.shared.scan(...)
    await MainActor.run { appState.updateCost(cost) }
}
// WRONG
@MainActor func refresh() {
    let cost = await CostScanner.shared.scan(...)  // still awaits on main — blocks if not truly async
}
```
`CostScanner` is an actor; its methods are async but still run on the actor's executor. Calling from `Task.detached` ensures no main-thread involvement.

---

## Definition of Done

- [x] `swift build` succeeds with zero new warnings
- [x] Cost section in popover shows `"Today: $X · NK tokens"` with real data from local JSONL files (assuming Claude Code is installed)
- [x] `swift test --filter CostScannerTests` — all test groups pass (12 tests, covering AC14a–e + extras)
- [x] Pre-filter skips non-assistant lines without decoding them (verified by `preFilterSkipsLinesMissingMarkers` + `nonAssistantLinesDoNotContributeToCost`)
- [x] Incremental scan: second scan of unchanged file reads 0 new bytes (verified by `incrementalScanOnlyParsesNewLines` — third scan adds nothing)
- [x] Cost section hidden when `SettingsStore.costEnabled == false` (scan returns `nil` → `UsageCardView` omits the section)
- [x] Anti-freeze: `CostScanner` is a `public actor`; all file I/O runs on its executor, invoked from `AppState`'s `Task.detached` — never the MainActor (Swift 6 `-strict-concurrency=complete` build clean)

---

## Dev Agent Record (@dev Dex)

### Acceptance Criteria coverage
- AC1 dirs ✓ (`defaultDirectories`) · AC2 pre-filter ✓ · AC3 dedup last-chunk-wins ✓ · AC4 incremental offsets + truncation reset ✓ · AC5 pricing 24h cache + models.dev + fallback + unknown→sonnet ✓ · AC6 aggregation per (day, model) ✓ · AC7 `ProviderCost` output ✓ · AC8 `byModel` submenu ✓ · AC9 `costDays` window in local TZ ✓ · AC10 off-MainActor fold into snapshot ✓ · AC11 disabled→`nil`→section hidden ✓ · AC12 silent skip + `os.Logger` ✓ · AC13 anti-freeze ✓ · AC14a–e tests ✓

### IDS decisions
- REUSE: `HTTPClient`/`HTTPTransport` (pricing fetch), `CoreLog`, `ISO8601Decoder` (lenient timestamp parse), `PopoverFormatter.currency/tokenCount`, existing `ProviderCost` (extended), `SettingsStore.costEnabled/costDays`, the holder pattern (`PromptPolicyHolder`/`ClaudeBinaryHolder`) for off-main settings reads.
- ADAPT: reference `CostUsageJsonl.scan` → `JSONLByteScanner.scanLines` (extended to report per-line absolute byte offset for dedup); reference `Data.containsAscii` → `containsAsciiSubsequence([UInt8])` (raw-byte needle, no per-call re-encode); reference `normalizeClaudeModel` → trimmed `Pricing.normalize` for the priced families.
- CREATE: `Cost/Pricing.swift`, `Cost/CostScanner.swift`, `Cost/JSONLByteScanner.swift`, `Cost/CostDefaults.swift` (Sendable `UserDefaults` box for Swift-6), `ModelCostEntry`, `CostScannerTests.swift`.

### Justified deviations
- **Offset cache stores `[String: Int64]` (offset only), not `(offset, fileSize)`** (AC4 wording): after a full scan the stored offset already equals the prior file size, so truncation is detected by `liveFileSize < storedOffset`. Functionally equivalent, simpler, fully tested (`truncatedFileRescansFromZero`).
- **Incremental accumulation via a persisted per-`(day,model)` aggregate** (in addition to offsets): dedup-by-offset is single-pass; persisting the rolled-up aggregate lets each incremental scan add only the delta from new bytes without re-reading the whole file. Required to satisfy AC4 + AC6 together.
- **Wired through `LiveUsageProvider.makeFetch()` rather than literally inside `AppState`** (T5): `AppState` is intentionally fetch-agnostic (all fetch logic lives in the provider closure, per EXB-1.4 AC1). The scan runs inside `AppState`'s existing `Task.detached`, preserving the off-main guarantee.
- **models.dev parse converts per-million → per-token** and tolerates two payload layouts; on any schema drift it falls back to the hardcoded table (AC5/AC12).

### File List
**Modified:**
- `Sources/ClaudeBarCore/Model/ProviderCost.swift` — added `ModelCostEntry`; extended `ProviderCost` with `byModel`
- `Sources/ClaudeBar/App/LiveUsageProvider.swift` — `CostSettings`, cost-settings provider, scanner wiring into the fetch closure
- `Sources/ClaudeBar/App/SettingsStore.swift` — `onCostSettingsChange` callback fired by `costEnabled`/`costDays`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — `CostSettingsHolder` + seed/keep-in-sync + refresh on toggle
- `Sources/ClaudeBar/Popover/UsageCardView.swift` — gate cost section on presence (AC11); expandable `byModel` submenu (AC8)

**Created:**
- `Sources/ClaudeBarCore/Cost/Pricing.swift`
- `Sources/ClaudeBarCore/Cost/CostScanner.swift`
- `Sources/ClaudeBarCore/Cost/JSONLByteScanner.swift`
- `Sources/ClaudeBarCore/Cost/CostDefaults.swift`
- `Tests/ClaudeBarCoreTests/CostScannerTests.swift`

### Test result
`swift test` → **127 tests in 18 suites passed** (115 baseline + 12 new; zero regressions). `swift build` clean, zero warnings.

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. Corrected 4 reference paths: CostUsageScanner+Claude.swift and CostUsagePricing.swift live under Sources/CodexBarCore/Vendored/CostUsage/, not Providers/Claude/. | @po Pax |
| 2026-06-11 | 1.2 | Implemented all ACs (T1–T7). 5 files created, 5 modified. 12 new tests (AC14a–e + extras), 127 total green, build clean. Status: Ready → Review. | @dev Dex |
