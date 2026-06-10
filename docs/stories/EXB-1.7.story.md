# Story EXB-1.7: Cost Scan Local (P1)

**ID:** EXB-1.7
**Status:** Ready
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

- [ ] **T1 — ProviderCost model** (already stubbed in S1; complete here)
  - [ ] `struct ModelCostEntry { model: String; date: Date; inputTokens: Int; outputTokens: Int; cost: Double }`
  - [ ] `struct ProviderCost { today: Double; last30Days: Double; todayTokens: Int; last30DaysTokens: Int; byModel: [ModelCostEntry] }`

- [ ] **T2 — Pricing** (`Sources/ClaudeBarCore/Cost/Pricing.swift`)
  - [ ] `actor Pricing`
  - [ ] `func costPerToken(model: String) async -> (input: Double, output: Double)` — cache 24 h, fetch from models.dev fallback on miss/error
  - [ ] Hardcoded fallback table (prices in USD per token):
    ```
    claude-opus-4:           input 0.000015, output 0.000075
    claude-sonnet-4:         input 0.000003, output 0.000015
    claude-3-5-sonnet:       input 0.000003, output 0.000015
    claude-haiku-3-5:        input 0.0000008, output 0.000004
    ```
  - [ ] Unknown model → fallback to `claude-sonnet-4` prices
  - [ ] Reference: `_reference_codexbar/Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift` (and `CostUsageFetcher.swift` for the fetch/cache flow)

- [ ] **T3 — Scanner** (`Sources/ClaudeBarCore/Cost/CostScanner.swift`)
  - [ ] `actor CostScanner`
  - [ ] `func scan(directories: [URL], costDays: Int, now: Date) async -> ProviderCost`
  - [ ] `FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])` — enumerate `.jsonl` files recursively
  - [ ] Byte-level pre-filter: read raw `Data`, split on `\n`, check `contains("\"type\":\"assistant\"") && contains("\"usage\"")` as ASCII byte search
  - [ ] JSON decode passing lines: `struct JSONLLine: Decodable { var type: String; var message: Message?; struct Message { var id: String; var model: String; var usage: Usage? }; struct Usage { var input_tokens: Int; var output_tokens: Int }; var requestId: String?; var timestamp: String? }`
  - [ ] Dedup: `var seen: [String: Int] = [:]` (key = `"messageId:requestId"`, value = byte offset); keep entry with higher offset
  - [ ] Aggregation: for each deduped entry, call `Pricing.costPerToken(model:)`, accumulate into `[DateModelKey: Totals]`
  - [ ] Incremental offset cache: persist `[filePath: lastOffset]` to `UserDefaults`

- [ ] **T4 — Directory enumeration helper** (`Sources/ClaudeBarCore/Cost/CostScanner.swift`)
  - [ ] Build directory list from: `~/.claude/projects`, `~/.config/claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, `~/.pi/agent/sessions` (if exists)
  - [ ] All path resolution via `FileManager.default.homeDirectoryForCurrentUser`

- [ ] **T5 — Wire into AppState** (`Sources/ClaudeBar/App/AppState.swift`)
  - [ ] After each `FetchPipeline.fetch()` completes, if `settingsStore.costEnabled`: `let cost = await CostScanner.shared.scan(...)`
  - [ ] `DisplaySnapshot.cost = cost`
  - [ ] If disabled: `DisplaySnapshot.cost = nil`

- [ ] **T6 — Wire into popover** (`Sources/ClaudeBar/Popover/UsageCardView.swift`)
  - [ ] Replace stub cost section (from S3) with real data from `snapshot.cost`
  - [ ] Cost detail submenu: `ForEach(snapshot.cost.byModel) { entry in Text("...") }`

- [ ] **T7 — Tests** (`Tests/ClaudeBarCoreTests/CostScannerTests.swift`)
  - [ ] Create temp JSONL test files with known content
  - [ ] Tests for AC14a–AC14e

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

- [ ] `swift build` succeeds with zero new warnings
- [ ] Cost section in popover shows `"Today: $X · NK tokens"` with real data from local JSONL files (assuming Claude Code is installed)
- [ ] `swift test --filter CostScannerTests` — all 5 test groups pass
- [ ] Pre-filter skips non-assistant lines without decoding them (verifiable by log count)
- [ ] Incremental scan: second scan of unchanged file reads 0 new bytes
- [ ] Cost section hidden when `SettingsStore.costEnabled == false`
- [ ] Thread Sanitizer: no races when scanner and AppState run concurrently

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. Corrected 4 reference paths: CostUsageScanner+Claude.swift and CostUsagePricing.swift live under Sources/CodexBarCore/Vendored/CostUsage/, not Providers/Claude/. | @po Pax |
