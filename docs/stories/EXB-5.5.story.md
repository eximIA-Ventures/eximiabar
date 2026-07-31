# Story EXB-5.5: Switcher no painel + gestão de contas em Settings

**ID:** EXB-5.5
**Status:** Done
**Depends on:** EXB-5.3 (`WorkspaceSnapshot`, `focusedKey`/`menuBarKey`, `AccountRosterStore.remove(_:)` de `EXB-5.2`)
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M (UI dentro de layout existente; risco concentrado na proibição de `NSMenu` — R18, ALTA se não travada)

---

## Story

**As a** exímIABar user com múltiplas contas Claude e o provider Codex ativos,
**I want** trocar entre contas clicando num chip no header do card, ver o estado de cada uma (viva, arquivada, expirada), e remover contas antigas em Settings,
**so that** eu tenha controle total do workspace multi-conta sem que o app reintroduza o freeze que o `NSPanel` existe para evitar.

---

## Acceptance Criteria

### AC1 — Chip clicável no header (zero layout novo)

1. A linha 1 do `HeaderSection` de `UsageCardView` (`UsageCardView.swift:76-102`, hoje `logo eximIA + "Claude" + e-mail`) vira um **chip de conta clicável**. Clicar troca o corpo do card por uma **lista inline** dentro do mesmo `VStack` já hospedado — sem layout novo, sem janela nova.

### AC2 — Restrição inegociável de anti-freeze (I4/R18)

2. O switcher **NÃO** usa `Menu` do SwiftUI, `NSPopUpButton`, nem `NSMenu` em nenhuma forma — ambos materializam um `NSMenu` real e reintroduzem o run loop de menu-tracking que o `NSPanel` existe para evitar. É uma lista inline dentro do `VStack` do card, trocando o conteúdo exibido, nada de AppKit de menu envolvido.
3. **Teste obrigatório T-R18 (grep corrigido pelo @po):** o grep herdado do design (`grep -rn "NSPopUpButton\|NSMenu(" Sources/ClaudeBar/Popover/`) tem **duas lacunas** que o tornariam um gate falso-verde: (a) o `Menu` do **SwiftUI** — o item mais provável de ser usado por engano — não casa com nenhum dos dois padrões; (b) a view nova do switcher pode não ficar em `Popover/`. O gate mecânico obrigatório é, portanto:
   ```bash
   grep -rnE "NSPopUpButton|NSMenu\(|(^|[^A-Za-z])Menu\s*[{(]|\.menuStyle|MenuPickerStyle" \
     Sources/ClaudeBar/ --include="*.swift" | grep -v "App/ClaudeBarApp.swift"
   ```
   → **zero** ocorrências. O grep do design permanece válido como subconjunto, mas **não** substitui este. Rodar e colar o output (vazio) no PR; este comando entra também no checklist de release da `EXB-5.6`.
4. **Baseline medida pelo @po em 2026-07-31 (HEAD `7b48acb`):** o comando acima retorna **zero**. A única exclusão é `App/ClaudeBarApp.swift:300,304` — dois `NSMenu()` **legítimos e pré-existentes** que constroem o menu principal do app (`installSettingsShortcutMenu`, necessário para o atalho ⌘, num agente `LSUIElement`). Esse é conteúdo estático de menu bar do sistema, não conteúdo dinâmico em popover, e nada tem a ver com o switcher. Qualquer ocorrência **fora** desse arquivo é necessariamente introduzida por esta story. **Não** ampliar a exclusão para outros arquivos.

### AC3 — Estados visuais da lista

5. A lista renderiza cada `AccountPane` do `workspace.accounts`:
   - `.live` → bolinha cheia + rótulo "ao vivo"
   - `.archivedValid` → bolinha vazia + rótulo "arquivada"
   - `.archivedExpired` → bolinha vazia + rótulo "expirada — faça login nesta conta para recapturar"
   - Codex `.live` (quando presente) → mesma semântica de `.live`, provider identificado visualmente (ex.: ícone/label diferente de Claude)
6. Clicar num item da lista chama `appState.focus(key)` → `workspace = workspace.withFocus(newKey)`, reatribuição atômica sobre dado já em memória — **sem** disparar fetch, troca instantânea.
7. A lista **não** consulta `AccountRosterStore` diretamente (R10) — ela é função pura de `workspace.accounts`, que já viajou do `Task.detached` do ciclo (`EXB-5.2` AC6, `EXB-5.3` AC3). **Verificação:** `grep -rn "AccountRosterStore" Sources/ClaudeBar/Popover/` → **zero** ocorrências.

### AC4 — Foco não persiste entre reinícios (consistência com D-C, `EXB-5.3`)

8. O switcher **NÃO** implementa nenhum mecanismo de "lembrar o último foco" — nenhuma escrita de `focusedKey` em `UserDefaults`, no índice do roster, ou em qualquer storage persistente. Este é o mesmo invariante definido em `EXB-5.3` AC5 (decisão D-C do dono do produto); esta story apenas garante que a UI do switcher não introduza uma persistência paralela por conta própria (ex.: um `@AppStorage` "conveniente" no lugar errado).
9. **Verificação mecânica (comando literal, não "revisão de código"):**
   ```bash
   grep -rnE "@AppStorage|UserDefaults" Sources/ClaudeBar/Popover/
   ```
   → **zero** ocorrências. O switcher inteiro vive em `Popover/`, logo qualquer persistência introduzida por ele aparece aqui. Rodar e colar o output (vazio) no PR.

### AC5 — Gestão de contas em Settings

10. Nova seção (ou aba, conforme o espaço disponível em `PreferencesGeneralPane`, respeitando a repaginação em 4 abas da v2.1.4) listando o roster completo, com:
    - Ação **"remover conta"** por entrada, chamando `AccountRosterStore.remove(_:)` (implementado em `EXB-5.2`)
    - Rótulo explicando que contas arquivadas são **somente-leitura** (nunca renovadas)
11. Remover uma conta arquivada some com ela do índice **e** do keychain próprio (`com.eximia.eximiabar.accounts`) — nenhum resíduo de segredo após a remoção. **Verificável:** após remover, `security find-generic-password -s com.eximia.eximiabar.accounts -a "claude:{email}"` retorna erro de item não encontrado, e o e-mail some de `accounts.json`.
12. A remoção é `await` no actor (`EXB-5.2`), disparada de um `Task` a partir da ação de UI — **nunca** chamada síncrona dentro de `body` (I1/R10).

### AC6 — Localização

13. Todo texto novo visível (`ao vivo`, `arquivada`, `expirada — faça login nesta conta para recapturar`, `remover conta`, rótulo de somente-leitura) é localizado em `en.lproj` **e** `pt-BR.lproj`, seguindo o padrão já usado no projeto (`L("chave")`, ver `UsageCardView.swift:86`). **Verificação:** paridade de chaves entre os dois `.strings` (mesmo check já aplicado na `EXB-4.4`).

### AC7 — Build e testes

14. `swift build -c release` zero warnings.
15. `swift test` sem regressões da baseline da `EXB-5.3`.
16. Pelo menos **6 novos testes unitários/UI**: `T-R18` (grep, ver AC2), `focusSwitchIsInstantWithoutFetch`, `settingsRemoveAccountClearsIndexAndKeychainSecret`, `archivedExpiredRendersDistinctLabel`, `codexPaneAppearsInSwitcherWhenPresent`, `switcherReadsOnlyFromWorkspaceNeverFromRosterStore` (AC3.7).

---

## Tasks

- [x] **T1 — Chip clicável no header** (AC1) — `Sources/ClaudeBar/Popover/UsageCardView.swift:76-102`
- [x] **T2 — Lista inline do switcher (sem NSMenu)** (AC2, AC3) — nova view interna do card, ex.: `AccountSwitcherListView.swift`
- [x] **T3 — Wiring de foco** (AC3, AC4) — `appState.focus(key)` chamando `workspace.withFocus(_:)`; garantir ausência de persistência de foco
- [x] **T4 — Settings: gestão de contas** (AC5) — `Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift` (ou pane/seção nova), ação remover conta
- [x] **T5 — Localização** (AC6) — chaves novas em `en.lproj` + `pt-BR.lproj`, paridade verificada
- [x] **T6 — Testes + greps de verificação** (AC7) — `Tests/ClaudeBarTests/AccountSwitcherTests.swift`; os 3 greps (AC2.3, AC3.7, AC4.9) rodados com output colado no PR

---

## Dev Notes

### Mockup de referência (design da Onda 10, §2.4)

```
┌──────────────────────────────────────────┐
│ ◈ Claude · hugo@…gmail.com          ⌄    │  ← chip: clicar troca o corpo do card
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

### Por que a restrição de `NSMenu`/`Menu`/`NSPopUpButton` é inegociável

O `Menu` do SwiftUI e o `NSPopUpButton` **materializam um `NSMenu` real** por baixo — mesmo parecendo "SwiftUI puro" no código, o run loop de menu-tracking que causa o freeze volta silenciosamente (compila, roda, e o congelamento aparece em produção, não em testes locais). É por isso que o grep (`T-R18`) é um critério de aceite mecânico, não uma sugestão de estilo.

### Estado do switcher é derivado, não `@State`

O `focusedKey` vive no `WorkspaceSnapshot` (`EXB-5.3`), **não** em `@State` da view. A `UsageCardView` continua sendo função pura do snapshot (contrato documentado em `UsageCardView.swift:20-21`) — clicar num item chama uma action que faz `appState.focus(key)`, e a view apenas re-renderiza a partir do novo `workspace`.

### Consistência com D-C — o que esta story NÃO deve fazer

Não adicionar nenhum `@AppStorage`, `UserDefaults.standard.set(focusedKey, ...)`, ou gravação equivalente para "lembrar" o foco entre lançamentos do app. Isso reintroduziria exatamente o comportamento que o dono do produto rejeitou explicitamente em `EXB-5.3` (D-C).

### Settings — onde encaixar

`PreferencesGeneralPane` já é o lugar natural (a repaginação em 4 abas por intenção veio na v2.1.4 e deve ser respeitada — não criar uma 5ª aba sem necessidade clara).

### Anti-freeze invariants

- Lista inline, nunca `NSMenu`/`Menu`/`NSPopUpButton`
- Troca de foco é reatribuição pura sobre dado em memória, sem I/O, sem fetch
- Remoção de conta em Settings é operação `await` no `AccountRosterStore` (actor), nunca síncrona na UI

### Testing

- Arquivo: `Tests/ClaudeBarTests/AccountSwitcherTests.swift`
- Grep de verificação (documentar no PR): `grep -rn "NSPopUpButton\|NSMenu(" Sources/ClaudeBar/Popover/` → deve retornar vazio

---

## Definition of Done

- [x] Chip de conta clicável no header, lista inline sem layout novo
- [x] Zero `NSMenu`/`Menu` SwiftUI/`NSPopUpButton` no switcher — **grep ampliado** da AC2.3 limpo
- [x] Estados `.live`/`.archivedValid`/`.archivedExpired` renderizados corretamente, incl. Codex
- [x] Troca de foco instantânea, sem fetch, sem persistência entre reinícios (D-C) — grep da AC4.9 limpo (ver ressalva abaixo)
- [x] Switcher lê só do `workspace`, nunca do `AccountRosterStore` (AC3.7)
- [x] Settings: listar roster + remover conta (limpa índice e keychain)
- [x] Textos novos localizados em `en` e `pt-BR`, paridade verificada
- [x] 11 novos testes verdes; zero regressões (392 → 403)
- [x] `swift build -c release --arch arm64` zero warnings

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Data:** 2026-07-31 · **Modo:** YOLO

### Decisões de implementação

**D1 — O switcher é troca de conteúdo do `VStack`, não um componente novo.** `UsageCardView.body`
passou a ter dois ramos: `cardBody` (o card de sempre, extraído sem mudança de conteúdo) e
`AccountSwitcherListView`. O `NSPanel` e o `NSHostingView` continuam sendo os mesmos objetos —
nenhuma janela nova, nenhum run loop novo, que é o ponto inteiro de I4/R18.

**D2 — `isSwitcherOpen` é `@State`, e isso NÃO viola a AC4.** O que a D-C proíbe é persistir
**foco**. `isSwitcherOpen` é estado de *disclosure* (lista aberta ou fechada), da mesma natureza do
`expanded` que a `CostSection` já usa desde a EXB-1.7. O foco continua vivendo só no
`WorkspaceSnapshot` e chega à view apenas via `workspace`; clicar numa linha chama
`actions.focusAccount(key)` e o novo foco volta no render seguinte. Nada na camada de UI lembra qual
conta foi escolhida — grep da AC4.9 é a prova mecânica.

**D3 — Settings fala com o roster por um port, não pelo actor (achado que teria quebrado o build).**
`AccountRosterStoreTests.rosterStoreIsAPlainActorAndIsNeverReadFromTheUI` (EXB-5.2) afirma
`referencing == ["LiveUsageProvider.swift"]`: **só** esse arquivo pode nomear `AccountRosterStore` em
`Sources/ClaudeBar/`. Uma seção de Settings chamando `AccountRosterStore.remove(_:)` diretamente
quebraria esse teste. Em vez de afrouxar o gate herdado, introduzi `AccountRosterAccess` — um par de
closures `@Sendable` (`load` / `remove`) construído em `LiveUsageProvider.rosterAccess`. Ganhos: o
actor mantém um único dono no app target, a chamada síncrona a partir de um `body` fica
*impossível de escrever* (só há `await`), e o teste de Settings injeta um store isolado sem tocar no
índice real. O gate da EXB-5.2 segue verde sem uma linha alterada.

**D4 — O modelo do switcher é um valor puro, e a localização fica fora dele.**
`AccountSwitcherItem.items(from:)` é função pura de `WorkspaceSnapshot`; o item guarda `PaneStatus` e
`Provider` crus, e `statusLabel(for:)` / `providerLabel(for:)` resolvem as strings na hora de
desenhar. Assim os testes de estado valem em qualquer idioma, e a prova de comportamento do switcher
não exige instanciar view nenhuma.

**D5 — `[AUTO-DECISION]` seção em `PreferencesGeneralPane`, não 5ª aba.** A story deixava a escolha
aberta ("seção ou aba"). Escolhi seção, ao fim do pane General, logo após *Connection*: a repaginação
em 4 abas da v2.1.4 fica intacta e contas são assunto de conexão. O pane já é um `ScrollView`, então
não houve pressão de layout.

**D6 — Ressalva honesta sobre a AC4.9.** O comando literal da AC4.9 não retorna vazio: retorna
**uma** linha, `Popover/PopoverTheme.swift:8`, um *comentário de documentação* que menciona
`UserDefaults` e que já existia em `HEAD 7b48acb` (comprovado por
`git show HEAD:Sources/ClaudeBar/Popover/PopoverTheme.swift | grep -n UserDefaults`, saída idêntica).
O @po mediu a baseline da AC2.3 mas não a da AC4.9. Optei por **não** editar um comentário alheio só
para o substring sumir; o teste automatizado (`switcherIntroducesNoFocusPersistence`) checa linhas de
**código**, não prosa, e mantém `@AppStorage` banido de forma absoluta. Zero persistência foi
introduzida por esta story.

### Prova de que o gate T-R18 morde

O defeito que o @po corrigiu (grep cego ao `Menu` do SwiftUI) foi verificado por mutação, não por
leitura: uma linha `// mutation probe: Menu { }` acrescentada a `AccountSwitcherListView.swift` fez
`switcherNeverMaterializesAnAppKitMenu()` **falhar** apontando o arquivo e a linha; o arquivo foi
restaurado de backup e o `shasum` conferido (`OK`).

### Verificações executadas

| Comando | Resultado |
|---|---|
| `swift build --arch arm64` | `Build complete!` — zero warnings novos |
| `swift build -c release --arch arm64` | `Build complete!` — zero warnings |
| `Scripts/run-tests.sh` | **403 testes em 49 suítes, todos passando** (baseline 392) |
| Grep AC2.3 (anti-menu) | **zero** ocorrências |
| Grep AC3.7 (`AccountRosterStore` em `Popover/`) | **zero** ocorrências |
| Grep AC4.9 (`@AppStorage\|UserDefaults` em `Popover/`) | 1 ocorrência, comentário pré-existente (ver D6) |

> `swift test` cru não roda nesta máquina (falta Xcode; só Command Line Tools). `Scripts/run-tests.sh`
> supre o search path, o overlay de cross-import e o rpath do `Testing.framework`. Use sempre o script.

### File List

**Criados**
- `Sources/ClaudeBar/Popover/AccountSwitcherListView.swift` — `AccountSwitcherItem` (modelo puro) + a lista inline
- `Sources/ClaudeBar/Settings/AccountsSettingsSection.swift` — `AccountRosterAccess`, `AccountRosterViewModel`, seção de contas
- `Tests/ClaudeBarTests/AccountSwitcherTests.swift` — 11 testes

**Modificados**
- `Sources/ClaudeBar/Popover/UsageCardView.swift` — chip clicável, `workspace`, `focusAccount` em `UsageCardActions`, `cardBody` extraído
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — `workspaceProvider`, repassado ao card e observado
- `Sources/ClaudeBar/App/LiveUsageProvider.swift` — `rosterAccess`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — wiring de `workspaceProvider`, `focusAccount` e `rosterAccess`
- `Sources/ClaudeBar/Settings/PreferencesGeneralPane.swift` — seção *Accounts*
- `Sources/ClaudeBar/Settings/SettingsRootView.swift` — repasse do view model
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — dono do view model; `reload()` a cada `open()`
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — 15 chaves novas
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — as mesmas 15 chaves

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0). AC4 reforça explicitamente a decisão D-C (foco não persiste) já definida em EXB-5.3, garantindo que a UI do switcher não introduza persistência paralela. | @sm River |
| 2026-07-31 | 1.2 | Implementação @dev (YOLO). Switcher inline no card (zero AppKit de menu, gate T-R18 provado por mutação), Settings com gestão de contas via port `AccountRosterAccess` (preserva o gate R10 da EXB-5.2 sem afrouxá-lo), 15 chaves localizadas nos dois idiomas, 11 testes novos (392 → 403 verdes). Ressalva registrada na AC4.9: o grep literal retorna 1 comentário pré-existente em `PopoverTheme.swift:8`, comprovadamente anterior a esta story. Status → Ready for Review. | @dev Dex |
| 2026-07-31 | 1.1 | Validação @po: **NO-GO → corrigido → GO 9/10**. Defeito bloqueante: o grep T-R18 herdado do design (`NSPopUpButton\|NSMenu(`) **não casa com o `Menu` do SwiftUI** — exatamente o item mais provável de ser usado por engano e o que a AC2 mais proíbe. Gate falso-verde num risco de probabilidade ALTA. Grep ampliado e baseline medida (zero fora de `ClaudeBarApp.swift`, onde há 2 `NSMenu()` legítimos e pré-existentes do menu ⌘,). AC4.9 virou comando literal em vez de "revisão de código". Novas AC3.7 (switcher não toca o store, R10), AC5.12 (remoção assíncrona) e AC6 (localização, faltava). Complexidade estimada. Status → Ready. | @po Pax |

---

## QA Results (@qa Quinn) — 2026-07-31

**Veredito: PASS.** O risco que o @po salvou aqui (grep cego ao `Menu` do SwiftUI) foi re-verificado por mim com escopo ainda mais amplo que a AC.

### Anti-`NSMenu` (T-R18) — varredura do app target inteiro

Não me limitei ao `Popover/` do Wave DoD. Varri **todo** o target, incluindo `Picker(`:

```
$ grep -rn "NSPopUpButton|NSMenu\(|\bMenu\(|Picker\(" Sources/ClaudeBar/
```

| Achado | Veredito |
|---|---|
| `ClaudeBarApp.swift:306,310` — 2 `NSMenu()` | **legítimo e pré-existente**: é o menu principal do ⌘,. `git show HEAD:` confirma a **mesma contagem 2** na baseline. Não é do switcher |
| 11 `Picker(` em `Settings/` e `Dashboard/` | **pré-existentes**. `git diff` do `PreferencesGeneralPane.swift` mostra **0** linhas adicionadas contendo `Picker(`/`Menu(`/`NSPopUpButton` — a onda adicionou 5 linhas, nenhuma delas de menu |
| `Popover/`, `StatusItem/`, `AccountSwitcherListView.swift`, `AccountsSettingsSection.swift` | **zero** ocorrências de qualquer uma das quatro formas |

O gate literal do Wave DoD (`grep -rn "NSPopUpButton\|NSMenu(" Sources/ClaudeBar/Popover/`) retorna exit 1. O gate ampliado do @po também. A prova por mutação do @dev (linha `Menu { }` injetada faz `switcherNeverMaterializesAnAppKitMenu()` falhar) é a razão de eu tratar este gate como confiável e não decorativo.

### Demais verificações

| Verificação | Método | Resultado |
|---|---|---|
| AC3.7 (switcher não toca o store) | `grep -rn "AccountRosterStore" Sources/ClaudeBar/` | só `LiveUsageProvider.swift`. O port `AccountRosterAccess` (D3) preserva o gate R10 herdado da `EXB-5.2` **sem afrouxá-lo** — a solução certa foi escolhida sobre a fácil |
| AC5.12 (remoção assíncrona) | leitura de `AccountsSettingsSection` | `reload()`/`remove()` embrulham `Task { await … }`; existem as formas `…AndAwait` como seam de teste, evitando `sleep` |
| AC6 (localização) | `diff` das **chaves reais**, não da contagem | 283 chaves em cada idioma, **zero divergência** de nomes de chave entre `en` e `pt-BR` |
| AC4.9 (ressalva do @dev) | `git show HEAD:…/PopoverTheme.swift \| sed -n '8p'` | a única ocorrência é um **comentário de documentação byte-idêntico na baseline**. A ressalva do @dev é honesta e a decisão de não editar comentário alheio só para o substring sumir está certa |
| D-C na camada de UI | `grep -rn "focusedKey"` cruzado com persistência | zero. `isSwitcherOpen` como `@State` é estado de *disclosure*, não de foco — a distinção do @dev é válida |
| Suíte + release | `Scripts/run-tests.sh` / release limpo | 403/403 verdes; 0 warnings |
