# ClaudeBar — Spec de Clone (derivado de CodexBar, MIT)

> **Fonte:** análise de `/tmp/CodexBar` (CodexBar, Peter Steinberger, MIT, Swift 6.2, macOS 14+, SwiftPM puro).
> **Objetivo:** clone fiel focado EXCLUSIVAMENTE em Claude — mesmo visual, mesmas funcionalidades core, **sem os travamentos** documentados no CHANGELOG do original (#1376, #1379, #1384, #1274, #1351).
> **Contrato canônico do provider:** `/tmp/CodexBar/docs/claude.md` (ler antes de implementar).

---

## 1. Resumo Executivo

ClaudeBar é um app de menu bar macOS (agent, `LSUIElement`) que exibe em tempo real os rate limits do Claude (sessão 5h, semanal 7d, Sonnet/Opus, Extra Usage) lendo as credenciais OAuth que o Claude Code já mantém na máquina (`~/.claude/.credentials.json` / keychain `"Claude Code-credentials"`) e chamando `GET https://api.anthropic.com/api/oauth/usage`. O ícone da barra é um medidor de duas barras com "personalidade caranguejo" (estilo Claude do original); o dropdown mostra barras de progresso, countdown de reset, pace e custo local de tokens (scan dos JSONL do Claude Code). Notifica quando a quota cruza thresholds (50%/20% restantes, configuráveis) e quando esgota/restaura. Fallback automático de fonte: OAuth → CLI (PTY scrape) → Web (cookie claude.ai). Arquitetura nova elimina as 3 causas de freeze do original: rebuild síncrono de NSMenu+SwiftUI durante menu tracking, observation storm do store gigante, e probes CLI bloqueando o cooperative thread pool.

---

## 2. Funcionalidades a Replicar

| # | Feature | Comportamento exato | Prio |
|---|---------|---------------------|------|
| F1 | **Status item com ícone medidor** | `NSStatusItem` (.variableLength), ícone 18×18pt template desenhado em pixel grid 2× (36×36px): 2 barras horizontais (sessão em cima 30×12px, weekly embaixo 30×8px), fill proporcional a `remaining/100`, cutouts "caranguejo" (braços 3px, 4 pernas 2×3px, olhos verticais 2×5px, cantos retos — corner radius 0). Estados: stale (alphas reduzidos 0.55/0.28/0.18), erro (dimmed), incidente (ponto 4pt ou "!" no canto). Ref: `IconRenderer.swift:112-762` (estilo Claude `:257-336`) | P0 |
| F2 | **Modo brand icon + %** | Alternativa: SVG Claude 16×16 template + título `" 87%"` (ou `87% · +5%` com pace). Ref: `ProviderBrandIcon.swift`, `MenuBarDisplayText.swift:4-37`, `Resources/ProviderIcon-claude.svg` | P1 |
| F3 | **Dropdown com card de uso** | Header (nome + email + "Updated Xm ago" + plano), MetricRows: **Session** (5h), **Weekly** (7d), **Sonnet** (3ª barra), **Daily Routines** (se `seven_day_routines` presente), **Extra usage** (barra + "This month: $X / $Y"), **Cost** (Today/Last 30 days, do scan local). Cada row: título → barra 6pt → "N% left" + "Resets HH:mm". Ordem visual confirmada no screenshot `docs/screenshots/claude-extra-usage-bug.png` | P0 |
| F4 | **Pace (ritmo de consumo)** | Linha sob a barra weekly: `On pace` / `N% in deficit` / `N% in reserve` + `Lasts until reset` / `Runs out in Xd Yh` / `Runs out now`. Threshold "slightly" = absDelta ≤ 6. **Escondido se <3% da janela elapsou.** Strings EXATAS de `UsagePaceText.swift:37-54` (NÃO do screenshot, que é stale). Punch-out diagonal verde/vermelho na barra (`UsageProgressBar.swift:96-117`) | P0 |
| F5 | **Refresh pipeline** | Timer configurável: manual/1/2/5(default)/15/30 min. Gatilhos: startup, abertura do menu, manual (⌘R). User-initiated libera prompts de keychain e limpa cooldowns; background nunca abre diálogo. Ref: `SettingsStore.swift:6-38`, `UsageStore.swift:675-686` | P0 |
| F6 | **Fonte OAuth (principal)** | §4 deste doc. Endpoint `/api/oauth/usage` com Bearer token do Claude Code | P0 |
| F7 | **Fonte CLI (fallback)** | PTY 160×50, roda `claude --allowed-tools ""` sob watchdog, digita `/usage`, parseia painel (labels "Current session"/"Current week"), responde prompts de confiança automaticamente. Workdir isolado `~/Library/Application Support/ClaudeBar/ClaudeProbe/`. Limpa artefatos JSONL da probe. Ref: `ClaudeCLISession.swift`, `ClaudeStatusProbe.swift:152-253`, `ClaudeProbeSessionArtifactCleaner.swift` | P1 |
| F8 | **Fonte Web (fallback)** | Cookie `sessionKey` (`sk-ant-...`) dos browsers (Safari binarycookies → Chrome SQLite → Firefox SQLite, via SweetCookieKit). `GET claude.ai/api/organizations` → `/usage` → `/overage_spend_limit` → `/account`. Ref: `ClaudeWebAPIFetcher.swift` | P2 |
| F9 | **Source planner** | Modo `auto`: OAuth → CLI → Web, com `shouldFallback` por tipo de erro. Picker em Settings: Auto/OAuth/CLI/Web. Copiar `ClaudeSourcePlanner.swift` quase literal (224 linhas, função pura, testável) | P0 |
| F10 | **Notificações de quota** | (a) Depleted/restored: transição restante≤0% e retorno pós-reset. (b) Warnings: thresholds de **% restante**, default `[50, 20]`, separados por janela session/weekly, com anti-spam (set de thresholds disparados, limpo quando uso recua). Som opcional (NSSound "Glass"). `UNUserNotificationCenter`. Ref: `SessionQuotaNotifications.swift`, `CodexBarConfig.swift:258` | P0 |
| F11 | **Cost scan local** | Varre `~/.claude/projects/**/*.jsonl` + `~/.config/claude/projects/` + `$CLAUDE_CONFIG_DIR` (+ opcional `~/.pi/agent/sessions/`). Pré-filtro byte-level `"type":"assistant"` + `"usage"`, dedup por `message.id:requestId` (último chunk vence), pricing models.dev com cache, agregado dia×modelo, cache incremental por offset de bytes. Exibe "Today: $X · NK tokens / Last 30 days: $Y · N.NM tokens" com submenu. Ref: `CostUsageScanner+Claude.swift:27-53,132-158,211-219` | P1 |
| F12 | **Launch at login** | `SMAppService.mainApp` register/unregister, toggle em Settings | P0 |
| F13 | **Settings window** | 4 panes: General (refresh, launch, notificações+thresholds, cost toggle+dias), Claude (fonte, keychain prompt policy 3 modos, avoid-keychain-prompts toggle, web extras off-default), Display (used vs left, reset absoluto vs countdown, markers, brand icon+%), About (versão, link). Ver §3.3 | P0 |
| F14 | **Ações de menu** | `Refresh Now` (⌘R), `Usage Dashboard` (abre claude.ai/settings/usage), `Status Page` (status.claude.com), `Settings…` (⌘,), `Quit` (⌘Q). Em erro de sessão web: `Re-login at claude.ai`. Labels literais do screenshot | P0 |
| F15 | **Status page polling** | Statuspage.io do Claude → badge texto no menu ("Partially Degraded Service — Updated 16m ago") + overlay no ícone. Toggle em Settings | P2 |
| F16 | **Watchdog de processos** | Helper `ClaudeBarWatchdog` em `Contents/Helpers`: `posix_spawnp` + process group próprio + `waitpid(WNOHANG)` 200ms; mata árvore (SIGTERM→0.5s→SIGKILL) em SIGTERM/SIGINT/SIGHUP ou quando reparentado ao launchd. **Copiar `Sources/CodexBarClaudeWatchdog/main.swift` como está** (3.3KB, 1 arquivo) | P1 (junto com F7) |
| F17 | **Keychain prompt policy** | 3 modos visíveis na pane Claude: Never / Only on user action (default) / Always. + toggle "Avoid Keychain prompts" que ativa leitor via `/usr/bin/security` CLI (timeout 1.5s). Queries default no-UI (`LAContext.interactionNotAllowed` + `kSecUseAuthenticationUIFail`). Ref: `KeychainNoUIQuery.swift:11-19`, `ClaudeOAuthCredentials+SecurityCLIReader.swift` | P0 |
| F18 | **Animações de personalidade** | Blink/wiggle idle (timer randômico 3-12s, duração 0.36s, curva `pow(symmetric,2.2)`, 18% double-blink); loading animation (knightRider/pulse) **com cap de 30s e teto de 10fps** (reduzido vs 30fps do original). Ref: `StatusItemController+Animation.swift:112-179`, `LoadingPattern.swift` | P2 |
| F19 | **Quota warning flash** | Wash vermelho `systemRed` 0.22/0.28 no ícone por 60s ao cruzar threshold | P2 |
| F20 | **Hide personal info** | Toggle que oculta email/org em menu e notificações | P2 |

**NÃO replicar:** multi-provider (46 providers), Merge Icons/switcher/Overview, widget, CLI `codexbar`+serve, multi-conta/token accounts, Sparkle, 11 localizações, confetti/Vortex, OpenAI web scraping, charts Swift Charts (P2 futuro), macros swift-syntax, Admin API (`ANTHROPIC_ADMIN_KEY` — só se demanda enterprise surgir).

---

## 3. Visual a Replicar

### 3.1 Ícone da menu bar
- **Canvas:** 18×18pt template, renderizado 2× (36×36px) via `NSBitmapImageRep`; `image.isTemplate = true` (sistema tinge com labelColor, dark mode automático); `button.imageScaling = .scaleNone`. Pixel grid snapped a 0.5pt.
- **Barras:** superior `RectPx(x:3, y:19, w:30, h:12)`, inferior `(x:3, y:5, w:30, h:8)`. Track fill `labelColor` α0.28 (0.18 stale), stroke 1pt α0.44 (0.28 stale), fill α1.0 (0.55 stale). **Corner radius 0 (Claude é blocky)**.
- **Caranguejo Claude:** cutouts via blend `.clear` — braços laterais 3px, 4 pernas 2×3px embaixo, olhos verticais 2×5px que "fecham" de cima pra baixo no blink. Ref exata: `/tmp/CodexBar/Sources/CodexBar/IconRenderer.swift:257-336`.
- **Weekly ausente:** barra inferior dimmed α0.45 (`:671-710`). **Cache LRU** de 64 ícones, quantizado a 0.1% (`:31-70`).
- **Overlay de incidente:** minor = ponto 4pt canto inferior direito; major = "!" (linha 2×6 + ponto 2×2) (`:935-968`).

### 3.2 Dropdown (popover) — estrutura seção a seção
**Decisão de apresentação do clone: `NSPanel` ancorado ao status item (estilo popover), NÃO `NSMenu`** — ver §5/§6. O visual replica o do menu original: fundo `NSVisualEffectView` material `.menu` + vibrancy, largura **310pt**.

Top → bottom:
1. **Header** — linha 1: "Claude" `.headline.semibold` à esquerda, email `.subheadline` secondary truncado `.middle` à direita; linha 2: subtítulo "Updated 2m ago"/"Refreshing…"/erro (`.footnote`, erro = `systemRed` até 4 linhas + botão copy `doc.on.doc`→`checkmark` 18×18, press scale 0.94) à esquerda, plano ("Max", "Pro") `.footnote` secondary à direita. Ref: `MenuCardView.swift:253-299`.
2. **Divider.**
3. **MetricRow Session** — título `.body.medium` → `UsageProgressBar` 6pt → `"N% left"` `.footnote` + `"Resets 14:00"` `.footnote` secondary. Espaçamento: 6 interno, 12 entre rows. Ref: `MenuCardView.swift:383-452`.
4. **MetricRow Weekly** — idem + linha de pace (F4) + workday markers opcionais.
5. **MetricRow Sonnet** — idem (rótulo "Sonnet"; slot `seven_day_sonnet ?? seven_day_opus`).
6. **Daily Routines** (condicional) — barra extra de `seven_day_routines`.
7. **Divider + Extra usage** (condicional) — barra laranja + "This month: $222.00 / $2000.00" + "11% used".
8. **Divider + Cost** — "Estimated cost" `.body.medium`, "Today: $0.08 · 27K tokens", "Last 30 days: $3.72 · 5.4M tokens" `.footnote`; chevron → detalhe.
9. **Status line** (condicional) — "Partially Degraded Service — Updated 16m ago".
10. **Separator + ações** — rows 28pt: ícone SF Symbol 16×16 template + label + shortcut à direita (38pt, `smallSystemFontSize`); highlight `selectedContentBackgroundColor` radius 6 inset 6/2. Ordem: Refresh Now ⌘R · Usage Dashboard · Status Page · Settings… ⌘, · Quit ⌘Q. Ref: `StatusItemController+MenuPresentation.swift:173-290`.

**Barra de progresso** (`UsageProgressBar.swift:4-195`): altura 6pt, radius 3, único `Canvas` SwiftUI (sem Metal shaders). Track `tertiaryLabelColor.opacity(0.22)`; fill **cor de marca Claude `rgb(204,124,94)` ≈ #CC7C5E**. Pace tip: punch-out diagonal largura `stripeWidth*3` + stripe 2px central, verde (reserve) / vermelho (deficit); largura `max(25, height*6.5)`. Warning markers: traços 1px, 55% da altura, `primary.opacity(0.32)`.

**Referência pixel-perfect obrigatória:** `/tmp/CodexBar/docs/screenshots/claude-extra-usage-bug.png` (único screenshot real do card Claude).

### 3.3 Settings
`TabView` toolbar-style, janela **546×638pt**, padding h24/v16. Panes (referências para layout):
- **General** (`PreferencesGeneralPane.swift`): seções com headers `.caption` secondary UPPERCASE; launch at login, refresh cadence picker `.menu` maxWidth 200, notificações + thresholds, cost on/off + stepper 1–365 dias, botão Quit `.borderedProminent .large`.
- **Claude** (derivar de `PreferencesProviderDetailView.swift` + `QuotaWarningSettingsViews.swift`): picker de fonte (Auto/OAuth/CLI/Web), keychain prompt policy (picker só visível com Security.framework reader ativo), avoid-keychain-prompts, web extras (default OFF), thresholds por janela, paths de binário claude (debug).
- **Display** (`PreferencesDisplayPane.swift`): used vs left, reset absoluto vs countdown, markers, workday markers (off/4/5/7), brand icon+%.
- **About** (`PreferencesAboutPane.swift`): ícone 92×92 radius 16, hover scale 1.05, versão, links accent.
Componentes: `PreferenceToggleRow` = checkbox `.body` + subtítulo `.footnote` `.tertiary` spacing 5.4; `SettingsSection` = VStack spacing 10, título `.subheadline.semibold` (`PreferencesComponents.swift`).

### 3.4 Design tokens
| Token | Valor |
|---|---|
| Cor de marca Claude | `rgb(204/255, 124/255, 94/255)` #CC7C5E — barras, charts |
| Cores de sistema | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `controlTextColor`, `selectedMenuItemTextColor`, `selectedContentBackgroundColor`, `controlAccentColor`, `systemRed`, `systemYellow` — **nenhum asset catalog**, dark mode automático |
| Tipografia | 100% SF semântica: `.headline.semibold` / `.body.medium` / `.subheadline` / `.footnote` / `.caption2` |
| Métricas | popover 310pt; card hPad 20, headerLineSpacing 4, headerColumnSpacing 12; barra 6pt r3; row spacing 12; action row 28pt; highlight r6 inset 6/2; cardStyle r10 bg `secondary.opacity(0.08)`; ícone 18×18@2x; SF Symbols 16×16; settings 546×638 |
| Highlight | `MenuHighlightStyle.swift:7-35` — selecionado: texto `selectedMenuItemTextColor`, fundo `selectedContentBackgroundColor` |

---

## 4. Pipeline de Dados Claude

### 4.1 Credenciais — ordem de carga (copiar de `ClaudeOAuthCredentials.swift:169-306`)
1. Env `CLAUDEBAR_OAUTH_TOKEN` (+`_SCOPES`) — override de teste.
2. Cache em memória (TTL **30 min**, não expirado).
3. Cache keychain próprio (service `com.<org>.claudebar.cache`, account `oauth.claude`).
4. Arquivo **`~/.claude/.credentials.json`** — formato: `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt"(epoch ms), "scopes":[], "rateLimitTier", "subscriptionType"}}`. Lido com `Data(contentsOf:)`; sucesso → copia para caches 2 e 3.
5. Keychain do Claude Code — generic password, service **`"Claude Code-credentials"`**: probe de atributos sem prompt (`kSecMatchLimitAll` + `kSecReturnPersistentRef`, NoUI), ordena por `modificationDate`, lê por persistentRef. Prompt só se policy permitir e contexto for user-initiated.

**Detecção de mudança (SEM file watcher — polling de fingerprint):** arquivo = (mtime ms, size) em UserDefaults; keychain = (modifiedAt, createdAt, sha256-prefix do persistentRef), throttle 60s. Mudança → invalida caches.

**Owner do token decide o refresh (CRÍTICO):**
- `claudeCLI` (caso normal): **NUNCA refrescar direto** — o refresh token do Claude Code é rotativo; consumi-lo quebra o login do usuário (regressão #1161 do original). Delegar: rodar `claude /status` em PTY sob watchdog e poll do fingerprint do keychain (0.2/0.5/0.8s); cooldown 5min sucesso / 20s falha; depois reler keychain sem prompt e retentar.
- `claudebar` (token cacheado próprio): refresh direto `POST https://platform.claude.com/v1/oauth/token`, form-urlencoded `grant_type=refresh_token&refresh_token=...&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e` (client ID público do Claude Code).
- `environment`: não refresca.
- `invalid_grant` (400/401) → bloqueio terminal até fingerprint de auth mudar; outras falhas → backoff exponencial base 5min, teto 6h (`ClaudeOAuthRefreshFailureGate.swift`).

### 4.2 Endpoint de usage
```
GET https://api.anthropic.com/api/oauth/usage          (timeout 30s)
Authorization: Bearer <accessToken>
Accept: application/json
Content-Type: application/json
anthropic-beta: oauth-2025-04-20                        ← OBRIGATÓRIO
User-Agent: claude-code/<versão do CLI local>           ← fallback "claude-code/2.1.0"
```
**Escopo:** token DEVE ter `user:profile`. Token só com `user:inference` → 403; mensagem deve sugerir `claude setup-token`.

### 4.3 Schema do response (validado por fixtures `Tests/CodexBarTests/ClaudeOAuthTests.swift:69-128`)
```json
{
  "five_hour":        { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
  "seven_day":        { "utilization": 30,   "resets_at": "2025-12-31T00:00:00.000Z" },
  "seven_day_sonnet": { "utilization": 5 },
  "seven_day_opus":   { ... },
  "seven_day_oauth_apps": { ... },
  "seven_day_routines": { ... },          // aliases: claude_routines|routines|cowork...
  "extra_usage": { "is_enabled", "monthly_limit", "used_credits", "utilization", "currency" }
}
```
**Regras load-bearing:**
- `utilization` **JÁ É percentual 0-100** (12.5 = 12.5%). NÃO escalar. `remaining = 100 - utilization`.
- OAuth entrega `Double` (fracionário); a Web API entrega `Int`. Decodificar com `Double?` tolerante a ambos.
- `resets_at` = ISO8601 **com fractional seconds + Z** (fallback sem fractional).
- `extra_usage` valores em **centavos** — dividir por 100 ($222.00 = 22200).
- **Ignorar**: `iguana_necktie` (sonda da Anthropic, decodificado e descartado no original), `seven_day_design`, `seven_day_omelette` (compartilham o limite principal — não viram barras).
- Decoder tolerante a chaves novas (`DynamicCodingKey`).

### 4.4 Mapeamento para snapshot
- **Session** = `five_hour` (windowMinutes 300); fallback cascata `seven_day` → `oauth_apps` → `sonnet` → `opus`.
- **Weekly** = `seven_day` (10080 min). **3ª barra** = `seven_day_sonnet ?? seven_day_opus`, rótulo "Sonnet".
- **Daily Routines** = `seven_day_routines` (barra 0% se chave vier `null`).
- **Extra usage** → `{used, limit, currency, period: "Monthly cap"|"Spend limit"}`. Enterprise/credit-only sem janelas → primary sintético spendLimit (`enterprise.countsAsSubscription = false`).
- **Plano** de `subscriptionType`/`rateLimitTier` → "Claude Max/Pro/Team/Enterprise/**Ultra**" (`ClaudePlan.swift:8,49-106`).

### 4.5 Erros
| HTTP | Ação |
|---|---|
| 401 | "Run `claude` to re-authenticate" |
| 403 + `user:profile` no body | sugerir `claude setup-token` |
| 429 | gate persistente: `Retry-After` (segundos OU data RFC) senão 5min; background curto-circuita, user-initiated ignora; mensagem sugere `claude logout && claude login` |
| token expirado | refresh por ownership (§4.1) |
| rede | em `auto`, cai para próxima fonte do plano |

### 4.6 Web extras (decisão do clone)
O original, mesmo em OAuth, dispara um 2º fetch web (claude.ai) para enriquecer extra windows + custo (`applyWebExtrasIfNeeded`, `ClaudeUsageFetcher.swift:1230-1271`). **No clone: OFF por default**, toggle escondido em Claude pane — dobra latência e adiciona ponto de falha.

---

## 5. Diagnóstico de Travamento do Original (ranqueado)

| # | Causa | Prob. | Evidência | Lição para o clone |
|---|---|---|---|---|
| 1 | **Rebuild síncrono de NSMenu+NSHostingView durante menu tracking.** Cards SwiftUI de 61K medidos com `layoutSubtreeIfNeeded()`+`fittingSize` na main thread, dentro do run-loop mode de tracking do AppKit → congela WindowServer | ALTA | CHANGELOG 0.32.6: "multi-second WindowServer stalls" (#1376); 0.32.5 (#1379); comentário em `+MenuTracking.swift:80-84` admitindo "background freeze on every store tick" (#1274). HEAD ainda é um fix disso (#1384) | **Não usar NSMenu para conteúdo dinâmico.** NSPanel próprio fora do menu-tracking run loop |
| 2 | **Observation storm**: `UsageStore` `@Observable` de 77K linhas; cada fetch muta vários dicionários → cadeia observação→task→invalidação de menu repetida; + serialização de assinatura de 30 dias de dados na main a cada tick | ALTA | `UsageStore.swift:105,584-595`, `StatusItemController.swift:467-493` ("wasted main-thread work" no próprio comentário), band-aids #1297/#1351 | Store pequeno (1 provider), publicação de snapshot imutável único por refresh, UI diffa valor — não rastreia dezenas de propriedades |
| 3 | **Probes CLI síncronas saturando o cooperative thread pool**: `TTYCommandRunner.run()` bloqueia com `usleep`/`waitUntilExit` chamado de contexto async; fan-out paralelo de N providers esgota o pool (largura = nº de cores) → TODAS as continuations do app enfileiram | ALTA | `TTYCommandRunner.swift:415,541,654`; fan-out `UsageStore.swift:584` | Subprocess/PTY SEMPRE em thread dedicada (`Thread`/executor próprio), nunca no pool cooperativo. Com 1 provider o risco cai, mas a regra fica |
| 4 | Animação de ícone 30fps + blink tick 75ms na main durante loading prolongado (que durava dezenas de segundos por causa do #3) | MÉDIA | `+Animation.swift:7,9,1036-1041` | Cap 10fps, animação só quando loading real, parar ao abrir popover |
| 5 | Pressão de memória: WKWebView scraping OpenAI (200-400MB), caches de cost agregados, processos filhos Node ~150-250MB por probe — existe até "memory pressure relief" manual | MÉDIA | `UsageStore+MemoryPressure.swift:5-18`, `OpenAIDashboardFetcher.swift` (`@MainActor`, 43K) | Nada de WKWebView no clone; 1 processo `claude` por vez (actor serializa); sem relief manual — não criar o problema |
| 6 | I/O síncrono pontual no main (config save atômico por toggle, load inicial de histórico) | BAIXA | `SettingsStore.swift:117`, `CodexBarConfigStore.swift:52-66` | Persistência via actor dedicado, debounced |

---

## 6. Arquitetura Proposta do Clone

### 6.1 Targets (SwiftPM, Swift 6.2, StrictConcurrency)
```
ClaudeBar/
├── Package.swift                      (deps: KeyboardShortcuts? opcional, SweetCookieKit? só se F8)
├── Sources/
│   ├── ClaudeBarCore/                 (lib sem UI, ~35 arquivos)
│   │   ├── Model/        UsageSnapshot, RateWindow, ClaudePlan, ProviderCost
│   │   ├── FetchPlan/    FetchStrategy protocol, FetchPipeline, SourcePlanner (cópia de ClaudeSourcePlanner)
│   │   ├── OAuth/        CredentialsStore, UsageFetcher, RefreshCoordinator, gates (cópia adaptada de ClaudeOAuth/)
│   │   ├── CLI/          PTYRunner (REESCRITO async), CLISession (actor), StatusProbe parser, ArtifactCleaner
│   │   ├── Web/          WebAPIFetcher + CookieReader            [P2, atrás de flag]
│   │   ├── Cost/         CostScanner (adaptado de CostUsageScanner+Claude), Pricing
│   │   └── Support/      KeychainNoUIQuery, HTTPClient, ISO8601, Logging
│   ├── ClaudeBar/                     (app, ~30 arquivos)
│   │   ├── App/          ClaudeBarApp, AppState (store), SettingsStore, LaunchAtLogin
│   │   ├── StatusItem/   StatusItemController, IconRenderer (cópia do estilo Claude), AnimationDriver
│   │   ├── Popover/      UsagePanelController (NSPanel), UsageCardView, MetricRow, UsageProgressBar, ActionRow
│   │   ├── Settings/     SettingsWindow + 4 panes + components
│   │   └── Notifications/ QuotaNotifier
│   └── ClaudeBarWatchdog/main.swift   (cópia literal do CodexBarClaudeWatchdog)
└── Scripts/ package_app.sh, sign-and-notarize.sh (esqueleto do original sem widget/Sparkle/xcodegen)
```

### 6.2 Modelo de concorrência — REGRAS EXPLÍCITAS (anti-freeze)
1. **ZERO I/O na main thread.** Nenhum `Data(contentsOf:)`, `SecItemCopyMatching`, `Process`, stat, ou JSON parse no MainActor. Keychain e leitura de arquivo rodam em `Task.detached(priority: .utility)` ou actors.
2. **PTY/subprocess NUNCA no cooperative pool.** O `PTYRunner` reescrito usa `Thread` dedicada (ou executor serial próprio) com bridge por `CheckedContinuation` + `DispatchSource` para leitura do fd — proibido `usleep`/`waitUntilExit` em contexto `async`. `ClaudeCLISession` continua actor (serializa: máx 1 processo `claude` vivo).
3. **UI nunca dentro de menu tracking.** O dropdown é um **`NSPanel`** (nonactivating, `.statusBar` level, fecha em resign/click-out) com UMA `NSHostingView` raiz — herdamos vibrancy via `NSVisualEffectView` material `.menu`. Sem `fittingSize` forçado: altura via SwiftUI auto-sizing assíncrono. Elimina por construção a classe inteira de bugs #1376/#1379/#1274/#1384.
4. **Snapshot imutável único.** `AppState` (`@MainActor @Observable`, <300 linhas) expõe `var current: DisplaySnapshot?` (struct com tudo que a UI precisa: janelas, pace, custo, erro, identidade, timestamp). Fetch monta o snapshot inteiro off-main e publica com UMA atribuição. Refresh com guard de coalescing (se um fetch está em voo, marca pending e roda 1 depois — nunca empilha).
5. **Timer = Task estruturada** (`Task.sleep` em loop, cancelável), TaskLocal `RefreshPhase` (.startup/.background/.userInitiated) governa prompts de keychain e gates (como o original).
6. **Animação:** ≤10fps, somente enquanto `isLoading`, cap 30s, suspensa com popover aberto.
7. **Persistência (settings/histórico/caches) via actor** dedicado com write debounced 500ms.
8. **Budget de processo:** no máximo 1 `claude` filho por vez, sempre sob watchdog; ambiente scrubbed (`ANTHROPIC_*` removidos); workdir isolado.

### 6.3 O que NÃO portar (e por quê)
| Item | Motivo |
|---|---|
| `NSMenu` + NSHostingView por item + caches de altura + smart-update (`+Menu.swift`, `+MenuCardItems.swift`, `+MenuWidthCache`) | Causa-raiz #1 dos freezes; NSPanel elimina a classe de bug |
| `UsageStore` 77K + 25 extensões + `withObservationTracking` manual | Causa #2; substituído por snapshot único |
| `TTYCommandRunner` como está (busy-wait `usleep`) | Causa #3; reescrever async em thread dedicada |
| Macros `CodexBarMacros`/`CodexBarMacroSupport` + swift-syntax | Açúcar para 46 providers; com 1, registra-se em 1 linha. Corta a dep mais pesada do build |
| `OpenAIWeb/` (~200K), multi-conta (`+TokenAccounts` 55K), switcher (`+SwitcherViews` 62K), widget, CLI, Sparkle, Vortex, localização | Fora do escopo Claude-only |
| Web extras ON em modo OAuth | 2º fetch de rede no caminho feliz; OFF por default |
| `MemoryPressureRelief` | Sintoma de problema que o clone não cria |

### 6.4 O que copiar quase literal (o "ouro")
`ClaudeSourcePlanner.swift` (puro), `ClaudeOAuth/` (credenciais+gates+refresh delegado — adaptar nomes/services), `ClaudeStatusProbe` parsers, `ClaudeProbeSessionArtifactCleaner`, `IconRenderer` (estilo Claude), `UsageProgressBar`, `UsagePaceText`/`UsagePace`, `CostUsageScanner+Claude`, watchdog inteiro, fixtures de teste `ClaudeOAuthTests.swift`/`ClaudeUsageTests.swift` (contrato de formato).

---

## 7. Estimativa de Escopo

**~65-75 arquivos Swift, ~20-25K linhas** (vs 652 arquivos/144K do original — o overhead multi-provider era ~75-80%). Sem Xcode project (SwiftPM + `package_app.sh`).

| Story | Conteúdo | Tamanho |
|---|---|---|
| **S1 — Core OAuth pipeline** | Modelos (RateWindow/UsageSnapshot/ClaudePlan), CredentialsStore (5 camadas, fingerprints, owner), UsageFetcher (endpoint+headers+schema §4), gates 429/refresh-failure, mapeamento snapshot. Testes com as fixtures do original | G (maior story; ~base de tudo) |
| **S2 — Status item + ícone** | NSStatusItem, IconRenderer caranguejo (cópia), estados stale/erro, cache LRU, modo brand+% | M |
| **S3 — Popover NSPanel** | UsagePanelController, UsageCardView (header/MetricRows/pace/extra/cost), UsageProgressBar, action rows, atalhos ⌘R/⌘,/⌘Q | G |
| **S4 — AppState + refresh loop** | Snapshot imutável, timer Task, coalescing, TaskLocal phase, triggers (startup/menu/manual), notificações depleted+thresholds | M |
| **S5 — Settings** | Janela 4 panes, SettingsStore actor-persisted, launch at login, keychain prompt policy UI | M |
| **S6 — Fonte CLI + watchdog** | PTYRunner async reescrito (thread dedicada), CLISession actor, parser `/usage`+`/status`, artifact cleaner, watchdog embutido no bundle, delegated refresh (depende de S1) | G |
| **S7 — Cost scan local** | Scanner JSONL incremental, pricing models.dev + fallback, agregação dia×modelo, seção Cost + submenu | M |
| **S8 — Packaging + polish** | `package_app.sh` (build universal, Helpers, codesign, notarize, staple), status page polling, animações idle, hide personal info, flash de warning | M |

Ordem: S1 → S2 → S4 → S3 → S5 → S6 → S7 → S8. MVP utilizável ao fim de S5 (OAuth-only). S6-S8 completam paridade.

---

## 8. Riscos

| # | Risco | Prob. | Mitigação |
|---|---|---|---|
| R1 | **`/api/oauth/usage` é endpoint não-documentado** com header beta (`oauth-2025-04-20`); Anthropic pode mudar schema, exigir novo beta header, ou bloquear UA `claude-code/*` de terceiros | MÉDIA-ALTA | Decoder tolerante (DynamicCodingKey, campos opcionais); UA com versão real do CLI local; fallback CLI (F7) funciona enquanto o `claude` existir; testes de contrato com fixtures |
| R2 | **Formato das credenciais do Claude Code muda** (path, keychain service, JSON shape, rotação de refresh token) | MÉDIA | Ordem de carga em camadas; fingerprint detecta mudança; delegated refresh (nunca consumir o refresh token do CLI — regra §4.1) já protege contra a rotação |
| R3 | **TUI do `claude` muda** → parser do `/usage` quebra (labels "Current session"/"Current week", prompts de confiança) | MÉDIA | Fallback posicional por ordem dos % (como o original); fonte CLI é P1, não P0; erro degrada para OAuth |
| R4 | **Keychain ACL**: bundle id novo = sem ACL herdada; usuário verá prompt do item "Claude Code-credentials" | CERTA (1ª execução) | Replicar UX do original: prompt policy default "only on user action", doc "Always Allow" (cf. `docs/keychain-allow.png` + README do original), preferência pelo arquivo `.credentials.json` que não promptea |
| R5 | Rate limit 429 no endpoint de usage se refresh frequente | BAIXA | Gate persistente com Retry-After; default 5 min; background curto-circuita |
| R6 | claude.ai web API (F8) muda/adiciona Cloudflare | MÉDIA | F8 é P2 e best-effort; nunca usado para identidade quando OAuth funciona |
| R7 | Formato JSONL dos logs do Claude Code muda (cost scan) | BAIXA-MÉDIA | Pré-filtro tolerante, campos opcionais, dedup defensivo; falha de parse = pula linha |
| R8 | Licença: CodexBar é MIT | — | Manter atribuição MIT + copyright notice no repo do clone |
| R9 | Swift 6 StrictConcurrency: a reescrita do PTY em thread dedicada com continuations tem sutilezas (leaks de continuation, double-resume) | MÉDIA | Testes de stress da S6; timeout duro em todo wait; watchdog como rede de segurança final |

---

*Spec gerado em 2026-06-10 a partir de 5 lentes de análise (provider, UI, performance, features, arquitetura, dados-locais) + crítica de completude. Arquivos de referência citados são absolutos sob `/tmp/CodexBar/`.*
