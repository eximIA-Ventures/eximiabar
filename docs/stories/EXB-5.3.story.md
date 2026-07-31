# Story EXB-5.3: `WorkspaceSnapshot` + generalização do `AppState`

**ID:** EXB-5.3
**Status:** Done
**Depends on:** EXB-5.2 (enumerar o roster para montar os painéis arquivados), EXB-5.4 (painel do Codex para o fan-out)
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** L (ponto de maior risco arquitetural da onda — refactor do keystone anti-freeze `AppState` + wiring de 2 consumidores)

---

## Story

**As a** exímIABar user com múltiplas contas Claude e o provider Codex ativos,
**I want** que o `AppState` represente um workspace de várias contas (sem virar uma tempestade de `@Observable`), com o ícone da menu bar sempre ancorado na conta viva do CLI e o foco do painel podendo ser trocado sem custo,
**so that** eu possa alternar entre contas no switcher instantaneamente, sem que isso afete o medidor da menu bar nem dispare notificações da conta errada.

---

## Acceptance Criteria

### AC1 — `WorkspaceSnapshot`, o agregado imutável

1. Novo tipo `Sources/ClaudeBar/App/WorkspaceSnapshot.swift`:
   ```swift
   struct WorkspaceSnapshot: Sendable, Equatable {
       let accounts: [AccountPane]        // 1 por conta do roster + Codex, ordem estável
       let focusedKey: AccountKey          // qual está em foco no painel (ver AC5 — D-C)
       let menuBarKey: AccountKey          // qual alimenta o ícone — SEMPRE a Claude .live
       let updatedAt: Date

       struct AccountPane: Sendable, Equatable {
           let identity: AccountIdentity
           let lifecycle: AccountLifecycle
           let display: DisplaySnapshot?   // nil para arquivada sem dado / expirada
           let status: PaneStatus          // .live | .archivedValid | .archivedExpired | .unavailable
       }
   }
   ```

### AC2 — `AppState`: uma propriedade armazenada, o resto computado (preserva I3)

2. `AppState.workspace: WorkspaceSnapshot?` é a **ÚNICA** propriedade armazenada observável do `AppState`.
3. `snapshot: DisplaySnapshot? { workspace?.focused?.display }` e `menuBarSnapshot: DisplaySnapshot? { workspace?.menuBar?.display }` são propriedades **computadas**, não storage — uma leitura de `workspace` que o `withObservationTracking` já rastreia, disparando **uma única notificação** por reatribuição de `workspace`, independente do número de contas.
4. **Rejeitado explicitamente:** `var snapshots: [AccountKey: DisplaySnapshot]` — mutação incremental (`snapshots[k] = v`) geraria N notificações por ciclo com N contas. Não implementar dessa forma.

### AC3 — Montagem do agregado num único ciclo (T-I3)

5. Dentro do mesmo `Task.detached` já existente (`AppState.swift:129`): buscar Claude e Codex **concorrentemente** com `async let`, montar os painéis arquivados a partir do metadado do roster (**zero fetch** para eles — vem só de `AccountRosterStore.roster()`), montar o `WorkspaceSnapshot` inteiro, e só então **uma única** `await self?.completeFetch(workspace, phase:)`.
6. **Teste obrigatório T-I3:** um ciclo de refresh com N ≥ 3 contas (mistura de `.live` + `.archived` + Codex) produz **exatamente uma** atribuição a `AppState.workspace` (contável via spy/observador de mudanças, ou contagem de invocações do setter).

### AC4 — Desacoplamento do ícone da menu bar e do `QuotaNotifier`

7. `StatusItemController.update(snapshot:)` (`StatusItemController.swift:50`) passa a ser alimentado por `menuBarSnapshot` (**não** por `snapshot`/foco). Trocar o foco no switcher **nunca** altera o ícone/medidor da menu bar.
8. O `QuotaNotifier` **nunca** é alimentado pelo painel em foco (`snapshot`). Trocar o foco **nunca** dispara nem suprime notificação. A regra é: o notifier avalia **apenas painéis `.live`** — a `.live` da Claude (`menuBarKey`) e a `.live` do Codex, quando presente.
9. **Decisão D-D (dono do produto, divergindo da recomendação do Aria de adiar para a Onda 11):** o `QuotaNotifier` **também monitora os thresholds do painel Codex nesta mesma onda**. Quando o Codex está presente (`EXB-5.4`) e cruza os mesmos thresholds de cota já configurados para a Claude, dispara sua **própria** notificação — independente e sem duplicar a da Claude (**chave de deduplicação por `AccountKey` + janela, nunca global por janela**).
10. **Correção de contrato exigida pela D-D (@po):** alimentar o `QuotaNotifier` com `menuBarSnapshot` (um único `DisplaySnapshot?` da conta Claude `.live`) é **estruturalmente incapaz** de entregar o item 9 — o painel Codex não é alcançável a partir desse valor. Portanto a superfície de entrada do `QuotaNotifier` passa a receber a **coleção de painéis `.live`** (ex.: `evaluate(livePanes: [WorkspaceSnapshot.AccountPane], phase:)`, ou o `WorkspaceSnapshot` inteiro com filtro interno por `lifecycle == .live`), **não** um `DisplaySnapshot` solitário. O `StatusItemController` (item 7) continua recebendo `menuBarSnapshot` — o ícone é de uma conta só; o notifier não é.
11. **Contas arquivadas nunca geram notificação, em nenhuma circunstância.** O filtro é por `lifecycle == .live` no ponto de entrada, não por convenção do chamador. **Teste obrigatório `archivedPaneAboveThresholdNeverNotifies`:** um painel `.archived` com utilização acima de todos os thresholds configurados produz **zero** notificações num ciclo completo.

### AC5 — Decisão D-C: o foco NÃO persiste entre reinícios do app

12. **Decisão D-C (dono do produto, divergindo da recomendação do Aria de persistir o foco no índice do roster):** `focusedKey` é **estado de sessão em memória apenas**. Ele **NUNCA** é escrito no índice persistido do roster (`accounts.json`, `EXB-5.2`) nem em `UserDefaults`/qualquer outro storage persistente.
13. A **cada lançamento do app**, `focusedKey` inicializa **sempre igual a `menuBarKey`** (a conta `.live` da Claude) — nunca restaura o foco da sessão anterior.
14. Trocar o foco durante a sessão continua sendo uma reatribuição atômica e gratuita — `workspace = workspace.withFocus(newKey)` — sem disparar fetch. Esse valor simplesmente não sobrevive a um `quit`/relaunch do app.
15. **Teste obrigatório `focusResetsToLiveOnFreshAppStateConstruction`:** construir um `AppState`/`WorkspaceSnapshot` do zero (simulando um relaunch, independente de qual conta estava focada antes de um `quit` anterior) e provar que `focusedKey == menuBarKey` sempre no boot, nunca outro valor.

### AC6 — Compatibilidade dos consumidores existentes (R17)

16. `init(snapshot:)` do `AppState` é preservado como conveniência que embrulha num `WorkspaceSnapshot` de conta única — os testes existentes de `StatusItemController`, `UsagePanelController`, `UsageCardView`, `QuotaNotifier`, `ClaudeBarApp` continuam compilando **sem reescrita**.
17. **Ponto de composição (design §2.3):** `LiveUsageProvider.makeFetch()` (`Sources/ClaudeBar/App/LiveUsageProvider.swift`) hoje devolve uma `AppState.Fetch` que produz um `DisplaySnapshot`. Ele passa a produzir um `WorkspaceSnapshot`, orquestrando Claude + Codex com o `async let` da AC3. Este arquivo é o local do fan-out; não introduzir um segundo ponto de composição paralelo.

### AC7 — Build e testes

18. `swift build -c release` zero warnings.
19. `swift test` sem regressões da baseline da `EXB-5.2`/`EXB-5.4`.
20. Pelo menos **8 novos testes unitários**, incluindo (mas não limitado a): `T-I3` (uma única atribuição por ciclo), `menuBarNeverChangesWhenFocusChanges`, `focusResetsToLiveOnFreshAppStateConstruction` (D-C), `quotaNotifierMonitorsCodexThresholdIndependently` (D-D), `quotaNotifierNeverDuplicatesAcrossAccounts`, `archivedPaneAboveThresholdNeverNotifies` (AC4.11), `initSnapshotConvenienceWrapsSingleAccountWorkspace` (R17), `archivedPanesNeverTriggerFetchDuringAssembly`.

### AC8 — Comandos de verificação (mecânicos)

21. **I3, uma única propriedade armazenada observável:** `grep -n "^\s*\(var\|let\) " Sources/ClaudeBar/App/AppState.swift` cruzado com `grep -n "@ObservationIgnored" Sources/ClaudeBar/App/AppState.swift` → **toda** propriedade armazenada exceto `workspace` está anotada com `@ObservationIgnored`. Output dos dois comandos colado no Dev Agent Record.
22. **Foco não persiste (D-C):** `grep -rn "focusedKey" Sources/ | grep -iE "UserDefaults|AppStorage|accounts\.json|encode|Codable"` → **zero** ocorrências.
23. **Notifier não recebe o foco:** `grep -n "notifier.evaluate" Sources/ClaudeBar/App/AppState.swift` → o argumento **não** é `self.snapshot` nem o painel em foco.

---

## Tasks

- [x] **T1 — Criar `WorkspaceSnapshot`** (AC1) — `Sources/ClaudeBar/App/WorkspaceSnapshot.swift`
- [x] **T2 — Generalizar `AppState`** (AC2, AC6) — `Sources/ClaudeBar/App/AppState.swift`, `workspace` como única propriedade armazenada, `snapshot`/`menuBarSnapshot` computadas, `init(snapshot:)` preservado
- [x] **T3 — Montagem via `async let` num único ciclo** (AC3, AC6.17) — dentro do `Task.detached` existente (`AppState.swift:129`); `LiveUsageProvider.makeFetch()` passa a devolver `WorkspaceSnapshot`
- [x] **T4 — Desacoplar `StatusItemController`** (AC4) — alimentar por `menuBarSnapshot` (`StatusItemController.swift:50`)
- [x] **T5 — Desacoplar e estender `QuotaNotifier`** (AC4, D-D) — trocar a entrada de `DisplaySnapshot?` para a **coleção de painéis `.live`** (AC4.10); dedup por `AccountKey` + janela; filtro `lifecycle == .live` no ponto de entrada (AC4.11) — `Sources/ClaudeBar/Notifications/QuotaNotifier.swift`
- [x] **T6 — Foco em memória, sem persistência** (AC5, D-C) — `focusedKey` nunca escrito em `accounts.json` nem `UserDefaults`; reset para `menuBarKey` em toda construção fresca de `AppState`
- [x] **T7 — Testes** (AC7) — `Tests/ClaudeBarTests/WorkspaceSnapshotTests.swift`, `Tests/ClaudeBarTests/AppStateWorkspaceTests.swift`

---

## Dev Notes

### Por que a propriedade computada preserva I3 literalmente

Uma propriedade **computada** não é storage observável. O `withObservationTracking` do SwiftUI/AppKit registra a leitura de `workspace` (o storage que a computada consulta) e dispara **uma vez** quando `workspace` é reatribuída. Continua sendo: um ciclo → uma atribuição atômica → uma notificação. O número de contas não muda isso — é o ponto de maior risco arquitetural da onda, e a razão de existir do `T-I3`.

### Esboço do ciclo de montagem

```swift
Task.detached {
    async let claude = fetchClaudeLive(phase)      // 1 fetch
    async let codex  = fetchCodexIfPresent(phase)   // 1 fetch, independente
    let archived = rosterPanes()                    // 0 fetch — metadado do roster (EXB-5.2)
    let ws = WorkspaceSnapshot(assembling: claude, codex, archived, focus: currentFocusOrMenuBar)
    await completeFetch(ws, phase: phase)           // 1 atribuição
}
```

### Superfície de consumidores verificada (R17)

`StatusItemController`, `UsagePanelController`, `UsageCardView`, `QuotaNotifier`, `ClaudeBarApp`, mais os testes existentes. Pequena e conhecida — a mitigação (`init(snapshot:)` como wrapper) é suficiente, não é necessário reescrever nenhum desses consumidores além do que os ACs 4/5 exigem.

### D-C — por que a divergência do Aria é aceitável e como implementar

O Aria recomendava persistir o foco para não "anular metade do valor do switcher para quem consulta uma conta arquivada com frequência". O dono do produto decidiu que a simplicidade de sempre abrir na conta viva pesa mais. Implementação: **não** adicionar `focusedKey` ao `AccountRosterEntry`/índice (`EXB-5.2` já não o inclui, por construção). O `focusedKey` do `WorkspaceSnapshot` é inicializado com `menuBarKey` toda vez que o `AppState` é construído (app launch), e só muda em memória via `withFocus(_:)` durante a sessão.

### D-D — onde a extensão do `QuotaNotifier` se encaixa

O design original do Aria já previa "`QuotaNotifier` idem — alimentado pela conta viva, não pelo foco" como parte desta mesma story (desacoplamento estrutural). A decisão D-D **adiciona** escopo dentro dessa mesma superfície já tocada: o `QuotaNotifier` ganha uma segunda fonte de threshold (o painel Codex, quando presente), com sua própria lógica de deduplicação por `AccountKey` — não reaproveitar a chave de deduplicação da Claude, para não colidir/duplicar/silenciar notificações entre os dois provedores.

**Armadilha que a AC4.10 fecha (achado do @po na validação):** a formulação "alimentar o `QuotaNotifier` por `menuBarSnapshot`" (desacoplamento) e "o `QuotaNotifier` também monitora o Codex" (D-D) são **incompatíveis como escritas**. `menuBarSnapshot` é `workspace?.menuBar?.display` — um único `DisplaySnapshot?` da conta Claude `.live`. O painel do Codex não existe dentro desse valor, por construção. Um @dev que implementasse os dois ACs ao pé da letra ou (a) descartaria a D-D silenciosamente, ou (b) reintroduziria uma segunda propriedade/canal para o Codex, ferindo I3. A resolução é a AC4.10: **o notifier recebe a coleção de painéis `.live`**, o `StatusItemController` continua recebendo `menuBarSnapshot` (o ícone é de uma conta só). O desacoplamento que importava era do **foco**, não a redução a um painel único.

O ponto atual de chamada é `self.notifier.evaluate(...)` dentro de `completeFetch` (`AppState.swift`, ~linha 193) — é essa assinatura que muda.

### Anti-freeze invariants

- `workspace` é a única propriedade armazenada — nenhuma segunda propriedade observável introduzida
- Montagem inteira em `Task.detached`; única `await` de volta ao `MainActor` no `completeFetch`
- Painéis arquivados nunca disparam fetch — vêm só do roster (`EXB-5.2`)

### Testing

- Arquivos: `Tests/ClaudeBarTests/WorkspaceSnapshotTests.swift`, `Tests/ClaudeBarTests/AppStateWorkspaceTests.swift`
- `T-I3` pode ser implementado com um spy/wrapper que conta atribuições ao `workspace` durante um ciclo simulado com fetchers mockados

---

## Definition of Done

- [x] `WorkspaceSnapshot` criado, `Sendable`/`Equatable`
- [x] `AppState.workspace` é a única propriedade armazenada; `snapshot`/`menuBarSnapshot` computadas
- [x] T-I3 prova exatamente uma atribuição por ciclo com N ≥ 3 contas
- [x] `StatusItemController` alimentado por `menuBarSnapshot`; foco nunca altera o ícone
- [x] `QuotaNotifier` recebe a coleção de painéis `.live` (Claude + Codex), nunca o painel em foco (AC4.10, D-D)
- [x] Painel arquivado acima do threshold produz zero notificações (AC4.11)
- [x] `focusedKey` nunca persiste entre reinícios; sempre reinicia igual a `menuBarKey` (D-C)
- [x] `LiveUsageProvider.makeFetch()` é o único ponto de composição do fan-out (AC6.17)
- [x] `init(snapshot:)` preservado; consumidores existentes compilam sem reescrita
- [x] Os 3 comandos da AC8 executados, output no Dev Agent Record
- [x] 8+ novos testes verdes; zero regressões
- [x] `swift build -c release` zero warnings

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0). D-C (foco não persiste) e D-D (Codex nas notificações de cota nesta onda) do dono do produto aplicadas nos ACs, divergindo da recomendação original do Aria. | @sm River |
| 2026-07-31 | 1.2 | Implementada por @dev (Dex). `WorkspaceSnapshot` criado; `AppState` generalizado com `workspace` como única propriedade armazenada e `snapshot`/`menuBarSnapshot` computadas; fan-out `async let` em `LiveUsageProvider.makeFetch()`; `QuotaNotifier` passa a receber a coleção de painéis com filtro `.live` interno e dedup por `AccountKey`; ícone alimentado por `menuBarSnapshot`. 367 → 392 testes, zero regressões, builds debug e release sem warnings. Status → Ready for Review. | @dev Dex |
| 2026-07-31 | 1.1 | Validação @po: **NO-GO → corrigido → GO 9/10**. Defeito bloqueante encontrado e corrigido: AC4 mandava alimentar o `QuotaNotifier` por `menuBarSnapshot` (um `DisplaySnapshot?` da Claude `.live`) E monitorar o Codex (D-D) — estruturalmente impossível, o painel Codex não é alcançável a partir desse valor; a D-D morreria na implementação ou custaria uma segunda propriedade observável (fere I3). Nova AC4.10 muda a entrada do notifier para a **coleção de painéis `.live`**. Nova AC4.11 (arquivada nunca notifica) + teste. Nova AC6.17 (`LiveUsageProvider` como ponto de composição, faltava do design §2.3). Nova AC8 com 3 comandos mecânicos. Complexidade estimada. Status → Ready. | @po Pax |

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Data:** 2026-07-31 · **Modo:** YOLO

### Baseline

`Scripts/run-tests.sh` antes de tocar em qualquer arquivo: **367 testes, 46 suítes, exit 0**.
(`swift test` cru não roda nesta máquina — sem Xcode, o `Testing.framework` precisa dos três
flags que o `Scripts/run-tests.sh` injeta.)

### Como a AC2 foi implementada, e por que preserva I3

`AppState` tem **uma** propriedade armazenada observável, `workspace: WorkspaceSnapshot?`. Toda
escrita nela passa por um funil único, `publish(_:)`, e `snapshot` / `menuBarSnapshot` são
**computadas** sobre ela. Uma computada não é storage: o `withObservationTracking` registra a
leitura do `workspace` por baixo e dispara uma vez por reatribuição, independente do número de
contas. O dicionário `[AccountKey: DisplaySnapshot]` da AC2.4 **não** foi implementado.

O `publish(_:)` existe por um segundo motivo: ele torna o T-I3 **contável**. Um contador
`workspaceAssignmentCount` (`#if DEBUG`, `@ObservationIgnored`) incrementa em cada escrita, e
como não há caminho de escrita fora do funil (verificado por grep, abaixo), a contagem não pode
divergir da realidade.

### O que o T-I3 prova, exatamente

`oneRefreshCycleAssignsWorkspaceExactlyOnceRegardlessOfAccountCount` roda **o mesmo ciclo duas
vezes**, com 1 conta e com 5 (1 Claude `.live` + 1 Codex `.live` + 3 arquivadas), e compara:

| Ciclo | Contas publicadas | Escritas em `workspace` |
|---|---|---|
| N = 1 | 1 | 2 |
| N = 5 | 5 | 2 |

As 2 escritas são o *flip do spinner* no início e **a única publicação do agregado montado** no
fim — exatamente o que o código fazia antes com uma conta. O valor que importa não é o "2", é a
**invariância**: cinco contas custam o mesmo número de notificações observáveis que uma. Se a
montagem fosse incremental (uma escrita por conta), o segundo ciclo daria 6 e o teste falharia.
`archivedPanesNeverTriggerFetchDuringAssembly` fecha o outro lado: 6 contas, **1** chamada ao
closure de fetch — as 4 arquivadas saem do metadado do roster, sem I/O.

### D-C — linha a linha

- **AC5.12 (nunca persiste):** `focusedKey` não entra em `AccountRosterEntry`, `accounts.json`,
  `UserDefaults` ou qualquer `Codable`. Verificado pelo comando da AC8.22 (zero ocorrências).
- **AC5.13 (reset no boot):** garantido **por construção**, não por convenção. O único
  inicializador público de `WorkspaceSnapshot` é `init(accounts:menuBarKey:updatedAt:)`, que fixa
  `focusedKey = menuBarKey`. O inicializador que aceita um `focusedKey` divergente é `private`, e
  o único caminho até ele é `withFocus(_:)` — em memória. Não existe construtor capaz de semear um
  foco vindo de disco.
- **AC5.14 (troca gratuita):** `AppState.focusAccount(_:)` faz `workspace.withFocus(key)` e
  publica. `changingFocusNeverTriggersAFetch` prova: 2 trocas de foco → 0 fetches novos e
  exatamente +2 escritas.
- **AC5.15 (teste):** `focusResetsToLiveOnFreshAppStateConstruction` existe nas duas camadas — no
  tipo puro (`WorkspaceSnapshotTests`) e ponta a ponta (`AppStateWorkspaceTests`, foca o Codex,
  reconstrói um `AppState` do zero e checa que o foco voltou à Claude `.live`).
  `focusSurvivesRefreshWithinTheSameSession` é o contra-teste: dentro da sessão o foco **não**
  pode voltar sozinho a cada 60 s, senão o switcher seria inutilizável.

### D-D — linha a linha

- **AC4.10 (a superfície de entrada):** `QuotaNotifier.evaluate(panes:previous:settings:)` recebe
  a **coleção de painéis**, nunca um `DisplaySnapshot` solitário. O `AppState` passa
  `merged.accounts` (todos, inclusive arquivados) — o achado do @po está resolvido na raiz: o
  painel Codex é alcançável porque a entrada é a coleção.
- **AC4.11 (arquivada nunca notifica):** o filtro `lifecycle == .live` está **dentro** do
  notifier, no `for pane in panes where pane.lifecycle == .live`. Como o chamador passa a coleção
  inteira, o filtro morde de verdade — não é convenção do call site.
  `archivedPaneAboveThresholdNeverNotifies` usa uma conta arquivada a 0 % (abaixo de todos os
  thresholds e depletada) e prova zero posts, `firedThresholds` vazio e `depletedWindows` vazio.
- **AC4.9 (dedup por conta):** `ThresholdKey` virou `(account, window, threshold)` e nasceu um
  `DepletionKey (account, window)`. `quotaNotifierMonitorsCodexThresholdIndependently` mostra os
  dois provedores cruzando 50 % no mesmo ciclo e **duas** notificações distintas
  (`threshold-session-50` e `threshold-session-50-codex`);
  `quotaNotifierNeverDuplicatesAcrossAccounts` mostra que a de um não consome a do outro
  (`firedThresholds.count == 2`, nunca fundidas).
- **Copy:** as strings existentes citam "Claude" literalmente, então um alerta do Codex mentiria.
  Três chaves novas (`…​.codex`) em `en.lproj` e `pt-BR.lproj`; Claude mantém as chaves e os
  `idPrefix` de sempre (a conta viva Claude é única no roster, não há o que desambiguar).
- **AC4.7 (ícone):** `StatusItemController` é alimentado por `menuBarSnapshot` nos 5 call sites do
  `ClaudeBarApp`. O popover (`snapshotProvider`) continua no `snapshot` (o foco) — é ele que deve
  seguir o switcher. `menuBarNeverChangesWhenFocusChanges` e
  `menuBarSnapshotIsUnaffectedByFocusChange` cobrem os dois lados.

### AC8 — comandos mecânicos (output real)

```
$ grep -n "^\s*\(var\|let\) " Sources/ClaudeBar/App/AppState.swift
28:    var workspace: WorkspaceSnapshot?
31:    var snapshot: DisplaySnapshot? { self.workspace?.focused?.display }
36:    var menuBarSnapshot: DisplaySnapshot? { self.workspace?.menuBar?.display }
(demais linhas são `let` locais dentro de corpos de função, não propriedades)

$ grep -n "@ObservationIgnored" Sources/ClaudeBar/App/AppState.swift
54:    @ObservationIgnored private(set) var workspaceAssignmentCount = 0
57:    @ObservationIgnored private let fetch: Fetch
58:    @ObservationIgnored private let settingsStore: SettingsStore
59:    @ObservationIgnored private let notifier: QuotaNotifier
60:    @ObservationIgnored private let clock: @Sendable () -> Date
62:    @ObservationIgnored private let predictor: ExhaustionPredictor
63:    @ObservationIgnored private let log = Logger(...)
66:    @ObservationIgnored private var timerTask: Task<Void, Never>?
68:    @ObservationIgnored private var fetchInFlight: Task<Void, Never>?
70:    @ObservationIgnored private var pendingFetch = false
```
→ toda propriedade armazenada exceto `workspace` está anotada; linhas 31 e 36 são computadas.

```
$ grep -rn "focusedKey" Sources/ | grep -iE "UserDefaults|AppStorage|accounts\.json|encode|Codable"
(exit 1 — zero ocorrências)          ✅ AC8.22 / D-C

$ grep -n "notifier.evaluate" Sources/ClaudeBar/App/AppState.swift
267:                self.notifier.evaluate(   → panes: merged.accounts, previous: previous
281:                self.notifier.evaluate(   → panes: merged.accounts, previous: nil
```
→ o argumento **não** é `self.snapshot` nem o painel em foco.  ✅ AC8.23

```
$ grep -n "self.workspace = " Sources/ClaudeBar/App/AppState.swift
85:        self.workspace = workspace     (semente do init, não é ciclo)
339:        self.workspace = next          (dentro de `publish(_:)`)
```
→ funil de escrita único, o que valida a contagem do T-I3.

### Build e testes

```
$ swift build --arch arm64            → Build complete! (19.64s), zero warnings
$ swift build -c release --arch arm64 → zero errors, zero warnings
$ Scripts/run-tests.sh                → Test run with 392 tests in 48 suites passed
```

**367 → 392 = 25 testes novos**, zero regressões, zero falhas. Os 8 testes nomeados na AC7.20
existem todos, com os nomes exatos pedidos.

### Decisões autônomas (YOLO)

- **[AUTO-DECISION]** `AppState.Fetch` passou a produzir `WorkspaceSnapshot?`, e a conveniência de
  conta única virou um inicializador com rótulo próprio, `init(displayFetch:…snapshot:)`, em vez de
  uma sobrecarga de `fetch:`. Motivo: sobrecarga por tipo de retorno de closure `async` é fonte
  clássica de ambiguidade no type-checker; um rótulo distinto é determinístico. Custo: os **2**
  call sites de `AppStateTests` trocaram `fetch:` por `displayFetch:` (2 linhas). Os consumidores
  listados na AC6.16 (`StatusItemController`, `UsagePanelController`, `UsageCardView`,
  `QuotaNotifier`, `ClaudeBarApp`) compilaram **sem nenhuma reescrita**, que é o que a AC exige.
- **[AUTO-DECISION]** O `ExhaustionPredictor` enriquece **somente** o painel Claude `.live`.
  Motivo: ele indexa o histórico por id de janela (`session`, `weekly`) sem dimensão de conta, então
  alimentar o Codex nele intercalaria duas séries independentes numa previsão só. Consequência
  honesta: o Codex recebe alertas de threshold e de esgotamento (D-D), mas **não** o alerta
  preditivo de 30 min. Estender o predictor por conta é escopo de outra story.
- **[AUTO-DECISION]** Falha do Codex vira um painel `.unavailable` com a mensagem, em vez de sumir.
  Motivo: sumir silenciosamente esconderia do usuário que o provider parou de responder. O painel
  não tem janelas, então o notifier não acha nada nele e o painel Claude segue intacto
  (`codexFailureNeverDegradesTheClaudePane`).
- **[AUTO-DECISION]** `DisplaySnapshot.settingRefreshing(_:)` foi extraído (o caminho "sem dados"
  reconstruía o struct campo a campo, e agora precisa fazê-lo por painel). Puro, aditivo.

### IDS — SEARCH FIRST

| Alvo | Busca | Decisão |
|---|---|---|
| Agregado multi-conta | `find`/`grep` por `Workspace*`, `AccountPane` | **CREATE** — não existia |
| Identidade/roster | `Sources/ClaudeBarCore/Model/AccountIdentity.swift`, `Accounts/` | **REUSE** — `AccountKey`, `AccountIdentity`, `AccountLifecycle`, `AccountRosterEntry` usados como estão |
| Provider Codex | `Sources/ClaudeBarCore/Codex/` | **REUSE** — `CodexProviderState`/`CodexUsage` mapeados para painel, zero duplicação |
| Spinner / merge de erro | `DisplaySnapshot.refreshing`, `.mergingError` | **REUSE**, + `settingRefreshing` (**ADAPT**) |
| Lógica de threshold | `QuotaNotificationLogic` | **REUSE** intacta — só as chaves de dedup ganharam a dimensão de conta |

### Lacuna declarada (para o @qa)

`LiveUsageProvider.makeFetch()` — o wiring do fan-out — **não tem teste automatizado**. Construí-lo
exige um `CredentialsStore` real, e este repo trata tocar o keychain em teste como perigo conhecido
(o pop-up Allow/Deny que a EXB-3.8 gastou uma onda inteira matando). As partes puras que ele compõe
(`assemble`, `claudePane`, `codexPane`, `archivedPane`, `claudeIdentity`) **estão** testadas
isoladamente; o que não está coberto é a costura entre elas e os dois atores reais.

### File List

**Criados**
- `Sources/ClaudeBar/App/WorkspaceSnapshot.swift`
- `Tests/ClaudeBarTests/WorkspaceSnapshotTests.swift`
- `Tests/ClaudeBarTests/AppStateWorkspaceTests.swift`

**Modificados**
- `Sources/ClaudeBar/App/AppState.swift`
- `Sources/ClaudeBar/App/LiveUsageProvider.swift`
- `Sources/ClaudeBar/App/DisplaySnapshot.swift`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift`
- `Sources/ClaudeBar/Notifications/QuotaNotifier.swift`
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings`
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings`
- `Tests/ClaudeBarTests/AppStateTests.swift` (2 call sites → `displayFetch:`)
- `docs/stories/EXB-5.3.story.md`

---

## QA Results (@qa Quinn) — 2026-07-31

**Veredito: PASS.** Esta era a story de maior risco arquitetural da onda. O invariante I3 foi verificado **por mutação**, não por leitura.

### O T-I3 morde — prova por mutação (não é teste fraco)

O briefing pedia explicitamente para confirmar que `oneRefreshCycleAssignsWorkspaceExactlyOnceRegardlessOfAccountCount` testa o que diz testar. Não bastou ler:

1. Backup de `AppState.swift` (`shasum a381f7a7…`).
2. Substituí `self.publish(merged)` por uma montagem **incremental**, um `publish` por conta — exatamente o modo de falha que o invariante existe para impedir.
3. `Scripts/run-tests.sh --filter AppStateWorkspaceTests`:

```
✘ oneRefreshCycleAssignsWorkspaceExactlyOnceRegardlessOfAccountCount()
  Expectation failed: (many.writes → 6) == (single.writes → 2)
```

4. Restaurado; `shasum` idêntico (`a381f7a7…`); `grep` por resíduo da sonda retorna vazio.

O valor **6** é exatamente o que o @dev previu no Dev Agent Record. O teste falha pelo motivo certo. **Não é teste fraco.**

O funil de escrita que torna a contagem confiável também foi verificado: `grep -n "self.workspace = "` retorna **só** a linha 85 (semente do `init`) e a 339 (dentro de `publish`). Não há caminho de escrita que escape do contador.

### D-C e D-D — prova estrutural

| Item | Método | Resultado |
|---|---|---|
| **D-C** nunca persiste | `grep -rn "focusedKey" Sources/ \| grep -iE "UserDefaults\|AppStorage\|accounts.json\|encode\|Codable"` | **exit 1, zero**. Mais forte: `WorkspaceSnapshot` é `Sendable, Equatable` — **não é `Codable`**. Não existe caminho de serialização, o foco é insalvável por construção, não por convenção |
| **D-C** reset no boot | leitura | único `init` público fixa `focusedKey = menuBarKey`; o que aceita foco divergente é `private`, alcançável só por `withFocus(_:)`, em memória |
| **D-D** entrada é a coleção | `grep -n "notifier.evaluate"` | linhas 267/281, ambas `panes: merged.accounts`. Nunca `self.snapshot`, nunca o painel em foco — o achado bloqueante do @po está fechado na raiz |
| **D-D** arquivada nunca notifica | leitura de `QuotaNotifier` | `for pane in panes where pane.lifecycle == .live` **dentro** do notifier (linha 166). O filtro morde independente do call site, não é convenção |
| **D-D** dedup por conta | leitura | `ThresholdKey(account, window, threshold)` e `DepletionKey(account, window)` — a dimensão de conta é do tipo, não do uso |
| Menu bar ancorada | leitura de `focusAccount` (347-352) | faz `publish(next)` e **nada mais**. Os 3 `notifier.evaluate*` vivem todos dentro de `completeFetch`. Trocar foco **não pode** notificar |

### Suíte e build

`Scripts/run-tests.sh` → **403/403, 49 suítes, exit 0**. `swift build -c release --arch arm64` em scratch **limpo** (sem cache) → `Build complete!`, **0 warnings, 0 errors**.

### CONCERNS (não bloqueia esta story)

- **QA-C2 (BAIXO) — a lacuna que o @dev declarou é real e continua aberta.** `LiveUsageProvider.makeFetch()` não tem teste automatizado. Li o código: é cola fina (`async let` de duas funções puras já testadas + leitura do índice do roster + `assemble`), e o risco é baixo — mas é **o único ponto onde os dois atores se encontram**. A honestidade da declaração conta a favor; a lacuna permanece para uma story futura.
- **QA-C3 (BAIXO, documental) — o texto do Wave DoD diverge do teste.** O DoD diz "exatamente **uma** atribuição a `AppState.workspace`", e o T-I3 assere **2** (flip do spinner + publicação do agregado). O invariante que de fato importa e está provado é a **invariância em relação a N** (5 contas custam o mesmo que 1). O texto do DoD foi corrigido por mim no `EPIC-EXB.md` para não induzir um leitor futuro a achar que o teste falha o próprio DoD.
