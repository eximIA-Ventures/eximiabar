# Story EXB-5.2: Roster de contas — captura no login + persistência somente-leitura

**ID:** EXB-5.2
**Status:** Done
**Depends on:** EXB-5.1 (`AccountKey`/`AccountIdentity` — o roster indexa por essa chave)
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** L (actor novo + keychain service novo + gancho no polling existente; carrega 6 riscos R9–R16)

---

## Story

**As a** exímIABar user que troca de conta Claude via `claude login`,
**I want** que o app capture automaticamente a conta anterior (arquivando-a) no instante em que detecta uma troca de identidade, mantendo um roster local e somente-leitura das contas já vistas,
**so that** eu não perco o histórico de contas usadas nem o painel de uma conta que não está mais "viva" no CLI, sem nunca correr o risco de o app renovar um token que não é dele para renovar.

---

## Acceptance Criteria

### AC1 — Modelo de dados do roster

1. Novos tipos (Sendable, Codable onde aplicável) em `Sources/ClaudeBarCore/Accounts/`:
   - `enum AccountLifecycle: String, Codable, Sendable { case live, archived }`
   - `struct AccountRosterEntry: Codable, Sendable { let identity: AccountIdentity; let lifecycle: AccountLifecycle; let plan: String?; let capturedAt: Date; var lastSeenAt: Date; let tokenExpiresAt: Date? }`
   - `struct ArchivedToken: Sendable { let accessToken: String; let expiresAt: Date? }` — **NÃO** contém `refreshToken` (ver AC3, decisão D-A).
2. O **índice persistido** (`[AccountRosterEntry]`) **NÃO** contém o campo de foco do switcher (`focusedKey`) — foco é estado de sessão em memória, definido e testado em `EXB-5.3` (decisão D-C do dono do produto). Este índice é só o roster de contas.

### AC2 — Persistência em duas camadas

3. **Índice (metadado):** `[AccountRosterEntry]` serializado em JSON, arquivo `~/Library/Application Support/exímIABar/accounts.json`, permissão de arquivo `0600`. Enumerável e legível **sem tocar no keychain**.
4. **Segredos:** apenas para contas `.archived`, guardados em keychain próprio, `service = "com.eximia.eximiabar.accounts"`, `account = "{provider}:{email}"`. Atributo `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (sem sincronização iCloud).
5. **Decisão D-A (dono do produto, confirmando a recomendação do Aria):** o segredo arquivado contém **apenas `accessToken` + `expiresAt`**. O **refresh token NUNCA é arquivado** — contas arquivadas são estritamente somente-leitura (nunca renovadas, AC5), logo um refresh token guardado é passivo de segurança puro sem uso funcional.
6. O componente responsável é um `actor` `AccountRosterStore` (`Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift`) com API:
   ```swift
   public actor AccountRosterStore {
       func roster() -> [AccountRosterEntry]
       func archivedToken(for key: AccountKey) -> ArchivedToken?
       func captureIfIdentityChanged(current: AccountIdentity, credentials: ClaudeOAuthCredentials) -> CaptureOutcome
       func remove(_ key: AccountKey)
   }
   ```
   **Nome de tipo verificado no código:** o tipo real da credencial é **`ClaudeOAuthCredentials`** (`Sources/ClaudeBarCore/OAuth/UsageFetcher.swift:35`), **não** `ClaudeCredentials` (`ClaudeCredentialsFile` é o wrapper do arquivo, outra coisa).
7. O serviço de keychain usado pelo `AccountRosterStore` é **injetável** no `init` (mesmo seam de `CredentialsStore.swift:41`) — o processo de testes **nunca** toca o service de produção `com.eximia.eximiabar.accounts`.

### AC3 — Decisão D-B: teto do roster

8. **Decisão D-B (dono do produto, confirmando a recomendação do Aria):** o roster tem um teto de **8 entradas**. Ao capturar uma 9ª conta, a entrada mais antiga por `lastSeenAt` (LRU) é evictada automaticamente antes de inserir a nova.

### AC4 — Captura automática no login (gatilho)

9. A captura se pendura no `CredentialsStore.pollFingerprintsAndInvalidateIfChanged()` existente (`CredentialsStore.swift:429`, já roda no máximo 1×/60s) — **sem novo timer**. Este método é `private`, logo o gancho vive **dentro do próprio `CredentialsStore`** (não é chamável de fora); `CredentialsStore` passa a receber `AccountRosterStore` + o resolvedor de identidade da `EXB-5.1` por injeção no `init`, ambos opcionais com default `nil` para não quebrar os construtores existentes nos testes.
10. Fluxo: quando o fingerprint muda, resolve a identidade atual (via `EXB-5.1`); se a identidade for diferente da última conhecida, arquiva a credencial **anterior** (ainda em cache) no roster como `.archived`, marca a nova identidade como `.live`.
11. **Ordem obrigatória (armadilha real):** hoje `pollFingerprintsAndInvalidateIfChanged` **derruba o cache em memória e o cache de keychain** quando o fingerprint muda. A captura da credencial anterior DEVE acontecer **ANTES** dessa invalidação — depois dela a credencial anterior já não existe em lugar nenhum e o arquivamento sempre falharia silenciosamente. **Teste obrigatório `capturesPreviousCredentialBeforeCacheInvalidation`:** simular troca de fingerprint e provar que a entrada `.archived` resultante contém o `accessToken` **anterior**, não o novo nem `nil`.
12. **Regra dura contra corrida (R11):** só arquiva quando o parse da credencial anterior **e** a resolução de identidade tiveram sucesso simultaneamente. Se o parse falhar (ex.: `.credentials.json` lido a meio de uma escrita não-atômica do `claude login`), a operação é **no-op** — tenta de novo no próximo poll (60s). Nunca sobrescreve uma entrada de roster existente com dados de parse parcial.

### AC5 — Contrato somente-leitura de contas arquivadas

13. Contas `.archived` **nunca** têm fetch de usage e **nunca** têm refresh de token — em nenhuma circunstância. O `RefreshCoordinator` **não é modificado**; a garantia é estrutural (o único caminho de fetch parte da credencial `.live`).
14. **Teste obrigatório T-R9:** com N contas arquivadas populadas no roster, executar um ciclo completo de refresh e provar (via spy/mock no `RefreshCoordinator`) que **zero** chamadas de refresh ou fetch são feitas para elas.

### AC6 — Isolamento de thread (R10)

15. `AccountRosterStore` é um `actor` — nenhuma anotação `@MainActor`. Todo I/O (arquivo + keychain) roda atrás de `await`.
16. **Teste T-R10:** grep/assert de que nenhuma leitura do roster acontece de fora do `Task.detached` do ciclo de refresh; a UI nunca consulta o store diretamente (consome via `WorkspaceSnapshot`, `EXB-5.3`).

### AC7 — Build e testes

17. `swift build -c release` zero warnings.
18. `swift test` sem regressões da baseline registrada no Dev Agent Record da `EXB-5.1` (AC5.13).
19. Pelo menos **9 novos testes unitários**, incluindo (mas não limitado a): `T-R9` (zero refresh em arquivadas), `T-R10` (isolamento actor), `T-R11` (parse falho é no-op), `capturesPreviousCredentialBeforeCacheInvalidation` (AC4.11), `rosterEvictsOldestByLastSeenAtAt9thEntry` (D-B), `archivedSecretNeverContainsRefreshToken` (D-A), `indexFileNeverContainsSecrets`, `keychainServiceIsInjectableInTests`, `duplicateIdentityDoesNotDuplicateRosterEntry`.

### AC8 — Comandos de verificação (mecânicos)

20. **D-A, prova estrutural:** `grep -n "refreshToken\|refresh_token" Sources/ClaudeBarCore/Accounts/` → **zero** ocorrências. O tipo `ArchivedToken` não tem o campo, logo é impossível arquivá-lo por acidente.
21. **Índice sem segredos:** `grep -niE "accessToken|refreshToken|Bearer" ~/Library/Application\ Support/exímIABar/accounts.json` → **zero** ocorrências após uma captura real.
22. **Permissão do índice:** `stat -f "%OLp" ~/Library/Application\ Support/exímIABar/accounts.json` → `600`.
23. **D-B, prova a olho:** após popular 9 identidades distintas, `python3 -c "import json;print(len(json.load(open('...accounts.json'))))"` → `8`.
24. **Sem `@MainActor` no store (R10):** `grep -n "@MainActor" Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift` → **zero** ocorrências.

---

## Tasks

- [x] **T1 — Criar tipos do roster** (AC1) — `Sources/ClaudeBarCore/Accounts/AccountRosterEntry.swift`
- [x] **T2 — Criar `AccountRosterStore` actor** (AC2, AC6) — `Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift`, índice JSON `0600` + keychain próprio injetável
- [x] **T3 — Implementar `captureIfIdentityChanged` + gancho no polling** (AC4) — `Sources/ClaudeBarCore/OAuth/CredentialsStore.swift:429`; injeção opcional (`nil` default) de `AccountRosterStore` + resolvedor de identidade no `init` do `CredentialsStore`; **capturar ANTES da invalidação de cache** (AC4.11)
- [x] **T4 — Evicção LRU no teto de 8** (AC3) — dentro de `AccountRosterStore`
- [x] **T5 — Garantir contrato somente-leitura** (AC5) — nenhuma mudança no `RefreshCoordinator`; documentar a garantia estrutural
- [x] **T6 — Testes** (AC7) — `Tests/ClaudeBarCoreTests/AccountRosterStoreTests.swift`

---

## Dev Notes

### Por que a separação índice/segredo é o coração do desenho

`AccountRosterEntry` é **puro metadado — não contém segredo nenhum**. O switcher (`EXB-5.5`) renderiza a lista inteira de contas e deriva o estado "expirado" a partir de `tokenExpiresAt` **sem tocar no keychain**. Só o card de uma conta arquivada específica, ao ser renderizado, consulta `archivedToken(for:)` sob demanda.

### Seam de teste injetável (por que importa)

`CredentialsStore.swift:36-40` documenta a causa-raiz do pop-up de keychain que a `EXB-3.8` custou uma onda inteira para eliminar: o processo de testes tocando o item real de keychain. `AccountRosterStore` **deve** herdar esse seam desde o primeiro commit — nunca reintroduzir esse risco com um service novo.

### Regra dura contra corrida (R11) — por quê

Arquivar lixo (dados de um parse parcial, meio-escritos pelo `claude login`) é pior que perder um ciclo de captura. O gate é: parse da credencial anterior com sucesso **E** resolução de identidade com sucesso, ambos, ou nada acontece.

### Fora de escopo desta story

- UI de "remover conta" em Settings — a **ação** (`remove(_:)`) é implementada aqui, a **superfície visual** é da `EXB-5.5`.
- O campo `focusedKey`/foco do switcher — pertence à `EXB-5.3` (decisão D-C, não persiste entre reinícios).

### Anti-freeze invariants

- `actor` puro, zero `@MainActor`
- Índice lido **uma vez por ciclo** no `Task.detached` existente (via `EXB-5.3`), nunca direto da UI

### Testing

- Arquivo: `Tests/ClaudeBarCoreTests/AccountRosterStoreTests.swift`
- Usar `tmpdir` para o arquivo de índice (mesmo padrão de testes já usado no repo para `CredentialsStore`)
- Keychain service mockável/injetável nos testes — nunca tocar `com.eximia.eximiabar.accounts` real

---

## Definition of Done

- [x] `AccountRosterStore` actor completo (roster/archivedToken/capture/remove)
- [x] Índice `0600` sem segredos; segredos em keychain próprio, injetável
- [x] D-A aplicada: refresh token nunca arquivado
- [x] D-B aplicada: teto de 8, evicção LRU
- [x] Captura automática pendurada no polling existente, sem novo timer
- [x] R11: parse falho é no-op, nunca corrompe entrada existente
- [x] Captura acontece ANTES da invalidação de cache do polling (AC4.11)
- [x] T-R9 e T-R10 passando (zero refresh em arquivadas; isolamento de actor)
- [x] Os 5 comandos de verificação da AC8 executados, output colado no Dev Agent Record
- [x] 9+ novos testes verdes; zero regressões
- [x] `swift build -c release` zero warnings

---

## Dev Agent Record (@dev Dex)

### Baseline e resultado

| Comando | Resultado |
|---|---|
| `Scripts/run-tests.sh` (antes de tocar em nada) | **336/336 verdes, 44 suítes** — bate com a baseline da `EXB-5.1` |
| `Scripts/run-tests.sh --filter AccountRosterStoreTests` | **14/14 verdes** |
| `Scripts/run-tests.sh` (final) | **367/367 verdes, 46 suítes, exit 0** — zero regressões |
| `swift build --arch arm64` | Build complete, zero warnings |
| `swift build -c release --arch arm64` | Build complete, zero warnings (AC7.17) |

367 = 336 da baseline + **14 desta story** + 17 da `EXB-5.4`, que rodou em paralelo na mesma
árvore. Durante a implementação a suíte ficou momentaneamente inconstruível por um erro de
compilação em `CodexProviderTests.swift` (arquivo da 5.4, em escrita naquele instante); resolveu-se
sozinho, sem nenhuma intervenção deste agente em arquivos da outra story.

### AC8 — os 5 comandos de verificação, output literal

A prova de índice real (AC8.21–23) exigia uma captura no caminho de **produção**. Foi feita por um
binário descartável linkado contra o `ClaudeBarCore` já compilado, escrevendo o índice no caminho
real mas com um keychain service de prova (`…accounts.proof`), nunca o de produção. Os artefatos
foram removidos ao final (índice apagado, itens de keychain de prova apagados, service de produção
verificado como inexistente).

```
== AC8.20 — D-A estrutural ==
$ grep -rn "refreshToken\|refresh_token" Sources/ClaudeBarCore/Accounts/
(exit 1 — zero ocorrências)

== AC8.21 — índice sem segredos ==
$ grep -niE "accessToken|refreshToken|Bearer" ~/Library/Application\ Support/exímIABar/accounts.json
(exit 1 — zero ocorrências)

== AC8.22 — permissão do índice ==
$ stat -f "%OLp" ~/Library/Application\ Support/exímIABar/accounts.json
600

== AC8.23 — D-B, teto de 8 após 9 identidades ==
$ python3 -c "import json;print(len(json.load(open('…/accounts.json'))))"
8

== AC8.24 — sem @MainActor no store ==
$ grep -n "@MainActor" Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift
(exit 1 — zero ocorrências)
```

Uma entrada do índice real, na íntegra — metadado e nada mais:

```json
{ "capturedAt": "2026-07-31T21:37:51Z",
  "identity": { "displayName": "Proof 2", "email": "proof2@example.com",
                "key": { "identifier": "proof2@example.com", "provider": "claude" } },
  "lastSeenAt": "2026-07-31T21:37:51Z", "lifecycle": "archived",
  "tokenExpiresAt": "2100-01-01T00:00:00Z" }
```

AC8.20 e AC8.24 não dependem de execução manual: viraram os testes
`accountsModuleNeverNamesTheRenewalCredential` e `rosterStoreIsAPlainActorAndIsNeverReadFromTheUI`,
que varrem o próprio código-fonte. Um `@MainActor` colado no store no futuro quebra a suíte.

### Decisões de implementação

- **A captura roda em TODO poll, não só quando o fingerprint muda.** A AC4.10 descreve o fluxo do
  instante da troca, mas só isso não funciona: o roster precisa já saber quem era a conta viva
  ANTES da troca para ter o que arquivar. Como o poll é o mesmo (≤ 1×/60 s, sem timer novo), o
  custo é idêntico e o bootstrap fecha em um ciclo. Sem isso, a primeira troca de conta após abrir
  o app arquivaria `nil`.
- **`load(phase:)` e o poll passaram a ser `async`.** A captura precisa de `await` (dois actors:
  roster e resolvedor) e tinha de acontecer DENTRO do poll, antes da invalidação (AC4.11). Como
  `CredentialsStore` já é um `actor`, todo chamador de `load` já escrevia `await` — a mudança é
  fonte-compatível, nenhum call site precisou ser tocado.
- **`AccountIdentity` ganhou `Codable` por extensão manual**, em `Accounts/`, não na declaração da
  `EXB-5.1`. Swift só sintetiza a conformidade no arquivo que declara o tipo, e editar o arquivo da
  5.1 durante a execução paralela da 5.4 era risco de colisão sem ganho.
- **Segredo arquivado sai do keychain quando a conta volta a ser viva.** O token de uma conta viva
  pertence ao CLI; manter uma cópia nossa seria um segundo passivo pelo mesmo motivo que motivou a
  D-A.
- **Um seam novo em `CredentialsStore`: `expireFingerprintThrottleForTesting()`, sob `#if DEBUG`**,
  no mesmo padrão do `setSecurityCLIReadOverrideForTesting` que já existia. O teste da AC4.11
  precisa de três polls consecutivos; sem o seam seriam três minutos de `sleep`.
- **`RefreshCoordinator` não foi tocado** (AC5.13). A garantia é estrutural: tanto o coordenador
  quanto o `UsageFetcher` recebem uma credencial como parâmetro, e o roster não entrega nenhuma
  para lugar nenhum — `archivedToken(for:)` só devolve sob demanda, para quem for renderizar um
  card. O teste T-R9 prova pelo tráfego: com 3 contas arquivadas no roster, um ciclo completo de
  refresh + fetch emite exatamente 1 POST e 1 GET, nenhum deles carregando um token arquivado, e a
  contagem não escala com o tamanho do roster.
- **O roster é ligado só no caminho real do app** (`LiveUsageProvider`, init com
  `promptPolicyProvider`, que é o que `ClaudeBarApp.swift:104` usa). Todo outro `CredentialsStore`
  — testes, previews — fica com os defaults `nil` e não captura nada, exatamente como antes.

### Auto-crítica aplicada antes de fechar

`putLive` tinha um laço que rebaixava outras contas vivas do mesmo provider para `.archived` — sem
gravar segredo, o que produziria uma entrada arquivada sem token. O estado é inalcançável (o único
chamador arquiva a conta anterior antes de chegar ali), então era código defensivo para um cenário
impossível, mais uma inconsistência latente do que uma proteção. Removido.

### File List

| Arquivo | Ação |
|---|---|
| `Sources/ClaudeBarCore/Accounts/AccountRosterEntry.swift` | **novo** — `AccountLifecycle`, `AccountRosterEntry`, `ArchivedToken`, `CaptureOutcome`, `AccountIdentity: Codable` |
| `Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift` | **novo** — actor; índice `0600` + keychain injetável; captura, evicção LRU, remoção |
| `Sources/ClaudeBarCore/OAuth/CredentialsStore.swift` | modificado — injeção opcional de roster/resolvedor, `load`+poll `async`, captura antes da invalidação, seam de throttle sob `#if DEBUG` |
| `Sources/ClaudeBar/App/LiveUsageProvider.swift` | modificado — liga roster + resolvedor no init real do app (2 linhas) |
| `Tests/ClaudeBarCoreTests/AccountRosterStoreTests.swift` | **novo** — 14 testes, todos verdes |

Nenhum arquivo da `EXB-5.1` ou da `EXB-5.4` foi tocado. `RefreshCoordinator.swift` intacto (AC5.13).

### Os 14 testes

| Teste | Cobre |
|---|---|
| `firstCaptureRecordsTheAccountAsLive` | AC1, AC2 |
| `indexRoundTripsThroughDiskAcrossStoreInstances` | AC2.3 |
| `indexFileIsMode0600` | AC2.3 / AC8.22 |
| `indexFileNeverContainsSecrets` | AC2.3 / AC8.21 |
| `keychainServiceIsInjectableInTests` | AC2.7 |
| `archivedSecretNeverContainsRefreshToken` | **D-A** |
| `accountsModuleNeverNamesTheRenewalCredential` | **D-A** / AC8.20 |
| `rosterEvictsOldestByLastSeenAtAt9thEntry` | **D-B** / AC8.23 |
| `partialCredentialParseIsNoOpAndNeverOverwritesAnExistingEntry` | **T-R11** |
| `duplicateIdentityDoesNotDuplicateRosterEntry` | AC7.19 |
| `removeDropsBothTheEntryAndItsSecret` | AC2.6 |
| `rosterStoreIsAPlainActorAndIsNeverReadFromTheUI` | **T-R10** / AC8.24 |
| `archivedAccountsNeverTriggerRefreshOrFetch` | **T-R9** / AC5 |
| `capturesPreviousCredentialBeforeCacheInvalidation` | **AC4.11** |

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.2 | Implementação @dev: `AccountRosterEntry.swift` + `AccountRosterStore.swift` novos, gancho de captura no polling do `CredentialsStore` (antes da invalidação), roster ligado ao app via `LiveUsageProvider`, 14 testes. D-A e D-B provadas por teste e pelos 5 comandos da AC8. **367/367 verdes** (baseline 336 + 14 desta story + 17 da 5.4 paralela), zero regressões, release sem warnings. Status → Ready for Review. | @dev Dex |
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0). D-A e D-B do dono do produto aplicadas nos ACs. | @sm River |
| 2026-07-31 | 1.1 | Validação @po: **GO 9/10**. Corrigido nome de tipo (`ClaudeCredentials` → `ClaudeOAuthCredentials`, verificado no código). Adicionada AC4.11 (ordem obrigatória: capturar ANTES da invalidação de cache — o polling derruba o cache, a captura falharia silenciosamente) + teste. Adicionada AC8 com 5 comandos mecânicos que provam D-A e D-B. Complexidade estimada. Status → Ready. | @po Pax |

---

## QA Results (@qa Quinn) — 2026-07-31

**Veredito: PASS.** Verificação independente. Os 5 comandos da AC8 foram rodados por mim, não lidos do relato.

### Prova executada por mim

| Verificação | Comando / método | Resultado |
|---|---|---|
| **D-A** estrutural | `grep -rn "refreshToken\|refresh_token" Sources/ClaudeBarCore/Accounts/` | **exit 1, zero ocorrências**. `ArchivedToken` não tem o campo — arquivar um refresh token é impossível de escrever, não apenas proibido |
| **D-B** teto + LRU | leitura de `AccountRosterStore.evictUntilRoomForOneMore` | `maxEntries = 8`; evicção por `min(lastSeenAt)` e — o ponto que importa — `deleteSecret(for:)` junto, **sem segredo órfão no keychain**. A conta `.live` nunca é a LRU porque o `putLive` atualiza `lastSeenAt` a cada poll |
| AC8.24 (R10) | `grep -n "@MainActor" …/AccountRosterStore.swift` | zero ocorrências |
| R10 na prática | `grep -rn "AccountRosterStore" Sources/ClaudeBar/` | **só** `LiveUsageProvider.swift` (3 linhas). Settings fala pelo port `AccountRosterAccess`, cujo par de closures só pode ser `await`ed — a chamada síncrona a partir de um `body` é *impossível de escrever* |
| **R11** (contra corrida) | leitura de `CredentialsStore.captureAccountIntoRoster` | fail-closed em **4 camadas**: roster+resolver injetados, `cachedRecord?.credentials` presente, `identityResolver.resolve` devolveu identidade, e `accessToken` não-vazio dentro do store. Qualquer falha → no-op silencioso, tenta no próximo poll |
| **AC4.11** (ordem) | leitura de `pollFingerprintsAndInvalidateIfChanged` | `await self.captureAccountIntoRoster()` na **linha 482**, `if changed { … cachedRecord = nil … clearCacheKeychain() }` na **484**. A ordem está correta e comentada como load-bearing |
| AC4.11 (teste) | `capturesPreviousCredentialBeforeCacheInvalidation` | teste ponta a ponta **real**: home temporário, `.credentials.json` e `.claude.json` de verdade, mtime manipulado para simular `claude login`. Assere `archived.accessToken == "TOKEN-A"` **e** `!= "TOKEN-B"`. Não é mock de conveniência |
| **T-R9** | `archivedAccountsNeverTriggerRefreshOrFetch` | 3 contas arquivadas + ciclo completo: `requestCount == 1` (POST) e `fetchSpy.requestCount == 1` (GET), e varre corpos **e** headers provando que nenhum token arquivado saiu do processo. A contagem **não escala** com o roster |
| Suíte + release | `Scripts/run-tests.sh` / `swift build -c release` limpo | 403/403 verdes; 0 warnings |

### Observações

- A decisão de **rodar a captura em todo poll** (não só na troca) está certa e é bem justificada: sem o bootstrap, a primeira troca após abrir o app arquivaria `nil`. Custo zero (mesmo poll, sem timer novo).
- A auto-crítica do @dev removendo o laço defensivo de `putLive` é o tipo de subtração que o padrão da casa premia: código defensivo para estado inalcançável é inconsistência latente, não proteção.
