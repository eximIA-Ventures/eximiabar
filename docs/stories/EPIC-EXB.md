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

## Onda 5 (v1.2.0)

**Status:** Draft | **Target:** v1.2.0 | **Created:** 2026-06-12

Polish and analytics wave after v1.1.0. Fixes the glassmorphism gap left by EXB-2.1 (materials were still effectively opaque), evolves the dashboard into a full analytics suite, and publishes a Homebrew tap for clean distribution.

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-3.1 | Glassmorphism REAL + Seção Appearance | @dev | Diagnosis confirmed materials are still opaque; adds user-configurable transparency + theme pane |
| 2 | EXB-3.2 | Dashboard Analytics v2 | @dev | Evolves EXB-2.3 baseline: period filter, projections, stacked tokens, heatmap, project breakdown, CSV export |
| 3 | EXB-3.3 | Homebrew Tap + Release v1.2.0 | @devops | Publishes tap at eximIA-Ventures/homebrew-tap; release cut after Onda 5 code is done |

**Execution order:** 3.1 → 3.2 → 3.3 (3.3 must be last — it cuts the release from completed code).

**Wave DoD:**
- [ ] All 3 stories Done
- [ ] `swift build -c release` zero warnings with all Onda 5 code
- [ ] `swift test` passing (no regression from Onda 4 baseline of 145 tests)
- [ ] GitHub release `v1.2.0` at `https://github.com/eximIA-Ventures/eximiabar/releases`
- [ ] Homebrew tap `eximIA-Ventures/homebrew-tap` public; `brew audit --cask eximiabar` clean
- [ ] App installed at `/Applications/ExímIABar.app` via cask or make install; `pgrep` confirms live
- [ ] README updated with Homebrew installation instructions

---

## Onda 6 (v1.3.0)

**Status:** Draft | **Target:** v1.3.0 | **Created:** 2026-06-12

Bug-fix and polish wave. Fixes two production bugs in the dashboard (broken period filters, UI jank), completes the visual layer with proper legends/axes/hover/empty states, and adopts macOS 26 Liquid Glass (`NSGlassEffectView`) with full fallback for macOS < 26.

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-3.6 | Dashboard: filtros, performance e completude visual | @dev | Bugs reportados em produção: filtros de período não funcionam + UI trava ao trocar período; completa visual com legendas, eixos, hover, empty states |
| 2 | EXB-3.5 | Liquid Glass nativo (macOS 26) | @dev | Substitui NSVisualEffectView por NSGlassEffectView em macOS 26; fallback automático em < 26; depende de SettingsStore/TransparencyLevel de EXB-3.1 |

**Execution order:** 3.6 primeiro (bugs de produção têm prioridade); 3.5 depois (feature de polish que não bloqueia fixes).

**Wave DoD:**
- [ ] All 2 stories Done
- [ ] `swift build -c release` zero warnings com todo o código Onda 6
- [ ] `swift test` passando (sem regressões da baseline de 201 testes)
- [ ] Trocar período no dashboard altera visivelmente todos os charts (BUG 1 resolvido)
- [ ] Abrir dashboard e trocar período nunca congela a UI (BUG 2 resolvido)
- [ ] Em macOS 26: painel, Settings e Dashboard usam `NSGlassEffectView`; em macOS < 26: comportamento Onda 5 preservado

---

## Onda 7 (v1.4.0)

**Status:** Draft | **Target:** v1.4.0 | **Created:** 2026-06-12

Polish visual profundo: tokens como protagonista nos KPI cards, heatmap com células uniformes e legível, gráficos interativos (hover em donut, tokens empilhados e novo gráfico modelos por dia), formatação K/M/B universal e correções de bugs visuais (truncagem de labels, overflow de tooltips).

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-3.7 | Dashboard polish: tokens-first, interatividade e visual | @dev | Feedback visual do usuário após ver screenshots reais: heatmap visual ruim, donut estático, tokens não estão em destaque, notação científica na legenda, labels truncados |

**Execution order:** 3.7 (única story da onda).

**Wave DoD:**
- [ ] EXB-3.7 Done
- [ ] `swift build -c release` zero warnings com todo o código Onda 7
- [ ] `swift test` passando (sem regressões da baseline de 207 testes)
- [ ] KPI cards exibem tokens como número principal em todos os 5 cards
- [ ] Heatmap legível: células uniformes, gradiente brand, legenda K/M/B (zero notação científica)
- [ ] Donut com hover interativo e tooltip completo
- [ ] Novo gráfico "Modelos por dia" visível com cores consistentes

---

### Onda 8 — Keychain prompt fix (v1.5.0)

**Status:** Draft | **Target:** v1.5.0 | **Created:** 2026-06-17

Elimina o pop-up recorrente de keychain (Allow/Deny). O item `"Claude Code-credentials"` é criado pelo Claude Code com partition list que confia em `/usr/bin/security` mas não no nosso app, e é recriado a cada renovação de token → o `SecItemCopyMatching` promptava periodicamente. Solução: ler o segredo via `/usr/bin/security ... -w` (caminho confiável, sem prompt) como estratégia PRIMÁRIA, com fallback no-UI; nenhum caminho de código promanta mais.

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-3.8 | Keychain: eliminar pop-up recorrente via `/usr/bin/security` CLI | @dev | Bug de produção pós-EXB-1.5/signing: leitura via Security.framework prompta porque o item do Claude CLI não confia no nosso app; CLI `/usr/bin/security` lê sem prompt (caminho do CodexBar original) |

**Execution order:** 3.8 (única story da onda).

**Wave DoD:**
- [ ] EXB-3.8 Done
- [ ] CLI `/usr/bin/security` é a estratégia primária da camada (e); fallback no-UI mantido
- [ ] Nenhum caminho de código levanta o diálogo de keychain (zero `allowPrompt`, NoUI incondicional)
- [ ] Setting `useSecurityCLIReader` conectado e default ON
- [ ] `make build` assinado zero warnings + `swift test` sem regressão da baseline (223 → 230)

---

## Onda 9 (v1.6.0)

**Status:** Draft | **Target:** v1.6.0 | **Created:** 2026-06-18

Feature wave com 5 histórias independentes: correção definitiva de visibilidade do heatmap (escala logarítmica), ícone próprio da marca, previsão de esgotamento com alerta preditivo, menu bar configurável com hotkey global, e insights de eficiência no dashboard (cache hit, comparação com média, resumo semanal).

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-4.1 | Heatmap fix — escala logarítmica e contraste | @dev | Bug confirmado: escala linear torna células quase invisíveis em dados com pico; fix cirúrgico sem tocar em outros charts |
| 2 | EXB-4.2 | Ícone customizado do app | @dev | Placeholder "eB" não representa a marca; pipeline dependency-free com símbolo eximIA real |
| 3 | EXB-4.3 | Previsão de esgotamento | @dev | Feature nova sem dependência de código novo (EXB-4.1/4.2 podem rodar em paralelo) |
| 4 | EXB-4.4 | Menu bar inteligente + hotkey | @dev | Depende de EXB-4.3 (forecasts no DisplaySnapshot); estende StatusItemController e SettingsStore |
| 5 | EXB-4.5 | Insights de eficiência | @dev | Depende do dashboard baseline EXB-3.7; independente dos demais da onda |

**Execução sugerida:** 4.1 e 4.2 em paralelo → 4.3 → 4.4 → 4.5 (ou 4.5 em paralelo com 4.3/4.4).

**Wave DoD:**
- [ ] All 5 stories Done
- [ ] `swift build -c release` zero warnings com todo o código Onda 9
- [ ] `swift test --no-parallel` passando (sem regressões — baseline antes da onda = 223+ testes)
- [ ] Heatmap: células não-zero visivelmente distinguíveis do fundo em dados com distribuição exponencial
- [ ] Ícone do app exibe símbolo eximIA real + arco gauge `#CC7C5E` no Finder/Dock/Spotlight
- [ ] Popover: linha de previsão de esgotamento aparece quando há dados suficientes (>= 3 amostras)
- [ ] Settings: picker de conteúdo da menu bar + campo de captura de hotkey funcionais
- [ ] Dashboard: cache hit rate, delta vs média, e seção "Esta semana" (só em 7d) visíveis

---

## Onda 10 (v2.4.0)

**Status:** Ready (validada @po 2026-07-31) | **Target:** v2.4.0 | **Created:** 2026-07-31

Multi-conta Claude + provider Codex enxuto. Design técnico completo em `docs/architecture/onda-10-multi-account-codex.md` (Aria, @architect). Introduz um **roster de contas** alimentado por **captura automática no momento do login** (quando o polling de fingerprint detecta troca de identidade, a conta anterior é arquivada como somente-leitura, nunca renovada), e um **provider Codex** enxuto (apenas OAuth via `~/.codex/auth.json`, sem WebView, sem RPC, sem cost scan). UX: switcher (uma conta/provider em foco por vez), ícone da menu bar sempre ancorado na conta viva do CLI.

**Nota de honestidade documental:** `git tag` mostra releases de **v1.7 até v2.3.2** sem story files correspondentes em `docs/stories/` — este `EPIC-EXB.md` está defasado do código real (a última onda documentada antes desta era a v1.6.0/Onda 9, o HEAD real na baseline desta onda é v2.3.2). Esta seção **não tenta reconstruir retroativamente** as ondas ausentes; a Onda 10 é anexada como continuação direta da Onda 9. Reconciliar o histórico v1.7–v2.3.2 é trabalho documental separado, recomendado para registro em inbox, fora do escopo desta onda.

**Decisões do dono do produto sobre o design do Aria** (seção "6. Decisões" do documento de arquitetura):
- **D-A:** confirmado — refresh token **não** é arquivado para contas somente-leitura (só `accessToken` + `expiresAt`).
- **D-B:** confirmado — teto de **8 contas** no roster, evicção LRU.
- **D-C:** **divergiu** da recomendação do Aria (persistir foco) — o foco do switcher **NUNCA** persiste entre reinícios do app; sempre volta para a conta `.live`. Aplicado em `EXB-5.3` (definição do `WorkspaceSnapshot`) e `EXB-5.5` (switcher).
- **D-D:** **divergiu** da recomendação do Aria (adiar para Onda 11) — o Codex **participa das notificações de cota** já nesta onda. Aplicado em `EXB-5.3` (wiring do `QuotaNotifier`).

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | EXB-5.1 | Resolução de identidade da conta Claude (`~/.claude.json`) | @dev | Fundação de tudo — `UsageSnapshot.identity` existe mas é sempre `nil`; sem isso não há como detectar troca de conta nem popular o e-mail que o header do popover tenta exibir desde a EXB-1.3 |
| 2 | EXB-5.2 | Roster de contas: captura no login + persistência somente-leitura | @dev | Depende de 5.1 (indexado por e-mail). `AccountRosterStore` (actor), índice `0600` + segredos em keychain próprio, gancho de captura no polling de fingerprint existente |
| 3 | EXB-5.4 | Provider Codex enxuto (OAuth via `~/.codex/auth.json`) | @dev | Só depende de `AccountKey` (5.1) — pode rodar em paralelo com 5.2. `CodexAuthStore`, decode de JWT, `CodexUsageFetcher`; regra dura: nunca renovar o token |
| 4 | EXB-5.3 | `WorkspaceSnapshot` + generalização do `AppState` | @dev | Depende de 5.2 (roster) e 5.4 (painel Codex). Ponto de maior risco arquitetural: uma propriedade armazenada observável, fan-out `async let` com uma única atribuição por ciclo; aplica D-C e D-D |
| 5 | EXB-5.5 | Switcher no painel + gestão de contas em Settings | @dev | Depende de 5.3. Chip de conta vira lista inline; restrição inegociável: sem `NSMenu`/`Menu`/`NSPopUpButton` |
| 6 | EXB-5.6 | Release v2.4.0 | @devops | Última por construção — corta a release do código completo da onda, atualiza cask Homebrew e README |

**Execution order:** `5.1 → (5.2 ∥ 5.4) → 5.3 → 5.5 → 5.6` (paralelo se houver dois executores; sequencial puro `5.1 → 5.2 → 5.4 → 5.3 → 5.5 → 5.6` se executor único). **Ordem validada pelo @po** contra as dependências reais declaradas em cada story: coerente, sem ciclo, sem dependência implícita não declarada.

### Validação @po — 2026-07-31 (Pax)

Checklist de 10 pontos aplicado às 6 stories. Veredito: **6 GO, 0 NO-GO** (2 stories exigiram correção bloqueante antes do GO, feita pelo @po sob sua autoridade sobre AC/escopo).

| Story | Nota | Veredito | Correção aplicada |
|---|:---:|---|---|
| EXB-5.1 | 9/10 | GO | AC4 estava factualmente errada: `UsageSnapshot.from` não aceita identidade, e trocar o tipo `UsageSnapshot.Identity` por `AccountIdentity` quebraria `DisplaySnapshot.swift:134` + `UsageCardView.swift:92`. AC6 nova (comandos mecânicos). |
| EXB-5.2 | 9/10 | GO | Tipo `ClaudeCredentials` → `ClaudeOAuthCredentials` (nome real). **AC4.11 nova:** a captura tem de acontecer ANTES da invalidação de cache do polling, senão falha em silêncio sempre. AC8 nova (5 comandos que provam D-A e D-B). |
| EXB-5.3 | 9/10 | GO *(era NO-GO)* | **Bloqueante:** AC4 mandava alimentar o `QuotaNotifier` por `menuBarSnapshot` **e** monitorar o Codex (D-D) — incompatíveis; o painel Codex não existe dentro desse valor. A D-D morreria na implementação ou custaria uma 2ª propriedade observável (fere I3). AC4.10 muda a entrada para a coleção de painéis `.live`. AC4.11 nova (arquivada nunca notifica). AC6.17 nova (`LiveUsageProvider` como ponto de composição). |
| EXB-5.4 | 9/10 | GO | Baseline de teste apontava para `EXB-5.2`, com a qual esta story roda **em paralelo** — corrigida para `EXB-5.1`. AC7 nova, incl. prova estrutural da não-renovação (R6 estendida). |
| EXB-5.5 | 9/10 | GO *(era NO-GO)* | **Bloqueante:** o grep T-R18 (`NSPopUpButton\|NSMenu(`) **não casa com o `Menu` do SwiftUI** — o item mais provável de ser usado por engano, num risco de probabilidade ALTA. Gate falso-verde. Grep ampliado + baseline medida. AC4.9 virou comando literal. AC3.7, AC5.12 e AC6 (localização) novas. |
| EXB-5.6 | 8/10 | GO | AC0 nova com 6 gates bloqueantes pré-release que só existiam como Dev Notes e Wave DoD sem dono — incl. os 30 min sem pop-up de keychain (R16, o risco que custou a Onda `EXB-3.8` inteira). |

**Decisões do dono sobreviveram como AC verificável:** D-A → `EXB-5.2` AC2.5 + AC8.20 (grep) + teste. D-B → `EXB-5.2` AC3.8 + AC8.23 + teste. D-C → `EXB-5.3` AC5.12-15 + `EXB-5.5` AC4.8-9 (grep literal) + teste. D-D → `EXB-5.3` AC4.9-11 + teste (**só sobreviveu porque a AC4.10 foi adicionada**; como estava escrita, a D-D era estruturalmente inalcançável).

**Invariantes anti-freeze:** nenhuma story permite violar I1/I2/I3/I4/R6-estendida. Ponto de maior exposição era o grep incompleto da `EXB-5.5` (I4), agora fechado.

**Wave DoD** — verificado pelo @qa (Quinn) em 2026-07-31, cada item com evidência executada, não relatada:

- [x] **5 de 6 stories `Done`** — `EXB-5.1` a `EXB-5.5` aprovadas no gate de QA (PASS cada uma). `EXB-5.6` (release) é a única aberta, por construção.
- [x] **`swift build -c release` sem novos warnings** — `swift build -c release --arch arm64 --scratch-path /tmp/…` (scratch **limpo**, sem cache, para que "zero warnings" seja prova e não artefato de build incremental) → `Build complete! (95.97s)`, **0 warnings, 0 errors**.
- [x] **`swift test` sem regressão** — `Scripts/run-tests.sh` rodado pelo @qa do zero → **403 testes em 49 suítes, exit 0**, zero linhas `✘` ou `error:` no log. Progressão da onda: 324 (baseline `7b48acb`) → 336 → 367 → 392 → **403**.
- [x] **Identidade** — provado ponta a ponta por binário descartável linkado contra o `ClaudeBarCore` de **release**, lendo o `~/.claude.json` **real**: `email = hugocapitelli@gmail.com`, idêntico ao `python3 -c json.load(...)['oauthAccount']['emailAddress']`. O gate de fingerprint também foi provado por execução: dois `resolve()` consecutivos deixam `parseCount` em **1 → 1** (o arquivo de 45 KB não é reparseado). `grep -n "identity:" UsageFetcher.swift` = 2 ocorrências, contra **0 na baseline `git show HEAD:`** — D1 fechada de forma medida.
- [~] **Captura** — **verificado por teste ponta a ponta, não por segunda conta real.** `capturesPreviousCredentialBeforeCacheInvalidation` usa home temporário com `.credentials.json` e `.claude.json` reais e mtime manipulado para simular `claude login`, e assere que o segredo arquivado é `TOKEN-A` (o anterior) e **não** `TOKEN-B`. A ordem que torna isso possível foi confirmada no código: captura na linha 482, invalidação de cache na 484. Não há segunda conta Claude neste ambiente; o `claude login` real fica para o smoke da `EXB-5.6`.
- [x] **Somente-leitura (T-R9)** — `archivedAccountsNeverTriggerRefreshOrFetch`: 3 contas arquivadas + ciclo completo → exatamente **1 POST + 1 GET**, e a varredura de corpos **e** headers prova que nenhum token arquivado deixou o processo. A contagem não escala com o tamanho do roster.
- [x] **Invariante I3 (T-I3)** — **provado por mutação pelo @qa**, não por leitura. Substituindo `publish(merged)` por montagem incremental (um `publish` por conta), o teste falha com `(many.writes → 6) == (single.writes → 2)`. Restaurado, `shasum` idêntico. O teste morde pelo motivo certo. *Nota de precisão:* o teste assere **2** escritas (flip do spinner + publicação do agregado), não 1; o invariante que de fato importa e está provado é a **invariância em relação a N** — 5 contas custam o mesmo número de notificações observáveis que 1. O texto anterior deste item ("exatamente uma atribuição") era impreciso e foi corrigido aqui.
- [x] **Anti-`NSMenu` (T-R18)** — o grep literal deste DoD retorna vazio, **e** o grep ampliado do @po (que inclui o `Menu` do SwiftUI) também. O @qa foi além e varreu o target inteiro incluindo `Picker(`: as únicas ocorrências de menu são 2 `NSMenu()` em `ClaudeBarApp.swift` (menu principal do ⌘,), **pré-existentes com contagem idêntica em `git show HEAD:`**, e 11 `Picker(` em `Settings/`/`Dashboard/`, todos pré-existentes (`git diff` do pane modificado adiciona 5 linhas, **nenhuma** contendo `Picker(`/`Menu(`/`NSPopUpButton`).
- [x] **Menu bar ancorada** — estrutural: `focusAccount(_:)` faz `publish(next)` e **nada mais**; os 3 `notifier.evaluate*` vivem todos dentro de `completeFetch`. Trocar foco não tem caminho para notificar. Coberto por `menuBarNeverChangesWhenFocusChanges` e `menuBarSnapshotIsUnaffectedByFocusChange`.
- [x] **D-C** — garantido **por construção**, não por convenção: `WorkspaceSnapshot` é `Sendable, Equatable` e **não é `Codable`**, logo não existe caminho de serialização do foco; o único `init` público fixa `focusedKey = menuBarKey` e o que aceita foco divergente é `private`, alcançável só por `withFocus(_:)` em memória. `grep -rn "focusedKey" | grep -iE "UserDefaults|AppStorage|accounts.json|encode|Codable"` → exit 1.
- [x] **D-D** — a entrada do notifier é a **coleção** `merged.accounts` (linhas 267/281), nunca o painel em foco — o achado bloqueante do @po está fechado na raiz. O filtro `lifecycle == .live` mora **dentro** do notifier (linha 166), então arquivada nunca notifica independente do call site. Dedup por conta é do tipo: `ThresholdKey(account, window, threshold)` e `DepletionKey(account, window)`.
- [~] **Codex** — o ramo "ausente" está provado (`missingAuthJsonMeansProviderSimplyAbsent`: `.absent` **e** zero requisições). O ramo "presente com session/weekly **reais**" **NÃO pôde ser verificado**: o `access_token` do `~/.codex/auth.json` real desta máquina **expirou em 2026-07-27**. Contra esse arquivo real, o provider devolve `.expired("expirado — rode \`codex login\`")` com **0 tentativas de rede** — comportamento correto e provado, mas é o ramo terminal, não o caminho feliz. **Requer `codex login` antes do smoke da `EXB-5.6`.** Ver QA-C1 na `EXB-5.4`.
- [x] **Keychain (R16):** 30 min de uso contínuo (19:49:18 → 20:19:19, 2026-07-31), **zero** diálogos Allow/Deny em 179 amostras. Medido pelo @devops sobre a v2.4.0 já instalada, assinada com a identidade estável. Método e sua limitação declarados na `EXB-5.6`.
- [~] **Codex presente com dado real** — a pré-condição do @qa foi cumprida: com o `codex login` refeito, `GET wham/usage` devolve **HTTP 200** com `plan_type: plus` e `rate_limit.primary_window.limit_window_seconds: 604800`. O caminho feliz deixou de ser hipótese. Falta apenas a confirmação **visual** do painel no popover.
- [ ] Release GitHub `v2.4.0` publicada — **RETIDA pelo @devops**. Artefato pronto e verificado (universal, assinado, `sha256 a929f131…`), mas o corte público aguarda GO humano: os gates `AC0.4`, `AC0.5` e `AC0.6` são explicitamente "a olho" e não têm equivalente automatizável, e o `AC4`/`AC5` (Homebrew) partem de premissa caída — o cask está na `1.4.1`, nove releases atrás, e o canal ativo é o auto-updater in-app.
- [x] App v2.4.0 instalado em `/Applications/ExímIABar.app`; `pgrep -x ClaudeBar` → **54147**.

**Legenda:** `[x]` verificado com evidência executada · `[~]` parcialmente verificado, com a lacuna nomeada · `[ ]` pendente, escopo da `EXB-5.6`.

**Veredito consolidado do @qa:** **APROVADO para a `EXB-5.6`**, com 1 pré-condição (`codex login` antes do smoke) e 2 CONCERNS de severidade baixa registradas nas stories (`QA-C2`: `LiveUsageProvider.makeFetch()` sem teste automatizado, lacuna declarada honestamente pelo @dev; `QA-C3`: divergência documental já corrigida acima).

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
