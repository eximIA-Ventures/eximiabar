# EPIC-EXB: exímIABar — macOS Menu Bar Rate Limit Monitor

**Status:** Draft
**Bundle ID:** com.eximia.eximiabar
**Repo:** /Users/hugocapitelli/Dev/eximia/eximiabar
**Reference:** _reference_codexbar/ (CodexBar, Peter Steinberger, MIT)

---

## Vision

exímIABar is a macOS menu bar app (Swift 6.2, SwiftPM, macOS 14+) that monitors Claude AI rate limits in real time. It reads OAuth credentials that Claude Code already maintains on the machine, calls the Anthropic usage endpoint, and renders a live progress meter in the menu bar — no setup, no extra auth, instant value.

It is a **faithful visual clone of CodexBar** stripped to Claude-only: same crab icon with rectangular cutouts, same popover card layout, same pace/color logic, same cost scan from local JSONL files — but rebuilt with an architecture that eliminates the three freeze root causes documented in the original's CHANGELOG.

**Scope approved:** P0 + P1 features. P2 features (Web/cookie source F8, status page F15, idle animations F18, quota flash F19, hide-personal-info F20) are explicitly out of scope.

---

## Problem Statement

The original CodexBar freezes the macOS WindowServer for multiple seconds on every menu open due to:
1. Synchronous NSMenu + SwiftUI layout inside the menu-tracking run loop
2. `@Observable` storm from a 77K-line store with many mutating properties
3. PTY subprocess calls saturating Swift's cooperative thread pool

exímIABar solves all three by design: `NSPanel` replaces `NSMenu` for the dropdown, a single immutable `DisplaySnapshot` replaces the observable store, and PTY runs on a dedicated `Thread` with a `CheckedContinuation` bridge.

---

## Architecture Summary

```
Sources/
  ClaudeBarCore/          — pure library, no UI, no AppKit
    Model/                UsageSnapshot, RateWindow, ClaudePlan, ProviderCost
    FetchPlan/            FetchStrategy, FetchPipeline, SourcePlanner
    OAuth/                CredentialsStore, UsageFetcher, RefreshCoordinator, gates
    CLI/                  PTYRunner (async, dedicated thread), CLISession (actor), parser, cleaner
    Cost/                 CostScanner, Pricing
    Support/              KeychainNoUIQuery, HTTPClient, ISO8601, Logging
  ClaudeBar/              — app target
    App/                  ClaudeBarApp, AppState (@MainActor, single snapshot), SettingsStore
    StatusItem/           StatusItemController, IconRenderer, AnimationDriver
    Popover/              UsagePanelController (NSPanel), UsageCardView, MetricRow, progress bar
    Settings/             SettingsWindow + 4 panes
    Notifications/        QuotaNotifier
  ClaudeBarWatchdog/      — copied literal from CodexBarClaudeWatchdog/main.swift
```

**Anti-freeze rules (transversal — every story that touches UI or I/O must enforce):**
- ZERO I/O on main thread (no `Data(contentsOf:)`, `SecItemCopyMatching`, JSON parse on MainActor)
- PTY/subprocess NEVER in Swift cooperative thread pool (use `Thread` + `CheckedContinuation`)
- Dropdown is `NSPanel`, never `NSMenu` + NSHostingView
- `AppState` publishes ONE immutable `DisplaySnapshot` per refresh cycle
- Timer = cancellable `Task` with `Task.sleep`, not DispatchTimer on main

---

## Feature Scope (P0 + P1)

| Feature | Priority | Story |
|---------|----------|-------|
| F1 Status item + crab icon | P0 | S2 |
| F2 Brand icon + % mode | P1 | S2 |
| F3 Dropdown popover card | P0 | S3 |
| F4 Pace | P0 | S3 |
| F5 Refresh pipeline | P0 | S4 |
| F6 OAuth source | P0 | S1 |
| F7 CLI source + watchdog | P1 | S6 |
| F8 Web source | P2 | OUT OF SCOPE |
| F9 Source planner | P0 | S1 |
| F10 Notifications | P0 | S4 |
| F11 Cost scan | P1 | S7 |
| F12 Launch at login | P0 | S5 |
| F13 Settings window | P0 | S5 |
| F14 Menu actions | P0 | S3 |
| F15 Status page polling | P2 | OUT OF SCOPE |
| F16 Watchdog process | P1 | S6 |
| F17 Keychain prompt policy | P0 | S1+S5 |
| F18 Idle animations | P2 | OUT OF SCOPE |
| F19 Quota warning flash | P2 | OUT OF SCOPE |
| F20 Hide personal info | P2 | OUT OF SCOPE |

---

## Story Execution Order

| Order | Story ID | Title | Rationale |
|-------|----------|-------|-----------|
| 1 | EXB-1.1 | Core OAuth Pipeline | Foundation — all UI stories depend on this data layer |
| 2 | EXB-1.2 | Status Item + Icon | Visible shell; depends on snapshot type from S1 |
| 3 | EXB-1.4 | AppState + Refresh Loop | Wires S1 fetcher to S2 icon via snapshot |
| 4 | EXB-1.3 | Popover NSPanel | Needs snapshot + icon already working |
| 5 | EXB-1.5 | Settings Window | Drives SettingsStore that S3/S4 already consume |
| 6 | EXB-1.6 | CLI Source + Watchdog | P1; extends the fetch pipeline from S1 |
| 7 | EXB-1.7 | Cost Scan Local | P1; standalone scanner, plugs into snapshot |
| 8 | EXB-1.8 | Packaging + Polish | Final; produces the distributable .app |

**MVP gate:** end of S5 — OAuth-only, fully functional, daily usable.
**Full P0+P1 gate:** end of S8.

---

## Key Risks

| # | Risk | Probability | Mitigation |
|---|------|-------------|------------|
| R1 | `/api/oauth/usage` is undocumented; Anthropic may change schema or block UA | MEDIUM-HIGH | Tolerant decoder (`DynamicCodingKey`); CLI fallback (S6) works while `claude` binary exists |
| R2 | Claude Code credential format changes (path, keychain service, JSON shape) | MEDIUM | Layered load order; fingerprint change detection; NEVER consume CLI refresh token |
| R3 | `claude` TUI changes → CLI parser breaks | MEDIUM | Positional fallback; CLI is P1, not P0; degrades to OAuth |
| R4 | Keychain ACL: new bundle ID → user will see prompt on first run | CERTAIN | Default policy "only on user action"; prefer `.credentials.json` file (no prompt) |
| R5 | Swift 6 StrictConcurrency with PTY continuations (leak/double-resume) | MEDIUM | Timeout guards on all `CheckedContinuation` waits; watchdog as final net |
| R6 | Refresh token rotation — consuming it breaks Claude Code login | CERTAIN (if violated) | Hard rule: NEVER call refresh directly when `owner == .claudeCLI`; delegate via `claude /status` PTY |
| R7 | JSONL cost log format changes | LOW-MEDIUM | Tolerant line parser; skip-on-error per line |
| R8 | MIT license attribution | — | LICENSE file must credit Peter Steinberger / CodexBar |

---

## Onda 4 (v1.1.0)

**Status:** Draft | **Target:** v1.1.0 | **Created:** 2026-06-11

Enhancement wave after the v1.0.0 MVP (Onda 1–3 = EXB-1.1 through EXB-1.8, all Done).

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-2.1 | Glassmorphism | @dev | NSPanel lost native menu material; NSVisualEffectView restores it |
| 2 | EXB-2.2 | Language Selector (en + pt-BR) | @dev | Full localization; depends on all UI strings being in place |
| 3 | EXB-2.3 | Local Dashboard | @dev | Requires CostScanner data model (EXB-1.7); new window with Swift Charts |
| 4 | EXB-2.4 | Auto-Updater via GitHub Releases | @dev | Requires published repo + release (EXB-2.5 sets that up); About pane update |
| 5 | EXB-2.5 | Distribution (@devops) | @devops | Publishes repo, tags v1.1.0, migrates install to /Applications |

**Execution order:** 2.1 → 2.2 → 2.3 → 2.4 → 2.5 (2.5 must be last — it creates the release that 2.4 checks against).

**Wave DoD:**
- [ ] All 5 stories Done
- [ ] `swift build -c release` zero warnings with all Onda 4 code
- [ ] `swift test` 130+ tests passing (no regression)
- [ ] GitHub release `v1.1.0` at `https://github.com/eximIA-Ventures/eximiabar/releases`
- [ ] App installed at `/Applications/ExímIABar.app`
- [ ] Auto-updater smoke test: Settings → About → Check for Updates returns "up to date" on v1.1.0

---

## Definition of Done (Epic)

- [ ] All 8 stories Done
- [ ] `swift build -c release` succeeds with zero new warnings
- [ ] App launches, shows icon in menu bar, opens NSPanel popover with live data
- [ ] OAuth credential load works on a machine with Claude Code installed
- [ ] CLI fallback activates when OAuth returns 401/403
- [ ] Cost scan displays today's spend from local JSONL files
- [ ] Settings window has 4 panes, launch-at-login works
- [ ] Package script produces signed ad-hoc `.app` with watchdog helper in `Contents/Helpers/`
- [ ] LICENSE file contains MIT attribution to Peter Steinberger / CodexBar
- [ ] Zero uses of `NSMenu` + NSHostingView for dynamic content
- [ ] Zero synchronous I/O calls on MainActor
