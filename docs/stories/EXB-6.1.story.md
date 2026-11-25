# Story EXB-6.1: Blindar os números (origem, estimativa e conta medida)

**ID:** EXB-6.1
**Status:** Done
**Depends on:** —
**Epic:** EPIC-EXB
**Wave:** Onda 11 (v2.8 "Confiança e foco")
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M

> Nota de numeração: comentários antigos no código citam "EXB-6.1 V1/V2/V3" (histograma, cascata, fluxo) de uma rodada de design sem story file. Esta é a primeira story em disco com o prefixo EXB-6.x; aqueles comentários não se referem a ela.

---

## Story

**As a** usuário do exímIABar,
**I want** que todo número estimado, posicional ou de outra conta venha marcado como tal,
**so that** eu nunca tome uma decisão sobre um número que parece medido e não é.

---

## Acceptance Criteria

### AC1 — Leitura posicional do fallback CLI (`ClaudeStatusProbe.swift`)
1.1. O caminho posicional ("primeiros dois `\d+%`") só aceita valores cujo número **bruto** está em 0–100 (sem `clamp` silencioso: `140%` reprova a leitura, não vira `100%`).
1.2. Coerência: o posicional só é aceito quando há **no máximo 4** linhas com percentual no buffer (acima disso a posição é ambígua) e pelo menos 2 para preencher sessão e semana.
1.3. O parser expõe se a leitura foi posicional (`ClaudeUsageReading.isPositional`); o caminho rotulado permanece idêntico (todos os testes existentes do parser verdes).
1.4. `DisplaySnapshot.isApproximate == true` sempre que `source == .cli`; a barra (`MenuBarContentText`/`MenuBarDisplayText`) e o número grande do popover (`MetricRow`) prefixam `~`.

### AC2 — Custo estimado por família
2.1. `Pricing` classifica a origem do preço: `catalog` (models.dev), `table` (tabela embutida, chave exata), `family` (modelo desconhecido precificado pela família) ou `fallbackDefault` (nem família inferível).
2.2. `ProviderCost` carrega `estimatedTokens` (tokens precificados por `family`/`fallbackDefault`) e `estimatedShare` (0–1); `isEstimated == estimatedShare > 0`.
2.3. Com `isEstimated`, o total de 30d e o "Hoje" do popover ganham `~`, a barra (`costToday`) ganha `~`, e o rodapé mostra "X% estimado por família".
2.4. Fixture com modelo inventado (`claude-opus-9-9`) acende o marcador; fixture só com modelos da tabela não acende.

### AC3 — Multi-conta
3.1. Quando a conta em foco no popover ≠ conta medida na barra, o cartão mostra um cabeçalho fixo "Barra mostra: <conta>".
3.2. A identidade fallback `live` (identificador `live` ou vazio) nunca é gravada no roster (`AccountRosterStore.captureIfIdentityChanged` devolve `.skipped`).

### AC4 — Testes que reprovam
4.1. Teste que reprova se um snapshot `.cli` renderizar percentual sem `~` (barra e popover).
4.2. Teste que reprova se um custo com `estimatedShare > 0` for formatado sem `~`.
4.3. Testes do parser: `140%` posicional → `nil`; 5+ linhas de percentual sem rótulo → `nil`; rotulado com 5+ linhas continua aceito.
4.4. Teste do roster: identidade `live` → `.skipped` e roster vazio.
4.5. EN e PT-BR para todas as strings novas.

---

## Tasks
- [x] T1 Parser: `parseUsageReading` com validação bruta e flag posicional (AC1.1–1.3)
- [x] T2 `isApproximate` + marcador `~` na barra e no popover (AC1.4)
- [x] T3 `Pricing.PriceSource` + contagem no `CostScanner.scan` + UI (AC2)
- [x] T4 Cabeçalho "Barra mostra" + guarda do roster (AC3)
- [x] T5 Testes (AC4) e strings (AC4.5)

## Verificação
- `swift build --arch arm64`
- `Scripts/run-tests.sh`

## Dev Agent Record

### Decisões
- `[AUTO-DECISION]` Novo `DataSource` para "posicional"? → **não**: todo `.cli` já é raspagem de TUI, então `~` vale para qualquer `.cli` (`DisplaySnapshot.isApproximate`); o parser expõe `isPositional` só para a validação. (motivo: evita mexer em 5 `switch` e no Settings por uma distinção que a UI trataria igual.)
- Coerência posicional = valores brutos 0–100 (sem clamp) + no máximo 4 linhas com `%` + pelo menos 2 valores. Painel rotulado continua aceito com qualquer número de linhas.
- Origem do preço classificada por modelo distinto **depois** da agregação (`Pricing.priceSource`), sem tocar o agregado persistido. Limite: se o catálogo do models.dev mudar entre o scan e a leitura, a classificação segue o catálogo atual.
- O `~` do custo vale para o `ProviderCost` do popover e da barra. O Dashboard usa outro caminho (`CostScanner+Analytics`) e já se apresenta inteiro como estimativa ("dashboard.cost.caveat"); não recebeu marcador por família nesta story.
- Guarda do roster em `AccountRosterStore.captureIfIdentityChanged` (`AccountKey.isPlaceholder`): `live`/vazio → `.skipped`.

### Verificação
- `swift build --arch arm64` → Build complete.
- `Scripts/run-tests.sh` → 751 testes / 87 suítes verdes (baseline 737 / 85).

## File List
- `Sources/ClaudeBarCore/CLI/ClaudeStatusProbe.swift` (parser gated + `ClaudeUsageReading`)
- `Sources/ClaudeBarCore/Cost/Pricing.swift` (`PriceSource`, `fallbackSource`, `priceSource`)
- `Sources/ClaudeBarCore/Cost/CostScanner.swift` (contagem de tokens estimados)
- `Sources/ClaudeBarCore/Model/ProviderCost.swift` (`estimatedTokens`, `estimatedShare`, `isEstimated`)
- `Sources/ClaudeBarCore/Model/AccountIdentity.swift` (`isPlaceholder`)
- `Sources/ClaudeBarCore/Accounts/AccountRosterStore.swift` (guarda)
- `Sources/ClaudeBar/App/DisplaySnapshot.swift` (`isApproximate`)
- `Sources/ClaudeBar/StatusItem/MenuBarContentText.swift`, `MenuBarDisplayText.swift`, `StatusItemController.swift`
- `Sources/ClaudeBar/Popover/MetricRow.swift`, `UsageCardView.swift` (`PopoverCostSection`, cabeçalho "Barra mostra")
- `Sources/ClaudeBar/Resources/{en,pt-BR}.lproj/Localizable.strings`
- `Tests/ClaudeBarCoreTests/NumberProvenanceTests.swift`, `Tests/ClaudeBarTests/NumberProvenanceUITests.swift`

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada a partir do escopo v2.8 aprovado pelo dono | @dev (Dex) |
| 2026-11-25 | Implementada, Done | @dev (Dex) |
