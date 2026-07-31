# Story EXB-5.1: Resolução de identidade da conta Claude (`~/.claude.json`)

**ID:** EXB-5.1
**Status:** Done
**Depends on:** — (fundação da Onda 10, nenhuma dependência formal)
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M (3 arquivos novos + 2 wirings; risco concentrado no decoder tolerante de 45 KB)

---

## Story

**As a** exímIABar user com mais de uma conta Claude,
**I want** que o app resolva a identidade (e-mail, nome, organização) da conta Claude atualmente logada a partir de `~/.claude.json`,
**so that** o roster de contas e o switcher da Onda 10 tenham uma chave de identidade real para comparar contas, e o header do popover finalmente exiba o e-mail que promete mostrar desde a EXB-1.3.

---

## Acceptance Criteria

### AC1 — Tipos novos de identidade

1. Novos tipos em `Sources/ClaudeBarCore/Model/` (arquivo novo, ex.: `AccountIdentity.swift`):
   - `enum Provider: String, Codable, Sendable { case claude, codex }`
   - `struct AccountKey: Hashable, Codable, Sendable { let provider: Provider; let identifier: String }` — `identifier` é o e-mail **normalizado** (lowercase + trim de espaços)
   - `struct AccountIdentity: Sendable, Equatable { let key: AccountKey; let email: String; let displayName: String?; let organizationName: String?; let accountUUID: String? }`
2. `AccountKey` e `AccountIdentity` são reusados por `EXB-5.2` (roster) e `EXB-5.4` (Codex) — não duplicar o tipo.

### AC2 — Leitor de identidade gated por fingerprint

3. Novo componente (actor) que lê `~/.claude.json`, localiza o objeto `oauthAccount` (campos observados na máquina: `emailAddress`, `accountUuid`, `displayName`, `organizationName`), e devolve um `AccountIdentity?`.
4. O leitor é **gated por fingerprint de mtime** do arquivo — mesmo padrão de `CredentialsStore.pollFingerprintsAndInvalidateIfChanged` (`CredentialsStore.swift:429`). Se o mtime não mudou desde a última leitura, **não** reparseia o arquivo de 45 KB.
5. Decoder **tolerante**: extrai apenas o campo `oauthAccount`, ignora todo o resto do arquivo (`DynamicCodingKey` ou equivalente já usado no projeto); não falha se `~/.claude.json` tiver campos desconhecidos ou adicionais.
6. Todo I/O (leitura de arquivo, decode JSON) roda **fora do MainActor** — o leitor é um `actor`, nenhuma chamada síncrona de arquivo em `body`/`viewDidLoad` (I1).

### AC3 — Fallback sem e-mail (R12)

7. Se `oauthAccount` estiver ausente ou malformado, o leitor **não falha** — devolve uma `AccountIdentity` com chave opaca `sha256(accessToken)[0..8]` e `displayName` rotulado como `"Conta N"` (N = ordinal de descoberta). O roster continua funcional sem e-mail.

### AC4 — Popular `UsageSnapshot.identity` (fecha D1)

8. `UsageFetcher.fetchSnapshot` (`UsageFetcher.swift:43`) passa a popular o parâmetro `identity:` (hoje sempre omitido/`nil` — descoberta D1 do design da Onda 10). **Precisão verificada no código:** `fetchSnapshot` não constrói o `UsageSnapshot` diretamente, ele delega a `UsageSnapshot.from(_:rateLimitTier:subscriptionType:source:now:)` (`UsageSnapshot.swift`), que **hoje não aceita identidade**. Logo o wiring exige adicionar um parâmetro `identity:` a `UsageSnapshot.from` e repassá-lo em `fetchSnapshot`.
9. **O tipo `UsageSnapshot.Identity` (`name: String`, `email: String`) NÃO é alterado nem substituído por `AccountIdentity`.** `AccountIdentity` (AC1) é o tipo do roster; o wiring é um **mapeamento** `AccountIdentity → UsageSnapshot.Identity`. Trocar o tipo quebraria `DisplaySnapshot.swift:134` e `UsageCardView.swift:92`, que já consomem a forma atual.
10. A cadeia de propagação `UsageSnapshot.identity → DisplaySnapshot.identity → header` **já existe** (`DisplaySnapshot.swift:134`) e não precisa ser construída — apenas alimentada na origem.
11. O header do popover (`UsageCardView.swift:92`) passa a exibir o e-mail **real** resolvido, não mais vazio.

### AC5 — Build e testes

12. `swift build -c release` zero warnings.
13. `swift test` sem regressões da baseline pré-onda. **A contagem exata da baseline é registrada no Dev Agent Record desta story** (comando: `swift test --arch arm64 --no-parallel 2>&1 | tail -5`), porque `EXB-5.2`, `EXB-5.3` e `EXB-5.4` a referenciam como ponto de comparação.
14. Pelo menos **5 novos testes unitários**: `emailIsNormalizedLowercaseAndTrimmed`, `fallbackOpaqueKeyWhenOauthAccountMissing`, `fingerprintGatePreventsReparseWhenMtimeUnchanged`, `tolerantDecoderIgnoresUnknownTopLevelFields`, `identityPopulatesUsageSnapshotNotNil`.

### AC6 — Comandos de verificação (mecânicos)

15. `grep -n "identity:" Sources/ClaudeBarCore/OAuth/UsageFetcher.swift` → retorna ≥ 1 ocorrência (hoje retorna **zero** — é a prova literal de D1 fechada).
16. `grep -n "public struct Identity" Sources/ClaudeBarCore/Model/UsageSnapshot.swift` → continua retornando 1 ocorrência (o tipo existente **não** foi removido — AC4.9).
17. Verificação a olho: com Claude Code logado, abrir o popover e confirmar que o e-mail exibido no header é o mesmo de `python3 -c "import json;print(json.load(open('$HOME/.claude.json'))['oauthAccount']['emailAddress'])"`.

---

## Tasks

- [x] **T1 — Criar tipos `Provider`/`AccountKey`/`AccountIdentity`** (AC1) — `Sources/ClaudeBarCore/Model/AccountIdentity.swift`
- [x] **T2 — Criar o leitor de identidade** (AC2, AC3) — `Sources/ClaudeBarCore/OAuth/ClaudeIdentityResolver.swift` (ou nome equivalente), `actor`, gated por fingerprint de mtime, decoder tolerante, fallback de chave opaca
- [x] **T3 — Wire no `UsageFetcher`** (AC4) — adicionar parâmetro `identity:` a `UsageSnapshot.from` (`Sources/ClaudeBarCore/Model/UsageSnapshot.swift`) e repassá-lo de `UsageFetcher.fetchSnapshot` (`Sources/ClaudeBarCore/OAuth/UsageFetcher.swift:43`); mapear `AccountIdentity → UsageSnapshot.Identity` sem trocar o tipo existente
- [x] **T4 — Confirmar o header** (AC4) — `Sources/ClaudeBar/Popover/UsageCardView.swift:92` já lê `snapshot?.identity.email`; a cadeia `DisplaySnapshot.swift:134` já propaga. Verificar que passa a exibir valor real, alterar só se necessário
- [x] **T5 — Testes** (AC5) — novo arquivo `Tests/ClaudeBarCoreTests/ClaudeIdentityResolverTests.swift`

---

## Dev Notes

### Descobertas que motivam esta story (design da Onda 10, §0)

- **D1:** `UsageSnapshot.identity` existe no modelo mas é **sempre `nil`** — `UsageFetcher.fetchSnapshot` nunca passa `identity:`. O e-mail do header (`UsageCardView.swift:92`) nunca foi preenchido desde que foi escrito.
- **D2:** a identidade vive em `~/.claude.json` → `oauthAccount` (verificado na máquina real): `emailAddress`, `accountUuid`, `displayName`, `organizationName`. Arquivo modo `600`, texto puro, **sem keychain, sem prompt**. É um arquivo de 45 KB de forma indocumentada — decodificação tolerante é obrigatória, não opcional.

### Padrão de fingerprint a reusar

`CredentialsStore.swift:429` (`pollFingerprintsAndInvalidateIfChanged`) já implementa o padrão de "só reparseia se o mtime mudou" para `.credentials.json`. Esta story replica o mesmo padrão para `~/.claude.json`, sem introduzir um segundo timer — é um leitor independente, consultado sob demanda pelo `UsageFetcher`.

### Por que esta story é a fundação de toda a Onda 10

`AccountKey`/`AccountIdentity` são o tipo compartilhado que `EXB-5.2` (roster) usa para indexar contas e que `EXB-5.4` (provider Codex) usa para sua própria `AccountKey` com `provider: .codex`. Nada na onda progride sem esta story primeiro.

### Anti-freeze invariants

- Leitor é `actor` — nenhum acesso síncrono de fora de `await`
- Nenhuma leitura de arquivo em `@MainActor`
- Decode tolerante, nunca `fatalError` ou crash em campo ausente

### Testing

- Framework: seguir o padrão existente em `Tests/ClaudeBarCoreTests/`
- Cobertura mínima: normalização de e-mail, fallback de chave opaca, gate de fingerprint, decoder tolerante, propagação para `UsageSnapshot`

---

## Definition of Done

- [x] `Provider`/`AccountKey`/`AccountIdentity` criados e reusáveis por 5.2/5.4
- [x] Leitor de identidade gated por fingerprint, off-main, decoder tolerante
- [x] Fallback de chave opaca quando `oauthAccount` ausente
- [x] `UsageSnapshot.identity` populado de verdade (D1 corrigida)
- [x] Header do popover exibe e-mail real (verificado contra o `~/.claude.json` real: `hugocapitelli@gmail.com`)
- [x] 5+ novos testes verdes; zero regressões — **12 novos, 336/336 verdes** via `Scripts/run-tests.sh`
- [x] `swift build -c release` zero warnings

---

## Dev Agent Record (@dev Dex)

### `swift test` sem Xcode — diagnóstico e correção permanente

Um `swift test` cru **falha** nesta máquina, e o erro engana:

```
$ swift test --arch arm64 --no-parallel
Tests/ClaudeBarCoreTests/CLITests.swift:2:8: error: no such module 'Testing'
error: fatalError        (exit 1, 40 ocorrências, TODA a suíte existente)
```

Parece "swift-testing não está instalado". **Não é.** O Command Line Tools traz
`Testing.framework` com o `arm64-apple-macos.swiftinterface` em
`$(xcode-select -p)/Library/Developer/Frameworks/`. Faltam três coisas que o Xcode daria:

| Sintoma | Causa | Flag |
|---|---|---|
| `no such module 'Testing'` | o diretório não está no framework search path | `-F` |
| `no such module '_Testing_Foundation'` (aparece só depois do `-F`) | o overlay cross-import está **vazio** — `_Testing_Foundation.framework/Modules` não tem módulo nenhum | `-Xfrontend -disable-cross-import-overlays` |
| linka, mas morre no `dlopen` (`Library not loaded: @rpath/Testing.framework/…`) | o `.xctest` não tem rpath para a framework | `-Xlinker -rpath` |

Com as três, a suíte compila, linka e roda normalmente. Isso virou
**`Scripts/run-tests.sh`**, para ninguém mais reencontrar esse beco:

```
$ Scripts/run-tests.sh
✔ Test run with 336 tests in 44 suites passed after 17.119 seconds.     (exit 0)

$ Scripts/run-tests.sh --filter ClaudeIdentityResolverTests
✔ Test run with 12 tests in 1 suite passed after 0.010 seconds.
```

**Baseline para 5.2/5.3/5.4 compararem: 324 testes** (336 executados menos os 12 desta story;
bate com `grep -rc "@Test" Tests/**/*.swift` no commit `7b48acb`). **Zero falhas, zero regressões.**

Nota de processo: a primeira leitura deste ambiente foi que `swift test` era impossível aqui, e
um harness executável avulso chegou a ser escrito como gate substituto. Ele foi **removido** —
com a suíte real rodando, era verificação duplicada destinada a apodrecer. O gate é
`Scripts/run-tests.sh`.

### Correções de premissa da story

- **AC4.8 estava desatualizada.** A story afirma que `UsageSnapshot.from` "hoje não aceita
  identidade" e que o wiring "exige adicionar um parâmetro `identity:`". **Ele já existia**
  (`UsageSnapshot+OAuth.swift:20`, `identity: Identity? = nil`) — o defeito D1 era só o
  `UsageFetcher` nunca passar o argumento. Nenhum parâmetro novo foi criado; o wiring foi
  exclusivamente no chamador. AC4.9 foi respeitada: `UsageSnapshot.Identity` está intacto.

### Decisões de implementação

- **`ClaudeIdentityResolver` é um `actor` sem timer próprio**, consultado sob demanda pelo
  `UsageFetcher` — a story pedia explicitamente para não introduzir um segundo timer.
- **Fingerprint em memória, não em `UserDefaults`.** O `CredentialsStore` persiste o fingerprint
  porque precisa detectar *mudança entre lançamentos* para invalidar cache de credencial. Aqui a
  pergunta é outra — "preciso reparsear agora?" — e a resposta certa no boot é sempre "sim, uma
  vez". Persistir criaria o risco de servir identidade obsoleta após um `claude login` feito com o
  app fechado.
- **`parseCount` é `public private(set)`.** O gate de fingerprint é invisível de fora: duas chamadas
  a `resolve` são indistinguíveis com ou sem reparse. Sem esse contador, AC2.4 não é verificável —
  seria uma afirmação, não uma prova. É seam de teste declarado, não vazamento acidental.
- **Fallback R12 devolve `email: ""`**, não um e-mail sintético. `UsageCardView.swift:92` já testa
  `!email.isEmpty`, então o header simplesmente não renderiza nada — em vez de exibir um hash ao
  usuário. O rótulo `"Conta N"` vai no `displayName`, que é o que o roster de 5.2 mostra.
- **`identityResolver` é injetável e anulável** no `UsageFetcher` (`identityResolver: nil`). Foi o
  que permitiu testar HTTP sem tocar em nenhum arquivo real, mantendo a higiene de teste que a
  EXB-3.8 estabeleceu.
- **Decoder tolerante em duas camadas:** `DynamicCodingKey` (já existente em
  `OAuthUsageResponse.swift:89`, reusado) extrai só `oauthAccount`, e um `try?` interno absorve um
  `oauthAccount` malformado. Provado: `"oauthAccount": "not-an-object"` degrada para o fallback em
  vez de lançar.

### File List

| Arquivo | Ação |
|---|---|
| `Sources/ClaudeBarCore/Model/AccountIdentity.swift` | **novo** — `Provider`, `AccountKey` (+ `normalize`), `AccountIdentity` |
| `Sources/ClaudeBarCore/OAuth/ClaudeIdentityResolver.swift` | **novo** — actor, gate de fingerprint, decode tolerante, fallback opaco |
| `Sources/ClaudeBarCore/OAuth/UsageFetcher.swift` | modificado — resolver injetável; `fetchSnapshot` popula `identity:` |
| `Sources/ClaudeBarCore/OAuth/UsageSnapshot+OAuth.swift` | modificado — `UsageSnapshot.Identity.init(_ account: AccountIdentity)` |
| `Tests/ClaudeBarCoreTests/ClaudeIdentityResolverTests.swift` | **novo** — 12 testes, todos verdes |
| `Scripts/run-tests.sh` | **novo** — destrava `swift test` em máquina sem Xcode (achado desta story, não requisito dela) |

Nenhum arquivo fora do escopo da story foi tocado. `UsageSnapshot.swift`, `DisplaySnapshot.swift` e
`UsageCardView.swift` **não** foram modificados — a cadeia já existia e só faltava alimentá-la.

### Comandos de verificação executados

| Comando | Resultado |
|---|---|
| `swift build --arch arm64` | Build complete — zero warnings |
| `swift build -c release --arch arm64` | Build complete — zero warnings (AC5.12) |
| `swift test --arch arm64 --no-parallel` (cru) | falha na compilação — ver diagnóstico acima |
| `Scripts/run-tests.sh` | **336/336 verdes, 44 suítes, exit 0** (baseline 324 + 12) |
| `Scripts/run-tests.sh --filter ClaudeIdentityResolverTests` | **12/12 verdes** |
| `grep -n "identity:" …/UsageFetcher.swift` | 2 ocorrências (linhas 52, 63) — antes: **zero** (AC6.15) |
| `grep -n "public struct Identity" …/UsageSnapshot.swift` | 1 ocorrência (linha 9) — preservada (AC6.16) |
| e-mail real vs. resolver | `hugocapitelli@gmail.com` em ambos (AC6.17) |

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0) | @sm River |
| 2026-07-31 | 1.2 | Implementação @dev: `AccountIdentity.swift` + `ClaudeIdentityResolver.swift` novos, wiring no `UsageFetcher`, mapeamento `AccountIdentity → UsageSnapshot.Identity`, 12 testes. D1 fechada. Premissa da AC4.8 corrigida (o parâmetro `identity:` de `UsageSnapshot.from` já existia). `swift test` destravado em máquina sem Xcode (`Scripts/run-tests.sh`): **336/336 verdes**, baseline 324. Status → Ready for Review. | @dev Dex |
| 2026-07-31 | 1.1 | Validação @po: **GO 9/10**. AC4 corrigida (o wiring exige parâmetro novo em `UsageSnapshot.from`, e o tipo `UsageSnapshot.Identity` NÃO pode ser substituído por `AccountIdentity` — quebraria `DisplaySnapshot.swift:134`/`UsageCardView.swift:92`). AC6 nova com comandos mecânicos. Complexidade estimada. Status → Ready. | @po Pax |

---

## QA Results (@qa Quinn) — 2026-07-31

**Veredito: PASS.** Verificação independente, do zero, sem confiar no Dev Agent Record.

### Prova executada por mim

| Verificação | Comando / método | Resultado |
|---|---|---|
| Suíte completa | `Scripts/run-tests.sh` | **403/403 verdes, 49 suítes, exit 0**; zero linhas `✘`/`error:` no log |
| Release limpo | `swift build -c release --arch arm64 --scratch-path` (scratch novo, sem cache) | `Build complete! (95.97s)` — **0 warnings, 0 errors** |
| AC6.15 (D1 fechada) | `grep -n "identity:" …/UsageFetcher.swift` | 2 ocorrências (52, 63). **Baseline `git show HEAD:` = 0** — a regressão de D1 é literal e medida, não alegada |
| AC6.16 (tipo preservado) | `grep -n "public struct Identity" …/UsageSnapshot.swift` | 1 ocorrência (linha 9) — intacto |
| AC2.3/AC4 ponta a ponta | binário descartável linkado contra o `ClaudeBarCore` de **release**, contra o `~/.claude.json` **real** | `email = hugocapitelli@gmail.com`, `key.id = hugocapitelli@gmail.com`, `provider = claude`, `display = Hugo`, `org = hugocapitelli@gmail.com's Organization` — bate campo a campo com o `python3 -c json.load` do arquivo |
| AC2.4 (gate de fingerprint) | mesmo binário: 2 `resolve()` consecutivos | `parseCount` = **1 → 1**. O arquivo de 45 KB **não** é reparseado. Prova de execução, não de leitura de código |
| I1 (zero I/O na main) | `grep -rn "FileManager\|Data(contentsOf" Sources/ClaudeBar/{Popover,Settings,StatusItem}/` | zero ocorrências |

Artefatos descartáveis (binário de prova, scratch de build) removidos; `git status` voltou aos mesmos 38 arquivos do início, `grep` por resíduo de sonda retorna vazio.

### Observações

- O Dev Agent Record corrige honestamente uma premissa errada da própria AC4.8 (o parâmetro `identity:` de `UsageSnapshot.from` **já existia**; o defeito era só o chamador). Confirmado por mim no `git show HEAD:` — a correção está certa e a AC estava desatualizada, não a implementação.
- `Scripts/run-tests.sh` é um subproduto legítimo desta story e o gate real da onda inteira. As 3 flags estão documentadas no próprio arquivo.
