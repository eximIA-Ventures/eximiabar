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

---

## QA Results — keychain CLI fix (rodada 1)

**Reviewer:** Quinn (Guardian) — Test Architect
**Date:** 2026-06-17
**Commit:** `ce058e3`
**Gate type:** results-criteria (não checklist) — verifiquei resultado real, não documentação

### 1. Primary read path IS the `/usr/bin/security` subprocess — CONFIRMED

`CredentialsStore.loadFromClaudeKeychain(strategy:)` — `CredentialsStore.swift:309-316`: quando `strategy == .securityCLIPrimary` (o default), chama `loadFromClaudeKeychainViaSecurityCLI()` ANTES de qualquer `SecItemCopyMatching` que leia o segredo. O subprocess em si: `CredentialsStore+SecurityCLI.swift:128` (`runClaudeSecurityCLIRead`) → `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. O `SecItemCopyMatching` de leitura do segredo (`readKeychainData`, linha 390) só é alcançado em fallback. PASS.

### 2. Nenhum caminho pode promptar — CONFIRMED

- `grep allowPrompt Sources/ Tests/` → **zero ocorrências**. A branch que removia o no-UI foi eliminada.
- 3 call-sites REAIS de `SecItemCopyMatching` em `CredentialsStore.swift` (linhas 228, 354, 390). Auditei cada um: os 3 têm `KeychainNoUIQuery.apply(to: &query)` nas linhas imediatamente anteriores (verificado por inspeção das 12 linhas precedentes de cada site). Os "hits" do grep nas linhas 24/113/318 são docstrings/comentários, não chamadas.
- `KeychainNoUIQuery` (`Support/KeychainNoUIQuery.swift:22-30`) aplica DUAS defesas: `kSecUseAuthenticationContext` com `interactionNotAllowed=true` E `kSecUseAuthenticationUIFail` (resolvido via dlsym). Primitivo no-UI robusto, portado do CodexBar.
- `readKeychainData` (linha 381-404): aplica `KeychainNoUIQuery` incondicionalmente; em `errSecInteractionNotAllowed`/`errSecItemNotFound` retorna `nil`; em `errSecUserCanceled`/`errSecAuthFailed`/`errSecNoAccessForItem` registra denial e retorna `nil`. Nunca lança prompt, nunca throwa nesses casos. NEUTRALIZADO. PASS.

### 3. Build + test — RODEI

- `swift build -c release` → Build complete, zero warnings. PASS.
- `swift test --no-parallel` → **230 tests passed in 32 suites** (223 baseline + 7 novos), zero falhas, run serial limpo. Zero regressão. PASS.

### 4. Seleção do token válido/não-expirado — SÓLIDA

`loadFromClaudeKeychainViaSecurityCLI` (`CredentialsStore+SecurityCLI.swift:104-107`): após parse, `guard !credentials.isExpired` — um token expirado retorna `nil` e roteia para o fallback `newestClaudeKeychainCandidate()` (linhas 343-374), que ordena candidatos por `modificationDate` (desc) e pega o mais recente. Lógica correta para múltiplos itens de renovação. Teste `expiredCLITokenIsNotUsed` garante que o token expirado NUNCA é exposto. PASS.

**Achado relevante (não-bloqueante):** o payload real do keychain contém DOIS top-level keys: `mcpOAuth` E `claudeAiOauth`. O parser (`ClaudeOAuthCredentialModels.swift:66`) lê `claudeAiOauth` — que ESTÁ presente. Confirmei contra o item real: `claudeAiOauth.accessToken` presente (108 chars), `expiresAt` futuro (não-expirado), scopes completos. O `head -c 20` mostrou só `mcpOAuth` por ordem de serialização, mas o parser localiza `claudeAiOauth` corretamente. Sem impacto no fix.

### 5. Subprocess hygiene — COMPLETA

- **Timeout:** 1.5s hard (`securityCLIReadTimeout`, linha 35); loop de polling até deadline (linhas 164-167).
- **Off-main:** roda dentro do actor `CredentialsStore` (não `@MainActor`); callers usam `await`.
- **Process-group kill:** `setpgid` (linha 160) + `terminate()` faz SIGTERM no grupo, depois SIGKILL no grupo e no pid se persistir (linhas 189-205). Um `security` travado nunca wedge o actor.
- **exit≠0:** `guard status == 0` → lança `nonZeroExit`, capturado pelo `catch` que retorna `nil` (linha 111-114).
- **stdout vazio:** `sanitizeSecurityCLIOutput` tira newlines; `guard !sanitized.isEmpty else return nil` (linha 92).
- Nunca throwa para fora do reader. PASS.

### 6. Testes funcionais REAIS — EXECUTADOS

- `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w | head -c 20` → **exit 0, sem prompt**, payload real retornado. A fonte que o app usa lê sem prompt. CONFIRMADO.
- Item count: **1 item canônico** com esse service (não 4 nesta máquina); `acct=hugocapitelli`. A leitura `-w` (sem `-a`) retorna o match canônico — comportamento esperado.
- App buildado: bundle universal assinado (x86_64 + arm64), `codesign --verify --deep --strict` → exit 0. Launch direto do binário → processo vive 4s sem crash, sem erros de keychain no log de startup, termina limpo. CONFIRMADO.

### Risco residual & notas

- Em produção esta máquina tem 1 item (não os 4 da descrição); a lógica de seleção do mais-recente existe e é defensável, mas o cenário multi-item não foi exercitado contra keychain real (apenas via teste unitário do guard de expiração). Risco baixo — a lógica de ordenação por `modificationDate` é sound.
- Account-pinning do CodexBar não portado: justificado, já que o fallback no-UI não pode promptar de qualquer forma.
- Verificação por design (não consegui reproduzir o prompt recorrente original em sessão de QA, mas a causa-raiz — ACL sem nosso app + recriação por renovação — está empiricamente confirmada na story e o caminho primário agora usa a ferramenta que o item confia).

### Gate Decision

Todos os 6 critérios de resultado satisfeitos. Caminho primário é o subprocess confiável, prompt path neutralizado e auditado (zero `allowPrompt`, 3/3 SecItemCopyMatching no-UI), 230 testes verdes sem regressão, seleção de token sólida, subprocess com timeout/off-main/kill/error-handling completos, e fonte real lê com exit 0 sem prompt. App assinado roda sem crash.

— Quinn, guardião da qualidade 🛡️

VERDICT: PASS
