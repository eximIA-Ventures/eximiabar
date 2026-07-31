# Story EXB-5.4: Provider Codex enxuto (OAuth via `~/.codex/auth.json`)

**ID:** EXB-5.4
**Status:** Done
**Depends on:** EXB-5.1 (`AccountKey`/`Provider` — o provider Codex usa `provider: .codex`). **Pode rodar em paralelo com EXB-5.2.**
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M (4 arquivos novos, isolados; risco externo em `wham/usage` indocumentado — R15)

---

## Story

**As a** usuário do Codex CLI que também usa exímIABar,
**I want** ver os limites de sessão/semanal do Codex no mesmo app, numa versão enxuta que só usa OAuth de `~/.codex/auth.json` (sem WebView, sem RPC, sem cost scan),
**so that** eu tenha visibilidade de ambos os provedores (Claude + Codex) num único lugar, sem que uma versão inchada do provider traga complexidade desproporcional ao valor.

---

## Acceptance Criteria

### AC1 — Localização e escopo do módulo

1. O provider Codex vive em `Sources/ClaudeBarCore/Codex/` (subpasta do target existente `ClaudeBarCore`) — **não** um target SwiftPM novo, **não** um refactor de `ClaudeBarCore` → `EximiaBarCore` (dívida consciente, adiada; gatilho de revisão é a entrada de um **terceiro** provider).
2. Componentes novos:
   - `CodexAuthStore.swift` — `actor`, lê/parseia `~/.codex/auth.json` (ou `$CODEX_HOME/auth.json` se definido), fingerprint por mtime (espelha `CredentialsStore`)
   - `CodexJWTClaims.swift` — decode base64url do payload de `tokens.id_token` (**sem verificação de assinatura** — não somos o verificador), tolerante a campos desconhecidos
   - `CodexUsageFetcher.swift` — `actor`, `GET https://chatgpt.com/backend-api/wham/usage`, mapeia erros para `UsageError` (reusa o mapeamento existente)
   - `CodexUsageResponse.swift` — decoder tolerante (mesmo padrão de `OAuthUsageResponse`)

### AC2 — Fluxo OAuth enxuto

3. Passo 1: ler `~/.codex/auth.json` (arquivo `0600`, texto puro) — **zero keychain, zero prompt**.
4. Passo 2: decodificar `tokens.id_token` (JWT): `email` → identidade (`AccountKey(provider: .codex, identifier: email)`); `exp` → validade; `https://api.openai.com/auth.chatgpt_plan_type` → plano; `https://api.openai.com/auth.chatgpt_account_id` → id de conta.
5. Passo 3: `GET https://chatgpt.com/backend-api/wham/usage` com `Authorization: Bearer <tokens.access_token>`.
6. Passo 4: mapear `rate_limit.primary_window` → `RateWindow` de sessão; `rate_limit.secondary_window` → `RateWindow` semanal. `additional_rate_limits[]` (Spark e cia) é **ignorado** nesta onda — anotado no código como candidato à Onda 11, não implementado.
7. Passo 5: montar `UsageSnapshot(source: .oauth, identity: …, plan: …)` a partir do resultado.

### AC3 — Regra dura: nunca renovar (divergência deliberada da referência)

8. O `auth.json` é propriedade do `codex` CLI, exatamente como `.credentials.json` é do `claude` CLI (R6 por analogia). O provider **NUNCA** renova o token, mesmo que `last_refresh` tenha mais de 8 dias (o CodexBar original renova — **divergência intencional e mais restritiva**).
9. Token expirado → estado terminal explícito: `"expirado — rode \`codex login\`"`. Nenhum código deve tentar `POST` de refresh para o Codex.
10. **Teste obrigatório:** com um token cujo `exp` já passou, o fetcher retorna o estado de expiração terminal e **nunca** chama nenhum endpoint de refresh (spy/mock de rede).

### AC4 — Isolamento de falha

11. Uma falha do Codex (endpoint indisponível, schema mudou, `auth.json` corrompido) **nunca** degrada nem marca stale o painel Claude, e vice-versa. Cada painel carrega o próprio `UsageError`.
12. Se `~/.codex/auth.json` **não existir**, o provider Codex simplesmente **não aparece** no switcher — sem erro, sem linha vermelha, sem ruído visual.

### AC5 — Não entra no `SourcePlanner`/`FetchPipeline`

13. O Codex **não** é modelado como uma fonte alternativa dentro do `SourcePlanner`/`FetchPipeline` existentes (que modelam fontes de um mesmo provider, `oauth → cli → web`, com semântica de fallback testada em `SourcePlannerTests`). É um `actor` direto e independente, com uma única fonte (OAuth).
14. O ponto de composição com o restante do app (fan-out `async let` junto do fetch Claude) é entregue pela `EXB-5.3`, não por esta story — esta story entrega o provider isolado e testável por conta própria.

### AC6 — Build e testes

15. `swift build -c release` zero warnings.
16. `swift test` sem regressões da baseline registrada no Dev Agent Record da **`EXB-5.1`** — **não** da `EXB-5.2`. Esta story roda **em paralelo** com a `EXB-5.2` (ver header `Depends on`), logo não pode referenciar uma baseline que talvez ainda não exista quando ela for implementada.
17. Pelo menos **6 novos testes unitários**: `jwtClaimsDecodeTolerantIgnoresUnknownFields`, `missingAuthJsonMeansProviderSimplyAbsent`, `neverCallsRefreshEvenWhenTokenExpired`, `expiredTokenYieldsTerminalStateNotError`, `fingerprintGatePreventsReparseWhenMtimeUnchanged`, `codexFailureNeverPropagatesToClaudeSnapshot`.

### AC7 — Comandos de verificação (mecânicos)

18. **Regra dura de não-renovação (AC3), prova estrutural:** `grep -rniE "refresh|renew" Sources/ClaudeBarCore/Codex/` → nenhuma ocorrência que seja uma **chamada de rede de renovação**. Ocorrências permitidas: leitura do campo `tokens.refresh_token` do arquivo (que existe no `auth.json` mas não é usado) e comentários explicando a proibição. Output colado no Dev Agent Record com justificativa por linha.
19. **Escopo do módulo (AC1):** `ls Sources/ClaudeBarCore/Codex/` → exatamente os 4 arquivos previstos; `grep -n "CodexBarCore\|EximiaBarCore" Package.swift` → **zero** ocorrências (nenhum target novo).
20. **`additional_rate_limits` não implementado (AC2.6):** `grep -rn "additional_rate_limits" Sources/ClaudeBarCore/Codex/` → aparece apenas em comentário marcando Onda 11, nunca em código de mapeamento.

---

## Tasks

- [x] **T1 — `CodexAuthStore` actor** (AC1, AC2) — `Sources/ClaudeBarCore/Codex/CodexAuthStore.swift`, leitura + fingerprint gate
- [x] **T2 — `CodexJWTClaims`** (AC2) — `Sources/ClaudeBarCore/Codex/CodexJWTClaims.swift`, decode base64url tolerante
- [x] **T3 — `CodexUsageFetcher` + `CodexUsageResponse`** (AC2, AC4) — `Sources/ClaudeBarCore/Codex/CodexUsageFetcher.swift`, `CodexUsageResponse.swift`
- [x] **T4 — Regra dura de não-renovação** (AC3) — nenhum caminho de código chama refresh para Codex; estado terminal explícito
- [x] **T5 — Isolamento de falha** (AC4) — garantir que erro do Codex não contamina `DisplaySnapshot`/`UsageError` da Claude
- [x] **T6 — Testes** (AC6) — `Tests/ClaudeBarCoreTests/CodexProviderTests.swift`

---

## Dev Notes

### Descoberta que sustenta o desenho (D3, design da Onda 10)

`~/.codex/auth.json` (verificado na máquina): `{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token, account_id}, last_refresh}`. O `id_token` é um **JWT cujo payload já carrega `email`, `exp` e `https://api.openai.com/auth.chatgpt_plan_type`**. Identidade e plano saem do próprio token, sem chamada de rede extra e sem WebView — o provider enxuto é genuinamente enxuto.

### Decisão de módulo (por que subpasta, não target novo)

| Opção | Custo | Veredito |
|---|---|---|
| Target SwiftPM novo `CodexBarCore` | Extrair `RateWindow`, `UsageSnapshot`, `UsageError`, `ProviderCost`, `HTTPClient` para um terceiro target → refactor de 3 targets, ~90 arquivos tocados | Rejeitado agora — custo desproporcional |
| Subpasta `Sources/ClaudeBarCore/Codex/` | Zero refactor, reusa os modelos como estão | **Escolhido** |
| Renomear `ClaudeBarCore` → `EximiaBarCore` | `git mv` mecânico + import em ~90 arquivos | Adiado, dívida consciente |

### JWT — decode sem verificação de assinatura

Não somos o verificador da assinatura do token (isso é responsabilidade do backend do Codex). O decode aqui é **apenas leitura de claims** do payload (segundo segmento do JWT, base64url), tolerante a campos ausentes/desconhecidos.

### Fora de escopo (subtração deliberada, herdada do design)

- Cost scan do Codex (`~/.codex/sessions/**/*.jsonl`) — schema de evento diferente, candidato Onda 11
- `additional_rate_limits[]` (Spark etc.) — aditivo depois
- RPC `codex app-server`, WebView do dashboard, cookies de browser — explicitamente fora do pedido

### Anti-freeze invariants

- `CodexAuthStore` e `CodexUsageFetcher` são `actor` — todo I/O fora do MainActor
- Fetch de rede via `HTTPClient` existente do projeto, mesmo padrão do `UsageFetcher` da Claude

### Testing

- Arquivo: `Tests/ClaudeBarCoreTests/CodexProviderTests.swift`
- Mockar `~/.codex/auth.json` via `tmpdir`; mockar resposta HTTP de `wham/usage` via o mesmo seam de `HTTPClient` já usado nos testes de `UsageFetcher`

---

## Definition of Done

- [x] `CodexAuthStore`/`CodexJWTClaims`/`CodexUsageFetcher`/`CodexUsageResponse` criados em `Sources/ClaudeBarCore/Codex/`
- [x] Identidade e plano extraídos do JWT sem chamada de rede extra
- [x] Token do Codex **nunca** renovado, mesmo expirado — estado terminal explícito
- [x] Falha do Codex isolada, nunca degrada painel Claude
- [x] Ausência de `auth.json` = provider oculto, sem erro
- [x] Os 3 comandos da AC7 executados, output no Dev Agent Record
- [x] 6+ novos testes verdes (17); zero regressões
- [x] `swift build -c release` zero warnings

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Data:** 2026-07-31 · **Modo:** YOLO (autônomo)

### Baseline e resultado

| Momento | Testes | Falhas |
|---|---|---|
| Baseline `EXB-5.1` (medida antes de tocar em nada) | 336 | 0 |
| Depois desta story | 353 (336 + **17** novos) | 0 nesta story |

`Scripts/run-tests.sh` (nunca `swift test` cru — a máquina tem Command Line Tools sem Xcode).
Execução final da suíte completa: **367 testes em 46 suítes, todos verdes** (336 da baseline +
17 desta story + 14 da `EXB-5.2`, que rodou em paralelo). Numa execução intermediária houve 1
falha em `AccountRosterStoreTests.archivedAccountsNeverTriggerRefreshOrFetch` — arquivo da
`EXB-5.2` em andamento, reproduzida isolada sem nenhum código desta story em jogo, e já
corrigida pelo autor dela. **Zero regressões atribuíveis à EXB-5.4.**

Builds: `swift build --arch arm64` → `Build complete`. `swift build -c release --arch arm64` →
**zero warnings, zero errors**.

### Comandos da AC7 (output colado)

**AC7.18 — prova estrutural da não-renovação.** `grep -rniE "refresh|renew" Sources/ClaudeBarCore/Codex/`
retorna **16 linhas, todas comentário** (`///` ou `//`) — zero código executável. Justificativa por arquivo:

| Arquivo:linhas | Natureza | Por quê é permitido |
|---|---|---|
| `CodexUsageFetcher.swift:15,53,55,57,108,167` | comentários | documentam a proibição e o estado terminal (`never renew`, `no refresh path`, `no renewal attempted`) |
| `CodexAuthStore.swift:5,6,42,45,46,171,172,180` | comentários | documentam que `tokens.refresh_token` e `last_refresh` **não são sequer decodificados**, e a divergência deliberada da referência (que renova) |
| `CodexAuthStore.swift:41` | comentário | fala do *ciclo de refresh de 60 s da UI*, não de renovação de token |
| `CodexUsageFetcher.swift:90` | comentário | cita os gates da Claude só para dizer que este módulo **não** os toca |

A não-renovação não fica só na disciplina: o teste `noCodePathInTheCodexModuleCanRenewAToken`
lê o próprio fonte do módulo e falha se aparecer `POST`, `refresh_token`, `func refresh` ou
qualquer URL absoluta fora do endpoint de leitura. É um gate que morde, não uma promessa.

**AC7.19 — escopo do módulo.** `ls Sources/ClaudeBarCore/Codex/` → exatamente 4 arquivos
(`CodexAuthStore.swift`, `CodexJWTClaims.swift`, `CodexUsageFetcher.swift`,
`CodexUsageResponse.swift`). `grep -n "CodexBarCore\|EximiaBarCore" Package.swift` → **zero
ocorrências** (exit 1): nenhum target novo, nenhum rename.

**AC7.20 — `additional_rate_limits`.** Uma única ocorrência, em
`CodexUsageResponse.swift:20`, dentro de comentário marcando Onda 11. Nunca em código de
mapeamento.

### Descobertas e desvios (leitura obrigatória p/ @qa)

**D1 — O gate de validade lê o `access_token`, não o `id_token` (desvio da AC2.4, com prova).**
Medido no `~/.codex/auth.json` real desta máquina: os dois tokens são emitidos no mesmo
instante, mas `id_token.exp = iat + 1 h` e `access_token.exp = iat + 10 dias`. O `id_token` é
uma *asserção de identidade*; a frescura dele não diz nada sobre acesso à API. Gatear por ele
declararia "expirado" para qualquer usuário cujo CLI não rodou na última hora — ou seja, quase
sempre, e o provider nasceria inútil. Logo: **o token que vamos usar é o token que checamos**.
O `id_token` continua sendo a fonte de identidade e plano (AC2.4 no que importa), e o `exp`
dele é ignorado de propósito. Coberto por `expiryGateReadsTheAccessTokenNotTheIdToken`.

**D2 — `UsageSnapshot.plan` fica `nil`; o plano Codex vive em `CodexUsage.plan`.**
`UsageSnapshot.plan` é do tipo `ClaudePlan`, cujos rótulos são todos "Claude …"
(`brandedLoginMethod`). Preencher com o plano de uma conta ChatGPT renderizaria "Claude Pro"
sobre um usuário do Codex — mentira na tela. Os vocabulários também mal se sobrepõem
(`plus`, `go`, `business` não têm contraparte Claude). Por isso a AC2.7 é atendida com o plano
carregado em `CodexUsage.plan` (enum `CodexPlan`, rótulo `displayName` sempre "ChatGPT …"),
e a chamada do `UsageSnapshot` passa `plan:` explicitamente com o comentário da razão.
`EXB-5.3` deve ler `CodexUsage.plan`.

**D3 — Campos sem consumidor não são decodificados.** `last_refresh` está no arquivo, é
informativo, e nada nesta app age sobre ele. Decodificá-lo seria código morto que só serviria
de convite: é exatamente o campo que a referência usa para decidir renovar. Não lido, pela
mesma razão que `tokens.refresh_token` não é lido. A mesma régua eliminou `auth_mode`,
`iat` e `chatgpt_user_id`, que tinham entrado como "pode ser útil um dia" e não tinham
consumidor. Se a `EXB-5.3` precisar de algum deles, adicioná-lo é uma linha.

**D4 — Codex não reusa os gates da Claude.** `ClaudeOAuthUsageRateLimitGate` e
`ClaudeOAuthRefreshFailureGate` são estado global de processo; um 429 do Codex reusando-os
bloquearia um refresh da Claude, que é precisamente o acoplamento que a AC4.11 proíbe. O
Codex levanta `UsageError.rateLimited` puro. Provado em `codexFailureNeverPropagatesToClaudeSnapshot`,
que roda o fan-out `async let` real (Codex falhando, Claude saudável) e assere que o snapshot
Claude sai íntegro **e** que o gate da Claude continua limpo.

### Cobertura dos ACs

| AC | Onde | Teste |
|---|---|---|
| AC1.1/1.2 (4 arquivos, subpasta) | `Sources/ClaudeBarCore/Codex/` | `noCodePathInTheCodexModuleCanRenewAToken` (assere `files.count == 4`) + AC7.19 |
| AC2.3 (lê `auth.json`, zero keychain) | `CodexAuthStore` | `authStoreHonoursCodexHomeAndDefaultsToDotCodex` |
| AC2.4 (JWT → email/exp/plano/account) | `CodexJWTClaims` | `jwtClaimsDecodeTolerantIgnoresUnknownFields`, `jwtDecodeNeverCrashesOnMalformedPayload`, `unknownPlanTypeIsKeptVerbatimInsteadOfBeingDropped` |
| AC2.5 (GET com Bearer) | `CodexUsageFetcher.fetchUsage` | `rateLimitWindowsMapToSessionAndWeeklyLanes` (1 GET, URL exata, header `Bearer`) |
| AC2.6 (primary→sessão, secondary→semanal) | `CodexUsageFetcher.usage` | `rateLimitWindowsMapToSessionAndWeeklyLanes`, `windowLengthFallsBackToTheLaneDefaultWhenTheApiOmitsIt` |
| AC2.7 (monta `UsageSnapshot`) | idem | idem + D2 acima |
| AC3.8/3.9/3.10 (nunca renova) | módulo inteiro | `neverCallsRefreshEvenWhenTokenExpired` (zero requests), `expiredTokenYieldsTerminalStateNotError`, `noCodePathInTheCodexModuleCanRenewAToken` |
| AC4.11 (isolamento) | `CodexUsageFetcher` | `codexFailureNeverPropagatesToClaudeSnapshot`, `corruptAuthJsonSurfacesAsThisProvidersErrorNotSilence`, `httpErrorsMapToThisProvidersOwnUsageError` |
| AC4.12 (ausência = silêncio) | `CodexProviderState.absent` | `missingAuthJsonMeansProviderSimplyAbsent` |
| AC5.13/5.14 (fora do SourcePlanner) | actor independente | nenhum arquivo de `FetchPlan/` tocado (File List) |
| AC6.15/6.16/6.17 | build + suíte | 17 testes novos (mínimo era 6) |

### File List

**Criados**
- `Sources/ClaudeBarCore/Codex/CodexAuthStore.swift`
- `Sources/ClaudeBarCore/Codex/CodexJWTClaims.swift`
- `Sources/ClaudeBarCore/Codex/CodexUsageFetcher.swift`
- `Sources/ClaudeBarCore/Codex/CodexUsageResponse.swift`
- `Tests/ClaudeBarCoreTests/CodexProviderTests.swift`

**Modificados**
- `docs/stories/EXB-5.4.story.md` (este registro)

Nenhum arquivo existente de `Sources/` foi tocado — o provider é aditivo por construção, que é
o que permite ele ter rodado em paralelo com a `EXB-5.2` sem colisão.

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0) | @sm River |
| 2026-07-31 | 1.2 | Implementada. 4 arquivos em `Sources/ClaudeBarCore/Codex/` + 17 testes (mínimo era 6). 3 desvios documentados (D1 gate de validade lê o `access_token`, D2 plano Codex fora do `UsageSnapshot.plan`, D3 `last_refresh` não decodificado). Status → Ready for Review. | @dev Dex |
| 2026-07-31 | 1.1 | Validação @po: **GO 9/10**. Corrigida contradição interna: AC6 exigia baseline da `EXB-5.2`, mas o header declara execução **em paralelo** com ela — baseline passa a ser a da `EXB-5.1`. Adicionada AC7 com 3 comandos mecânicos, incluindo a prova estrutural da regra de não-renovação (R6 estendida). Complexidade estimada. Status → Ready. | @po Pax |

---

## QA Results (@qa Quinn) — 2026-07-31

**Veredito: PASS.** A regra dura desta story (nunca renovar) foi provada contra o `~/.codex/auth.json` **real** desta máquina, não contra fixture.

### Prova executada por mim, contra o arquivo de produção

Binário descartável linkado contra o `ClaudeBarCore` de **release**, com um `HTTPTransport` que **recusa qualquer chamada de rede** e conta tentativas:

```
estado = .expired("expirado — rode `codex login`")
tentativas de rede = 0
```

Dois fatos que isso estabelece de uma vez:

1. **O gate de validade corta ANTES da rede.** Zero tentativas com um token morto — não há requisição especulativa, não há caminho de renovação alcançável em runtime.
2. **Token expirado é estado terminal, não erro.** `.expired` com a mensagem que diz ao usuário o único comando que resolve. Não lança, não polui o painel Claude.

Leitura do mesmo arquivo real, pelo código de produção:

```
accessToken presente = true (len 1558)
idToken presente     = true
accountID            = <account_id real, redigido>
email (id_token)     = <conta Codex secundária, redigido>
plan                 = ChatGPT Plus
id_token expirado?   = true   <- exp ignorado de proposito (D1)
access_token expira  = 2026-07-27 17:34:43 +0000
access_token expirado? = true <- ESTE e o gate real
```

**O desvio D1 do @dev está empiricamente correto e é importante.** O `id_token` real está expirado; se o gate lesse o `exp` dele, o provider nasceria morto para qualquer usuário cujo CLI não rodou na última hora. Ler o `access_token` é a decisão certa, e a identidade/plano continuam vindo do `id_token`, que é o papel dele.

### Demais verificações

| Verificação | Comando | Resultado |
|---|---|---|
| AC7.18 (não-renovação) | `grep -rn "refresh_token\|func refresh\|POST" Sources/ClaudeBarCore/Codex/` | 3 ocorrências, **todas comentário** (`CodexAuthStore:5,180`, `CodexUsageFetcher:55`) — zero código executável. Reforçado pelo teste `noCodePathInTheCodexModuleCanRenewAToken`, que varre o próprio fonte |
| AC7.19 (escopo) | `ls Sources/ClaudeBarCore/Codex/` | exatamente **4** arquivos |
| AC4.12 (ausência = silêncio) | `missingAuthJsonMeansProviderSimplyAbsent` | `.absent` **e** `requestCount == 0` — ausência é silenciosa e gratuita |
| AC4.11 (isolamento) | `codexFailureNeverPropagatesToClaudeSnapshot` | fan-out `async let` real, Codex offline + auth inutilizável, Claude sai íntegro **e** o `ClaudeOAuthUsageRateLimitGate` fica limpo. D4 (não reusar os gates da Claude) é a decisão certa |
| Isolamento de ator | o próprio compilador | `CodexAuthStore.load()` recusou chamada síncrona de fora do ator na minha sonda — I1 garantido pelo type system, não por disciplina |

### CONCERNS

- **QA-C1 (MÉDIO) — o caminho feliz do Codex nunca foi observado em dado real.** O `access_token` desta máquina expirou em **2026-07-27** (4 dias atrás). Todo o comportamento de sucesso (`.available`, session/weekly reais no switcher) está provado **só por fixture**. O item de Wave DoD *"o switcher lista o provider Codex com session/weekly reais"* **não pode ser marcado** sem um `codex login` prévio. Não é defeito de código — o comportamento no estado expirado está correto e provado —, é uma lacuna de verificação que recai sobre o smoke test da `EXB-5.6`.
