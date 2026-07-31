# Onda 10 — Multi-conta Claude + Provider Codex

> **Documento de arquitetura** — insumo direto para o `@sm` criar os story files formais.
> **Autor:** Aria (@architect) · **Data:** 2026-07-31 · **Status:** Proposto, aguarda validação `@po`
> **Baseline verificada:** `swift build --arch arm64` → `Build complete! (72.41s)`, exit 0, HEAD `7b48acb` (v2.3.2)
> **Escopo:** design + quebra em stories. **Nenhum arquivo Swift foi alterado por este documento.**

---

## 0. Sumário executivo

Duas mudanças pedidas pelo dono do produto:

1. **Multi-conta Claude** — hoje o app resolve *uma* credencial (a que o `claude` CLI mantém viva) e não tem noção de que existem outras contas. A Onda 10 introduz um **roster de contas** alimentado por **captura automática no momento do login**: quando o polling de fingerprint (já existente, 60 s) detecta que a identidade da credencial mudou, a conta anterior é **arquivada** antes de ser perdida. Contas arquivadas são **estritamente somente-leitura** — nunca renovadas.
2. **Provider Codex** — versão enxuta do provider do CodexBar original: **apenas OAuth via `~/.codex/auth.json`**, sem WebView de dashboard, sem RPC `codex app-server`, sem cost scan.

UX decidida: **switcher** (uma conta/provider em foco por vez), e o **ícone da menu bar continua ancorado na conta viva do CLI**, independentemente do foco do painel.

### As três descobertas que mudam o desenho

| # | Descoberta | Consequência |
|---|---|---|
| **D1** | `UsageSnapshot.identity` **existe mas é sempre `nil`** — `UsageFetcher.fetchSnapshot` (`UsageFetcher.swift:43`) nunca passa o parâmetro `identity:`, e `OAuthUsageResponse` não tem campo de e-mail (`grep email` → zero ocorrências). O e-mail que aparece hoje no header do popover (`UsageCardView.swift:92`) **nunca é preenchido**. | Não existe "email resolvido na credencial" para comparar. **A resolução de identidade tem de ser construída antes de qualquer coisa** — é o pré-requisito de tudo. Vira a story EXB-5.1. |
| **D2** | A identidade vive em **`~/.claude.json` → `oauthAccount`** (verificado na máquina: `emailAddress`, `accountUuid`, `displayName`, `organizationName`). Arquivo modo `600`, texto puro, **sem keychain e sem prompt**. | Fonte de identidade barata, fingerprintável por `mtime` — mesmo padrão já usado para `.credentials.json`. Mas é um arquivo de **45 KB** cuja forma é indocumentada → decodificação tolerante + gate por fingerprint obrigatórios. |
| **D3** | `~/.codex/auth.json` (verificado): `{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token, account_id}, last_refresh}`. O `id_token` é um **JWT cujo payload já carrega `email`, `exp` e `https://api.openai.com/auth.chatgpt_plan_type`**. | Identidade e plano do Codex saem do próprio token, sem chamada de rede e sem WebView. O provider enxuto é genuinamente enxuto. |

---

## 1. Invariantes que nada nesta onda pode violar

Herdados do `EPIC-EXB.md` (§Architecture Summary) e testados hoje:

| # | Invariante | Onde é testado |
|---|---|---|
| **I1** | Zero I/O na main thread. Fetch roda em `Task.detached` (`AppState.swift:129`); só a atribuição final volta ao `MainActor`. | `AppStateTests` |
| **I2** | PTY/subprocess nunca no cooperative thread pool — `Thread` dedicada + `CheckedContinuation`. | `CLITests` |
| **I3** | `AppState` publica **exatamente uma** propriedade observável, atribuída **atomicamente uma vez por ciclo** (`AppState.swift:21` + `:191`). | `AppStateTests`, `DisplaySnapshotTests` |
| **I4** | Dropdown é `NSPanel`, nunca `NSMenu` + `NSHostingView` para conteúdo dinâmico. | `UsagePanelController.swift:7-13` |
| **I5** | **R6 (o mais crítico):** nunca consumir/renovar externamente um token de propriedade do CLI. `owner == .claudeCLI` → refresh delegado via `claude /status`, jamais `POST`. | `RefreshOwnershipTests` |

A Onda 10 **estende I5**: contas arquivadas e o token do Codex passam a ser um segundo e um terceiro caso de "token que não é nosso para renovar".

---

## 2. Design

### 2.1 Roster de contas — o novo tipo, e onde persiste

#### Modelo

```
AccountKey            = (provider: Provider, identifier: String)   // identifier = e-mail normalizado (lowercase, trim)
Provider              = .claude | .codex                            // enum novo em ClaudeBarCore/Model/
AccountIdentity       = { key, email, displayName?, organizationName?, accountUUID? }
AccountLifecycle      = .live | .archived
AccountRosterEntry    = { identity, lifecycle, plan?, capturedAt, lastSeenAt, tokenExpiresAt? }
```

`AccountRosterEntry` é **puro metadado — não contém segredo nenhum**. Essa separação é o coração do desenho.

#### Persistência: split deliberado em duas camadas

| Camada | O quê | Onde | Por quê |
|---|---|---|---|
| **Índice** (metadado) | `[AccountRosterEntry]` + `focusedKey` | JSON em `~/Library/Application Support/exímIABar/accounts.json`, modo `0600` | Enumerável e legível **sem tocar no keychain**. O switcher renderiza a lista inteira, e o estado "expirado — faça login de novo" é derivado de `tokenExpiresAt` **sem ler o segredo**. Barato, inspecionável, testável com `tmpdir`. |
| **Segredos** | token da conta arquivada | Keychain próprio, service **`com.eximia.eximiabar.accounts`**, `account = "{provider}:{email}"` | Serviço **irmão** do `cacheKeychainService` já existente (`CredentialsStore.swift:33`). É um item **nosso** — nossa partition list nos confia, logo **não reintroduz o pop-up** que a EXB-3.8 eliminou (o pop-up vinha do item do Claude Code, que confia em `/usr/bin/security` mas não em nós). |

**Recomendação com divergência declarada (decisão para o `@po`/Hugo):** o briefing pede arquivar *access token, refresh token, validade e e-mail*. Recomendo **NÃO arquivar o refresh token**.
*Racional:* pela própria regra R6/R-new, **nunca vamos usá-lo** — conta arquivada jamais é renovada. Guardar um refresh token de longa validade que nunca será lido é passivo de segurança puro (R14). Guardar apenas `accessToken` + `expiresAt` entrega exatamente o comportamento pedido ("mostra a conta até expirar, depois manda logar de novo") com uma superfície de ataque estritamente menor. *Se o `@po` mantiver o refresh token, o desenho não muda — só o payload da entrada de keychain.*

Atributos de keychain para as entradas do roster: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (mais restrito que o `AfterFirstUnlock` do cache atual, e sem sincronização iCloud).

#### Componente

```
public actor AccountRosterStore     // Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift
    func roster() -> AccountRoster                       // índice (arquivo) — sem keychain
    func archivedToken(for: AccountKey) -> ArchivedToken? // keychain, sob demanda (só no fetch/render do card)
    func captureIfIdentityChanged(current: AccountIdentity, credentials: …) -> CaptureOutcome
    func remove(_ key: AccountKey)
    func setFocus(_ key: AccountKey)
```

`actor` pelo mesmo motivo do `CredentialsStore` — **todo I/O de roster fica atrás de `await`, fora do MainActor** (I1). Mesmo seam de teste já provado no repo: o service de keychain é **injetável** (`CredentialsStore.swift:41` documenta exatamente por que isso importa — o processo de teste tocando o item real foi o que disparou o prompt na EXB-3.8). O `AccountRosterStore` **deve** herdar esse seam desde o primeiro commit.

#### Captura automática no login (o gatilho)

O `CredentialsStore.pollFingerprintsAndInvalidateIfChanged()` (`CredentialsStore.swift:429`) já roda no máximo 1×/60 s e já detecta mudança de `.credentials.json` e do item de keychain. A captura **pendura-se nesse mesmo ponto**, sem novo timer:

```
fingerprint mudou
  └─ resolve identidade atual (~/.claude.json → oauthAccount)          [EXB-5.1]
       └─ identidade != última conhecida?
            ├─ SIM → arquiva a credencial ANTERIOR (a que ainda está em cache) no roster
            │        marca a nova como .live, mantém foco no menu bar na .live
            └─ NÃO → nada a fazer (invalidação de cache segue como hoje)
```

**Regra dura contra corrida (R11):** só arquiva quando o parse da credencial anterior **e** a resolução de identidade tiveram sucesso. Um `.credentials.json` lido a meio da escrita do `claude login` (escrita não-atômica) resulta em parse falho → **não arquiva nada**, tenta de novo no próximo poll. Arquivar lixo é pior que perder um ciclo.

#### Contas arquivadas são somente-leitura — o contrato

| Operação | Conta `.live` | Conta `.archived` |
|---|---|---|
| Fetch de usage | Sim, todo ciclo | **Nunca** |
| Refresh de token | Delegado ao CLI (R6) | **Nunca**, em nenhuma circunstância |
| Exibição no switcher | Sim | Sim |
| Token expirado | Refresh delegado | Estado terminal **`expirado — faça login nesta conta para recapturar`** |

O `RefreshCoordinator` **não é modificado**. A garantia é estrutural: contas arquivadas nunca chegam a ele, porque o único caminho de fetch parte da credencial `.live`. Isso deve ser travado por um teste (§6, T-R9).

---

### 2.2 `AppState`: de escalar para coleção, sem quebrar I3

Este é o ponto de maior risco arquitetural da onda, e a solução precisa ser exata.

**O que NÃO fazer:** `var snapshots: [AccountKey: DisplaySnapshot]`. Formalmente é uma propriedade só, mas `snapshots[k] = v` é uma mutação incremental observável — N contas produziriam N notificações por ciclo. Isso **é** a tempestade de `@Observable` que o projeto existe para eliminar. Rejeitado.

**O que fazer:** introduzir um agregado imutável novo e manter **uma única propriedade armazenada**.

```swift
struct WorkspaceSnapshot: Sendable, Equatable {          // Sources/ClaudeBar/App/WorkspaceSnapshot.swift
    let accounts: [AccountPane]        // 1 entrada por conta do roster + Codex, ordem estável
    let focusedKey: AccountKey         // qual está em foco no painel
    let menuBarKey: AccountKey         // qual alimenta o ícone — SEMPRE a Claude .live
    let updatedAt: Date

    struct AccountPane: Sendable, Equatable {
        let identity: AccountIdentity
        let lifecycle: AccountLifecycle
        let display: DisplaySnapshot?  // nil para arquivada sem dado / expirada
        let status: PaneStatus         // .live | .archivedValid | .archivedExpired | .unavailable
    }
}
```

E no `AppState`:

```swift
var workspace: WorkspaceSnapshot?                              // ← a ÚNICA propriedade armazenada observável
var snapshot: DisplaySnapshot? { workspace?.focused?.display } // ← computada, não é storage
var menuBarSnapshot: DisplaySnapshot? { workspace?.menuBar?.display }
```

**Por que isso preserva I3 literalmente:** uma propriedade **computada** não é storage observável. O `withObservationTracking` do SwiftUI/AppKit registra a leitura de `workspace` (o storage que a computada consulta) e dispara **uma vez** quando `workspace` é reatribuída. Continua sendo: um ciclo → uma atribuição atômica → uma notificação. O número de contas não muda isso.

**Como o ciclo monta o agregado sem múltiplas atribuições:** dentro do mesmo `Task.detached` que já existe (`AppState.swift:129`), buscar Claude e Codex **concorrentemente** com `async let`, juntar, montar o `WorkspaceSnapshot` inteiro, e só então um único `await self?.completeFetch(...)`. Contas arquivadas **não** entram nesse fan-out — elas não fazem fetch, seus painéis são montados a partir do metadado do roster.

```
Task.detached {
    async let claude = fetchClaudeLive(phase)      // 1 fetch
    async let codex  = fetchCodexIfPresent(phase)  // 1 fetch, independente
    let archived = rosterPanes()                   // 0 fetch — metadado
    let ws = WorkspaceSnapshot(assembling: claude, codex, archived, focus: …)
    await completeFetch(ws, phase: phase)          // 1 atribuição
}
```

**Trocar o foco no switcher não dispara fetch.** É `workspace = workspace.withFocus(newKey)` — uma atribuição atômica sobre dado que já está em memória. Troca de conta é instantânea e gratuita.

**Compatibilidade dos consumidores** (superfície pequena, verificada): `StatusItemController`, `UsagePanelController`, `UsageCardView`, `QuotaNotifier`, `ClaudeBarApp`, mais os testes. Mitigação: manter o parâmetro `snapshot:` do `init` do `AppState` como conveniência que embrulha num workspace de conta única — os testes existentes seguem compilando sem reescrita.

**Decoupling explícito (pedido do dono):** `StatusItemController.update(snapshot:)` passa a ser alimentado por `menuBarSnapshot`, **não** por `snapshot`. Trocar o foco no painel **não** altera o medidor da menu bar. `QuotaNotifier` idem — as notificações continuam sendo sobre a conta viva, senão o usuário receberia alerta de cota de uma conta arquivada e congelada.

---

### 2.3 Provider Codex

#### Onde mora — decisão de módulo

Três opções pesadas:

| Opção | Custo | Veredito |
|---|---|---|
| Target SwiftPM novo `CodexBarCore` | Precisa extrair `RateWindow`, `UsageSnapshot`, `UsageError`, `ProviderCost`, `HTTPClient` para um terceiro target compartilhado → refactor de 3 targets, ~90 arquivos tocados | **Rejeitado agora.** Custo desproporcional ao valor de 1 provider enxuto. |
| Subpasta `Sources/ClaudeBarCore/Codex/` | Zero refactor, reusa os modelos como estão | **Escolhido.** Complexidade progressiva: simples agora, escalável depois. |
| Renomear `ClaudeBarCore` → `EximiaBarCore` | `git mv` mecânico + `import` em ~90 arquivos; ruído grande numa onda já grande | **Adiado.** Registrado como dívida consciente. |

**Gatilho de revisão declarado:** quando entrar um **terceiro** provider, extrair `EximiaBarCore` (modelos + HTTP + logging) e deixar `ClaudeProvider` / `CodexProvider` como targets irmãos. Antes disso, é over-engineering.

#### Fluxo OAuth (enxuto)

```
1. Ler ~/.codex/auth.json (ou $CODEX_HOME/auth.json)   — arquivo 0600, texto puro, ZERO keychain, ZERO prompt
2. Decodificar tokens.id_token (JWT, base64url do payload — sem verificar assinatura, não somos o verificador):
     email                                  → identidade  (AccountKey do provider .codex)
     exp                                    → validade
     https://api.openai.com/auth
        .chatgpt_plan_type                  → plano
        .chatgpt_account_id                 → id de conta
3. GET https://chatgpt.com/backend-api/wham/usage
     Authorization: Bearer <tokens.access_token>
4. Mapear rate_limit.primary_window   → session (RateWindow)
          rate_limit.secondary_window → weekly  (RateWindow)
   additional_rate_limits[] → IGNORADO nesta onda (Spark & cia) — anotado como candidato Onda 11
5. → UsageSnapshot(source: .oauth, identity: …, plan: …)
```

**Divergência deliberada da referência, e por quê:** o CodexBar original **renova** o token quando `last_refresh` tem mais de 8 dias. Nós **não vamos renovar**. O `auth.json` é propriedade do `codex` CLI, exatamente como o `.credentials.json` é do `claude` CLI — R6 se aplica por analogia direta. Token expirado do Codex → estado terminal **`expirado — rode `codex login``**, nunca uma renovação por fora que possa colidir com o fluxo do próprio CLI. Isto é mais restritivo que a referência, e é intencional.

#### Onde entra no pipeline existente

**Não entra no `SourcePlanner`/`FetchPipeline`.** Estes modelam *fontes* de um mesmo provider (`oauth → cli → web`), com semântica de fallback testada em `SourcePlannerTests`. Codex não é uma fonte alternativa de dado da Claude; é outro provider. Enfiá-lo ali corromperia um contrato testado por um ganho nulo.

Como o Codex enxuto tem **uma única fonte**, ele dispensa pipeline. O componente é um actor direto:

```
Sources/ClaudeBarCore/Codex/
    CodexAuthStore.swift        actor — lê/parseia auth.json, fingerprint por mtime (espelha CredentialsStore)
    CodexJWTClaims.swift        decode base64url do payload (sem verificação de assinatura), tolerante
    CodexUsageFetcher.swift     actor — GET wham/usage, mapeia erros para UsageError (reusa o mapeamento existente)
    CodexUsageResponse.swift    decoder tolerante (mesmo padrão de OAuthUsageResponse)
```

O ponto de composição é o **`LiveUsageProvider.makeFetch()`** (`LiveUsageProvider.swift:107`), que hoje devolve `AppState.Fetch` produzindo um `DisplaySnapshot`. Vira um `WorkspaceProvider.makeFetch()` devolvendo `WorkspaceSnapshot`, orquestrando os dois providers com `async let` conforme §2.2.

**Isolamento de falha:** uma falha do Codex **nunca** degrada o caminho Claude, e vice-versa. Cada painel carrega o próprio `UsageError`. Codex ausente (sem `auth.json`) = provider simplesmente não aparece no switcher — sem erro, sem linha vermelha, sem ruído.

---

### 2.4 UI do switcher

**Onde:** a linha 1 do `HeaderSection` do `UsageCardView` (`UsageCardView.swift:76-102`) já é exatamente `logo eximIA + "Claude" + e-mail`. Ela vira o **chip de conta clicável** — o lugar mais natural possível, zero layout novo.

```
┌──────────────────────────────────────────┐
│ ◈ Claude · hugo@…gmail.com          ⌄    │  ← chip: clicar troca o corpo do card pela lista
├──────────────────────────────────────────┤
│ Session  ▓▓▓▓▓▓░░░░  62%   reset 2h14   │
│ Weekly   ▓▓▓░░░░░░░  31%   reset 4d      │
└──────────────────────────────────────────┘
        ↓ clicou no chip
┌──────────────────────────────────────────┐
│ ← Contas                                 │
│ ● Claude  hugo@gmail.com      ao vivo    │  ← .live (bolinha cheia)
│ ○ Claude  hugo@eximia.com     arquivada  │  ← .archivedValid
│ ○ Claude  antiga@x.com        expirada · faça login nela de novo
│ ○ Codex   hugo@openai…        ao vivo    │
└──────────────────────────────────────────┘
```

**Restrição de anti-freeze (I4) — a armadilha a evitar:** **não** usar `Menu` do SwiftUI nem `NSPopUpButton` para o switcher. Ambos materializam um `NSMenu` real e reintroduzem exatamente o run loop de menu-tracking que o `NSPanel` existe para evitar. A solução é uma **lista inline dentro do próprio card** (troca de conteúdo do `VStack` já hospedado), sem nenhum AppKit de menu envolvido. Isto tem de estar escrito na story como restrição, não como sugestão.

**Estado do switcher:** o `focusedKey` vive no `WorkspaceSnapshot` (persistido no índice do roster), **não** em `@State` da view. A view continua sendo função pura do snapshot (`UsageCardView.swift:20-21` documenta isso como contrato) — clicar num item chama uma action que faz `appState.focus(key)`, que faz uma reatribuição atômica.

**Settings:** aba nova (ou seção na aba General) listando o roster com ação **remover conta** e um rótulo explicando que contas arquivadas são somente-leitura. `PreferencesGeneralPane` já é o lugar; a repaginação em 4 abas por intenção veio na v2.1.4 e deve ser respeitada.

---

## 3. Riscos novos (continuação de R1–R8 do `EPIC-EXB.md`)

| # | Risco | Prob. | Mitigação |
|---|---|---|---|
| **R9** | **Token arquivado diverge do comportamento esperado.** O usuário vê uma conta arquivada com dados de horas atrás e supõe que estão vivos; ou o app tenta renovar e colide com o fluxo do CLI (violação de R6 por uma porta nova). | **ALTA** se não tratado | Estado explícito por painel (`.live` / `.archivedValid` / `.archivedExpired`), rótulo textual visível, `updatedAt` sempre renderizado em conta arquivada. Estrutural: **contas arquivadas nunca chegam ao `RefreshCoordinator`** — o caminho de fetch parte só da `.live`. **Teste obrigatório T-R9:** com N contas arquivadas no roster, um ciclo completo de refresh executa **zero** chamadas de refresh/fetch para elas (spy no coordinator). |
| **R10** | **I/O de roster fora da main thread.** Keychain (`SecItemCopyMatching`) e leitura de arquivo são síncronos e bloqueiam; uma leitura acidental dentro de `body`/`viewDidLoad` reintroduz o freeze que o projeto inteiro combate. | MÉDIA | `AccountRosterStore` é `actor` — todo acesso é `await`, impossível de chamar de um `body` síncrono. O índice é lido **uma vez por ciclo**, no `Task.detached`, e viaja dentro do `WorkspaceSnapshot`; a UI **nunca** consulta o store. **Teste T-R10:** nenhuma anotação `@MainActor` no store; assert de que a UI só lê do snapshot. |
| **R11** | **Corrida na captura:** `claude login` reescreve `.credentials.json` de forma não-atômica; podemos ler um arquivo cortado e arquivar lixo, ou arquivar a conta errada. | MÉDIA | Só arquiva quando parse **e** resolução de identidade tiveram sucesso; parse falho = no-op e nova tentativa em 60 s. Nunca sobrescreve uma entrada de roster existente com dados de parse parcial. |
| **R12** | **`~/.claude.json` é indocumentado** (45 KB, forma pode mudar) e é a única fonte de e-mail. Se `oauthAccount` sumir ou mudar de nome, o roster fica cego. | MÉDIA | Decoder tolerante que extrai **apenas** `oauthAccount`. Fallback de degradação: se ausente, usar `sha256(accessToken)[0..8]` como chave opaca e rotular `Conta 2` — o roster continua funcionando sem e-mail. Leitura **gated por fingerprint de mtime** (não reparsear 45 KB a cada 60 s). |
| **R13** | **Roster cresce sem limite** e acumula contas mortas de meses atrás. | BAIXA-MÉDIA | Teto de **8** entradas, evicção LRU por `lastSeenAt`, mais a ação explícita "remover conta" em Settings. |
| **R14** | **Segredos em repouso — superfície nova.** Guardar tokens de contas arquivadas é um ativo que não existia antes da Onda 10. | MÉDIA | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, sem iCloud sync, service próprio. **E a mitigação mais forte: não guardar o refresh token** (§2.1) — não usamos, logo não guardamos. Índice em arquivo `0600` contém só metadado, nunca segredo. |
| **R15** | **`wham/usage` do Codex é indocumentado**, atrás de Cloudflare, e pode bloquear por UA ou mudar schema. | MÉDIA-ALTA | Decoder tolerante (mesmo padrão de `OAuthUsageResponse`). **Isolamento de falha:** erro do Codex nunca degrada o caminho Claude. Codex ausente = provider oculto, sem erro visível. |
| **R16** | **Reintrodução do pop-up de keychain** — a EXB-3.8 custou uma onda inteira para eliminá-lo; um service novo mal configurado o traz de volta. | MÉDIA | O item é **nosso** (partition list nos confia), diferente do item do Claude Code. Todas as queries usam `KeychainNoUIQuery`. **Service injetável desde o primeiro commit** para que o processo de teste jamais toque o item real — exatamente a causa-raiz documentada em `CredentialsStore.swift:36-40`. Verificação manual: 30 min de uso, zero diálogos. |
| **R17** | **Regressão nos consumidores de `AppState.snapshot`** ao virar propriedade computada. | BAIXA | Superfície verificada e pequena (5 arquivos + testes). `init(snapshot:)` mantido como conveniência que embrulha em workspace de conta única. |
| **R18** | **Switcher via `NSMenu` disfarçado** — `Menu` do SwiftUI / `NSPopUpButton` materializam um `NSMenu` e violam I4 silenciosamente (compila, roda, e o freeze volta em produção). | **ALTA** se não travado | Restrição escrita na story: lista **inline** no card, proibido `Menu`/`NSPopUpButton`/`NSMenu` no switcher. Grep de verificação no DoD. |

---

## 4. Quebra em stories — **Onda 10 (v2.4.0)**

**Numeração:** as ondas formais documentadas vão até a **Onda 9** (`EXB-4.1`–`EXB-4.5`). Os story files em `docs/stories/` param em `EXB-4.5`. Logo a onda nova é a **Onda 10**, prefixo **`EXB-5.x`** — sem colisão.

> **Nota de honestidade documental:** `git tag` mostra releases de **v1.7 até v2.3.2** sem story files correspondentes — o `EPIC-EXB.md` está defasado do código real (a última onda documentada é a v1.6.0, o HEAD é v2.3.2). Este documento **não tenta reconstruir retroativamente** essas ondas; a Onda 10 é anexada ao epic como continuação. Reconciliar o histórico é trabalho separado, e recomendo registrá-lo no inbox em vez de embutir nesta onda.

| Order | Story ID | Title | Executor | Rationale |
|-------|----------|-------|----------|-----------|
| 1 | **EXB-5.1** | Resolução de identidade da conta Claude (`~/.claude.json`) | @dev | **Fundação de tudo.** Descoberta D1: `UsageSnapshot.identity` existe mas é sempre `nil` — não há e-mail para comparar, logo não há como detectar troca de conta. Entrega o `Provider`/`AccountKey`/`AccountIdentity`, o leitor gated por fingerprint, e finalmente popula o e-mail que o header do popover já tenta exibir desde a EXB-1.3. |
| 2 | **EXB-5.2** | Roster de contas: captura no login + persistência somente-leitura | @dev | Depende de 5.1 (indexado por e-mail). Entrega `AccountRosterStore` (actor), índice em arquivo `0600` + segredos em keychain próprio, e o gancho de captura no `pollFingerprintsAndInvalidateIfChanged` existente. Cobre R9/R10/R11/R13/R14/R16. |
| 3 | **EXB-5.4** | Provider Codex enxuto (OAuth via `~/.codex/auth.json`) | @dev | Só depende de `AccountKey` (5.1) — **pode rodar em paralelo com 5.2**. Entrega `CodexAuthStore`, decode de claims do JWT, `CodexUsageFetcher` (`wham/usage`) e o mapeamento para `UsageSnapshot`. Regra dura: nunca renovar o token do Codex. Cobre R15. |
| 4 | **EXB-5.3** | `WorkspaceSnapshot` + generalização do `AppState` | @dev | Depende de 5.2 (enumerar roster) **e** 5.4 (painel do Codex). O ponto de maior risco arquitetural: uma propriedade armazenada observável, `snapshot` vira computada, fan-out `async let` com uma única atribuição por ciclo. Desacopla ícone da menu bar do foco do painel. Cobre I3/R17. |
| 5 | **EXB-5.5** | Switcher no painel + gestão de contas em Settings | @dev | Depende de 5.3 (consome o workspace). Chip de conta no header vira lista inline; estados `ao vivo`/`arquivada`/`expirada`; remover conta em Settings. Restrição inegociável: **sem `NSMenu`/`Menu`/`NSPopUpButton`**. Cobre R18. |
| 6 | **EXB-5.6** | Release v2.4.0 | @devops | Última por construção — corta a release do código completo da onda, atualiza cask Homebrew e README. Segue o padrão das Ondas 4 e 5, que terminaram em story de distribuição. |

**Ordem de execução:** `5.1 → (5.2 ∥ 5.4) → 5.3 → 5.5 → 5.6`
Sequencial puro se o executor for único: `5.1 → 5.2 → 5.4 → 5.3 → 5.5 → 5.6`.

### Fora de escopo (subtração deliberada)

| Item | Por quê |
|---|---|
| Cost scan do Codex (`~/.codex/sessions/**/*.jsonl`) | Schema de evento diferente (`event_msg` token_count + `turn_context`), não é o `CostScanner` atual com outro caminho. Trabalho real, valor secundário à contagem de limites que foi pedida. **Candidato Onda 11.** |
| `additional_rate_limits[]` do Codex (Spark etc.) | Enxuto significa enxuto. Aditivo depois, sem quebrar nada. |
| RPC `codex app-server`, WebView do dashboard, cookies de browser | Explicitamente fora do pedido — a WebView é cara e é opt-in até na referência. |
| Login de conta nova **de dentro** do app | A captura é por snapshot no login do CLI, por decisão do dono. Fazer login por fora seria assumir a propriedade do token — colisão frontal com R6. |
| Renomear `ClaudeBarCore` → `EximiaBarCore` | Dívida consciente. Gatilho: entrada de um terceiro provider. |
| Reconciliar as ondas v1.7–v2.3.2 ausentes do epic | Trabalho documental separado; registrar no inbox. |

---

## 5. Wave DoD (objetivo e verificável)

- [ ] Todas as 6 stories `Done`
- [ ] `swift build -c release` sem novos warnings com todo o código da Onda 10
- [ ] `swift test` passando sem regressão da baseline pré-onda (contagem registrada no início da 5.1)
- [ ] **Identidade:** com o Claude Code logado, o header do popover mostra o e-mail real de `~/.claude.json` (hoje mostra vazio, sempre) — verificável a olho
- [ ] **Captura:** após `claude login` numa segunda conta, em ≤ 60 s o roster contém **2** entradas, a nova `.live` e a anterior `.archived` — verificável por inspeção de `~/Library/Application Support/exímIABar/accounts.json`
- [ ] **Somente-leitura (T-R9):** teste automatizado prova **zero** chamadas de refresh/fetch para contas arquivadas num ciclo completo de refresh
- [ ] **Expiração:** conta arquivada com `tokenExpiresAt` no passado renderiza o rótulo de expiração e **não** tenta renovar
- [ ] **Invariante I3 (T-I3):** teste prova que um ciclo de refresh com N ≥ 3 contas produz **exatamente uma** atribuição a `AppState.workspace`
- [ ] **Anti-`NSMenu` (T-R18):** `grep -rn "NSPopUpButton\|NSMenu(" Sources/ClaudeBar/Popover/` retorna **zero** ocorrências
- [ ] **Menu bar ancorada:** trocar o foco no switcher **não** altera o medidor da menu bar nem dispara notificação de cota
- [ ] **Codex:** com `~/.codex/auth.json` presente, o switcher lista o provider Codex com session/weekly reais; com o arquivo ausente, o provider simplesmente não aparece (sem erro)
- [ ] **Isolamento:** falha forçada do endpoint do Codex não degrada nem marca stale o painel da Claude
- [ ] **Keychain (R16):** 30 min de uso contínuo, **zero** diálogos Allow/Deny; suíte de testes roda sem tocar o service de produção
- [ ] Release GitHub `v2.4.0` publicada; app instalado em `/Applications/ExímIABar.app`; `pgrep` confirma vivo

---

## 6. Decisões que precisam de veredito do `@po`/dono antes da 5.2

| # | Questão | Recomendação de Aria |
|---|---|---|
| **D-A** | Arquivar o **refresh token** junto com o access token? | **Não.** Nunca será usado (R6/somente-leitura) e é passivo de segurança puro. Guardar `accessToken` + `expiresAt` entrega o comportamento pedido com superfície menor. |
| **D-B** | Teto do roster: 8 contas? | Sim, 8 com evicção LRU. Número redondo, bem acima do uso real, e evita crescimento silencioso. |
| **D-C** | Foco do switcher persiste entre reinícios do app, ou volta sempre para a `.live`? | **Persiste** (fica no índice). Voltar sempre para a `.live` anularia metade do valor do switcher para quem consulta uma conta arquivada com frequência. |
| **D-D** | Codex participa das **notificações** de cota? | **Não nesta onda.** O `QuotaNotifier` está calibrado para a conta viva da Claude; estender agora acopla duas mudanças de risco na mesma onda. Aditivo depois. |

---

*Aria — arquitetando o futuro. Documento de design; a criação dos story files é do `@sm`.*
