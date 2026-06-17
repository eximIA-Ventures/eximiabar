# Story EXB-3.8: Keychain — eliminar o pop-up recorrente lendo via `/usr/bin/security` CLI

**ID:** EXB-3.8
**Status:** Ready for Review
**Depends on:** EXB-1.5 (SettingsStore, PromptPolicy, keychain prompt policy), EXB-1.1 (CredentialsStore 5-layer load, no-UI keychain query)
**Epic:** EPIC-EXB
**Wave:** Onda 8 (v1.5.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** user running exímIABar alongside an active Claude Code login,
**I want** the app to read my Claude OAuth token **without ever showing the macOS keychain Allow/Deny dialog**,
**so that** I am not interrupted by a recurring permission pop-up every time Claude Code renews its token — matching the original CodexBar, which never prompts.

---

## Problem (empirically confirmed)

1. The Claude token lives only in the keychain (item `service="Claude Code-credentials"`); `~/.claude/.credentials.json` does **not** exist on this machine.
2. Our layer (e) read the secret via `SecItemCopyMatching`, which requires our app to be in the item's ACL. The item is created by Claude Code (Node) with a partition list trusting `/usr/bin/security` (`apple-tool:`) but **not** our app → the API prompts.
3. Claude Code **recreates** the item on every token renewal, zeroing the ACL → the prompt returns "periodically".
4. **Proof:** `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` reads the token with exit 0, **no prompt** — that is the path the item trusts.
5. The original CodexBar uses `/usr/bin/security` as the PRIMARY production strategy (`.securityCLIExperimental` default).

---

## Acceptance Criteria

### AC1 — CLI reader in Core
1. A new reader (`CredentialsStore+SecurityCLI.swift`) reads the Claude keychain secret by running `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` as a subprocess.
2. The subprocess runs off-main (the `CredentialsStore` actor), with a 1.5s hard timeout matching the reference; on timeout the whole process group is SIGTERM/SIGKILL'd so a stuck `security` never wedges the actor.
3. stdout is captured and trailing newlines stripped; a non-zero exit, launch failure, or timeout returns `nil` (never throws out of the reader) so layer (e) can fall back.

### AC2 — CLI reader is PRIMARY in layer (e)
4. In `loadFromClaudeKeychain`, the CLI reader is attempted **first**. If it yields parseable, non-expired credentials, they are used (owner `.claudeCLI`, source `.claudeKeychain`).
5. Only if the CLI read fails (empty / unparseable / expired) does layer (e) fall back to the no-UI `SecItemCopyMatching` path.
6. The read strategy is injected via a live, non-memoized provider (like the prompt policy) — `.securityCLIPrimary` (default) or `.securityFramework` (legacy opt-out).

### AC3 — Multiple-item selection
7. The Claude CLI leaves several renewal items behind. The background CLI read does **not** pass `-a`; the `security` tool returns the keychain's canonical match for the service, and the reader then parses and verifies `isExpired == false` before trusting it. An expired CLI token is rejected and routes to the fallback (which selects the newest candidate by modification date via the existing no-UI enumeration). Strategy documented in `CredentialsStore+SecurityCLI.swift`.

### AC4 — No code path prompts
8. `readKeychainData` is now **always** no-UI (`KeychainNoUIQuery` applied unconditionally); the previous `allowPrompt == true` branch that removed the no-UI policy is eliminated. On `errSecInteractionNotAllowed` / `errSecNoAccessForItem` it returns `nil` (records the denial for cooldown bookkeeping) instead of throwing/prompting.
9. All `SecItemCopyMatching` sites in `CredentialsStore` apply `KeychainNoUIQuery`. The user never sees the Allow/Deny pop-up again.

### AC5 — Setting connected & default ON
10. The orphan `useSecurityCLIReader` Settings flag is wired to the Core read strategy via a `KeychainReadStrategyHolder` (off-main, lock-light), seeded at launch and updated live on toggle. Default is **ON** (`.securityCLIPrimary`).

### AC6 — No regressions
11. `swift build` (signed) zero new warnings. `swift test --no-parallel` green with no regression to the baseline 223 tests; new tests cover the CLI path via a DEBUG subprocess override.
12. Fingerprint polling and all caches keep working. The `owner == .claudeCLI` refresh contract is untouched (never POST to the OAuth refresh endpoint for CLI-owned tokens).

---

## Dev Agent Record

### Agent Model Used
Opus 4.8 (1M) — @dev (Dex)

### File List

**New:**
- `Sources/ClaudeBarCore/OAuth/CredentialsStore+SecurityCLI.swift` — `/usr/bin/security` subprocess reader (off-main, 1.5s timeout, process-group kill, sanitize, parse + non-expired guard), DEBUG `SecurityCLIReadOverride` test seam
- `Tests/ClaudeBarCoreTests/SecurityCLIReaderTests.swift` — 7 tests (valid-token primary, expired rejection, empty/timeout/nonZeroExit fallthrough, legacy-strategy bypass, sanitizer)

**Modified:**
- `Sources/ClaudeBarCore/OAuth/CredentialsStore.swift` — `readStrategyProvider` (live, non-memoized) + both inits; layer (e) `loadFromClaudeKeychain(strategy:)` calls the CLI reader first, then no-UI fallback; `readKeychainData` is now unconditionally no-UI (prompt branch removed, returns `nil` on interaction-required); `log` made internal so the sibling extension can log; DEBUG override property + async setter; class/`load` doc updated
- `Sources/ClaudeBarCore/OAuth/PromptPolicy.swift` — new `KeychainReadStrategy` enum (`.securityCLIPrimary` default, `.securityFramework`)
- `Sources/ClaudeBar/App/SettingsStore.swift` — `useSecurityCLIReader` default → `true`, `didSet` fires `onSecurityCLIReaderChange`, `coreReadStrategy` computed snapshot, `onSecurityCLIReaderChange` callback
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — `KeychainReadStrategyHolder` (lock-light, off-main), seeded at launch + updated on toggle change, passed to provider
- `Sources/ClaudeBar/App/LiveUsageProvider.swift` — provider init forwards `readStrategyProvider` to `CredentialsStore`
- `Tests/ClaudeBarCoreTests/PromptPolicyTests.swift` — repurposed the no-memoization guard from prompt-policy to read-strategy (the prompt policy is no longer consulted in layer (e), since the CLI reader is prompt-free)
- `Tests/ClaudeBarTests/SettingsStoreTests.swift` — default assertion flipped to `true`; round-trip now persists `false` (the non-default opt-out)

### IDS Decisions
- **ADAPT** the reference `ClaudeOAuthCredentials+SecurityCLIReader` (gitignored `_reference_codexbar/`) into our actor's idiom — same subprocess/timeout/process-group-kill/sanitize, but returning parsed non-expired `ClaudeOAuthCredentials` and our DEBUG override shape instead of the reference's `ProviderInteraction`/metadata machinery.
- **CREATE** `KeychainReadStrategy` (2 cases) in Core — the reference's `ClaudeOAuthKeychainReadStrategy` lives in gitignored code and carries UserDefaults-preference plumbing we don't need (strategy is injected into the store).
- **REUSE** the existing `*Holder` + provider-closure pattern (prompt policy, claude binary, cost settings) for the read strategy — no new wiring mechanism.
- **REUSE** the existing no-UI enumeration (`newestClaudeKeychainCandidate`) for the fallback's newest-item selection.

### Multiple-item selection (strategy chosen)
The reference returns `nil` for the background account, so `security ... -w` runs WITHOUT `-a` and the keychain returns its canonical match. We replicate that: read via CLI (no `-a`) → parse → require `isExpired == false`. An expired CLI token is rejected and we fall through to the no-UI `SecItemCopyMatching` enumeration, which already sorts candidates by `modificationDate` and picks the newest. Account-pinning (the reference's prompt-safe Security.framework candidate probe on user actions) is intentionally not ported: it exists only to *avoid* a prompt that our unconditional no-UI fallback already cannot raise.

### Validation
- Empirical proof: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` → exit 0, no prompt.
- Code audit: zero remaining `allowPrompt`; `readKeychainData` applies `KeychainNoUIQuery` unconditionally; all 3 `SecItemCopyMatching` sites are no-UI; primary read is a subprocess (no SecItem prompt possible).
- `EXIMIA_SIGN_IDENTITY="eximIA Code Signing" make build`: signed universal `dist/ExímIABar.app` (7.7M), zero warnings.
- `swift test --no-parallel`: **230 tests passed** (baseline 223 + 7 new), 3 consecutive green runs. The single first-run flake was the known `CredentialLoadOrderTests` shared-`UserDefaults` race, not new code.

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-17 | 1.0 | Implemented all 6 ACs — `/usr/bin/security` CLI reader as primary layer-(e) path (off-main, 1.5s timeout), no-UI fallback, prompt path eliminated, orphan setting wired (default ON), 7 new tests. Status → Ready for Review | @dev Dex |
