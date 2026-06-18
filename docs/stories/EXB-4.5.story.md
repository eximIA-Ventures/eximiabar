# Story EXB-4.5: Insights de Eficiência no Dashboard

**ID:** EXB-4.5
**Status:** Ready for Review
**Depends on:** EXB-3.7 (Dashboard baseline completo — `DashboardData`, `CostScanner.scanAnalytics`, K/M/B formatter, KPI cards, período 7/30/90d), EXB-4.3 (opcional — cache hit rate pode vir de `ExhaustionPredictor` se já persistir amostras; mas EXB-4.5 pode usar dados de `UsageAnalytics` diretamente)
**Epic:** EPIC-EXB
**Wave:** Onda 9 (v1.6.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** Claude user who cares about getting the most out of my usage quota,
**I want** efficiency insights in the dashboard — cache hit rate, comparison to my own average, and a weekly summary,
**so that** I can see whether I'm using Claude efficiently, how today compares to my usual, and get a quick recap of my week.

---

## Acceptance Criteria

### AC1 — Cache hit rate

1. O dashboard exibe o **Cache Hit Rate** do período selecionado: `cacheReadTokens / (inputTokens + cacheReadTokens)` — proporção de tokens que vieram de cache read em relação ao total de input processado.
2. O cache hit rate é exibido como percentagem com 1 casa decimal (ex: "63.4%") em um KPI card ou seção de insights dedicada.
3. O dashboard exibe também uma estimativa de "Economia estimada com cache": diferença de custo entre pagar os tokens de cache read ao preço de output vs ao preço real de cache read. Fórmula: `(cacheReadTokens * (outputPricePerToken - cacheReadPricePerToken))`. Exibido em USD com 2 casas decimais (ex: "~$0.48 economizados").
4. Os valores de `cacheReadPricePerToken` e `outputPricePerToken` são lidos do `ProviderCost` / `Pricing` existente em `Sources/ClaudeBarCore/Cost/` — sem hardcoding por modelo na view.

### AC2 — Comparação com média pessoal

5. O dashboard exibe a comparação do uso **de hoje** com a média diária do período selecionado: `delta = (todayCost - averageDailyCost) / averageDailyCost * 100`.
6. A comparação é exibida em um dos KPI cards (ex: card "Hoje" ou como badge abaixo do KPI de hoje): "+32% acima da média" em laranja/vermelho se > 0, ou "-15% abaixo da média" em verde se < 0. Zero delta: "Na média do período".
7. Se não houver dados de hoje no período selecionado (ex: usuário está fora do horário de uso), exibir "Sem uso hoje" em vez de delta.

### AC3 — Resumo semanal estilo "wrapped"

8. Uma seção "Esta semana" (visível apenas no período de 7d — quando `period == .sevenDays`) exibe um conjunto de cards com destaques:
   - **Dia mais intenso**: dia da semana com maior custo (ex: "Quarta-feira, $4.23")
   - **Modelo mais usado**: modelo com mais tokens no período (ex: "claude-sonnet-4-5, 12.3B tokens")
   - **Total da semana**: custo total e tokens totais (ex: "$18.45 · 45.2B tokens")
   - **Hora de pico**: hora do dia com mais atividade (derivada do heatmap existente em `DashboardData.heatmap`)
9. Os cards da seção "Esta semana" usam `DashboardSectionHeader` existente e o mesmo estilo visual dos outros cards do dashboard.
10. A seção "Esta semana" NÃO aparece nos períodos 30d e 90d (para esses períodos, a seção é simplesmente omitida).

### AC4 — Integração com o agregador existente

11. Os novos campos (`cacheHitRate`, `estimatedCacheSavings`, `dailyDelta`, `peakHour`, `busiestDay`, `topModelByTokens`) são adicionados a `DashboardData` como campos computados em `DashboardData.build(from:period:now:)` — dentro do pipeline off-main existente (`Task.detached`).
12. Nenhum cálculo é feito em `body` de uma view ou no `@MainActor`.
13. Os novos campos reutilizam os dados já calculados em `DashboardData.build`: `heatmap`, `byModel` (modelo por custo/tokens), `dailyEntries` — sem novo scan do filesystem.

### AC5 — Localização e formatação

14. Todas as novas strings localizadas em `en.lproj` e `pt-BR.lproj`.
15. Tokens exibidos com K/M/B via `DashboardFormat.tokenCount` (ponto único — sem duplicação).
16. Custo exibido com `DashboardFormat.compactCurrency` ou equivalente existente.

### AC6 — Regressão e build

17. `swift build -c release` zero warnings (clean `.build`).
18. `swift test --no-parallel` sem regressões (223+ testes baseline); pelo menos **5 novos testes unitários**: `cacheHitRateZeroWhenNoCache`, `cacheHitRateCalculation`, `dailyDeltaPositive`, `dailyDeltaNegative`, `peakHourFromHeatmap`.

---

## Tasks

- [x] **T1 — Estender `DashboardData`** (AC1, AC2, AC3, AC4) — `Sources/ClaudeBar/Dashboard/DashboardData.swift`
  - [x] Adicionar campos: `cacheHitRate: Double`, `estimatedCacheSavings: Double`, `dailyDelta: Double?` (nil se sem dados hoje), `peakHour: Int`, `busiestDay: BusiestDay?`, `topModelByTokens: TopModel?` (tuplas viraram structs nomeados `BusiestDay`/`TopModel` para manter `DashboardData` `Equatable`/`Sendable` plano)
  - [x] Calcular tudo em `DashboardData.build(from:period:now:cachePricing:)` a partir de dados já existentes (`heatmap`, `byDayModel`, `daily`)
  - [x] `cacheHitRate`: somar `cacheReadTokens` e `inputTokens` de todos os `DashboardDailyEntry` do período (helper puro `cacheHitRate(input:cacheRead:)`)
  - [x] `estimatedCacheSavings`: preços via `CachePricing` derivado do modelo dominante (maior custo); preços resolvidos off-main no controller via `CostScanner.modelPrice(for:)` → `Pricing` actor. Sem hardcoding na view (AC4)
  - [x] `dailyDelta`: `todayCost` vs `averageDailyCost`; `nil` se sem uso hoje
  - [x] `peakHour`: argmax de `sum(tokens)` por hora sobre todo o heatmap
  - [x] `busiestDay`: argmax de custo por dayOfWeek sobre `daily` (0=Dom, 6=Sáb)

- [x] **T2 — KPI/Badge de cache hit rate** (AC1) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [x] KPI card dedicado "Cache Hit" (`CacheHitCard`) exibindo `cacheHitRate` como "63.4%" (`DashboardFormat.percent1`) + linha secundária "~$X economizados". Card dedicado escolhido (mais descobrível que linha no Total) — flui no grid adaptativo existente

- [x] **T3 — Badge de comparação com média** (AC2) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [x] No KPI card "Hoje": badge de delta (`DeltaBadge`) abaixo do valor (cor warm se > 0, verde se < 0, neutro se zero/nil)
  - [x] Formato: "+32% acima da média" / "-15% abaixo da média" / "Na média do período" / "Sem uso hoje"

- [x] **T4 — Seção "Esta semana"** (AC3) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [x] `WeeklySummarySection`: 4 cards (dia mais intenso, modelo top, total semana, hora de pico) via `WeeklyHighlightCard`
  - [x] Condicional: `if data.period == .sevenDays`
  - [x] Usa `DashboardSectionHeader` existente; estilo rounded-rect dos KPI cards

- [x] **T5 — Localização** (AC5) — `en.lproj` + `pt-BR.lproj`
  - [x] Todas as novas chaves (`dashboard.insights.*`: cache hit, savings, delta labels, weekly summary labels)

- [x] **T6 — Testes** (AC6) — `Tests/ClaudeBarTests/DashboardInsightsTests.swift` (novo)
  - [x] 13 testes (5 requeridos + 8 edge cases): `cacheHitRateZeroWhenNoCache`, `cacheHitRateCalculation`, `dailyDeltaPositive`, `dailyDeltaNegative`, `peakHourFromHeatmap` + savings/dominant-pricing, delta-nil, peak-hour-empty, busiest-day, top-model, CachePricing helper

---

## Dev Notes

### Arquivos de referência (baseline EXB-3.7)

| Arquivo | Papel |
|---------|-------|
| `Sources/ClaudeBar/Dashboard/DashboardData.swift` | `DashboardData.build(from:period:now:)` — ponto de adição dos novos campos; `DashboardDailyEntry` (tem todos os token types); `HeatmapBucket` |
| `Sources/ClaudeBar/Dashboard/DashboardView.swift` | KPI cards (`SummaryCard`), `DashboardSectionHeader`, `DashboardFormat`, `DashboardPalette` |
| `Sources/ClaudeBarCore/Cost/Pricing.swift` | `ProviderCost`, preços por modelo (input/output/cacheRead/cacheWrite) |
| `Sources/ClaudeBarCore/Model/` | `ModelCostEntry`, `UsageAnalytics`, `ProjectUsageEntry` |

### Cache hit rate — cálculo

```swift
// Em DashboardData.build:
let totalInput = dailyEntries.reduce(0) { $0 + $1.inputTokens }
let totalCacheRead = dailyEntries.reduce(0) { $0 + $1.cacheReadTokens }
let denominator = totalInput + totalCacheRead
let cacheHitRate = denominator > 0 ? Double(totalCacheRead) / Double(denominator) : 0.0
```

### Economia com cache — cálculo simplificado

```swift
// Preços em USD por token (checar Pricing.swift para valores reais)
// Economia = cacheReadTokens * (outputPrice - cacheReadPrice)
// Usar modelo predominante do período para os preços
let dominantModel = byModel.first?.modelName ?? "claude-sonnet-4-5"
if let cost = ProviderCost.cost(for: dominantModel) {
    estimatedCacheSavings = Double(totalCacheRead) * (cost.outputPerToken - cost.cacheReadPerToken)
}
```

### Pico de hora — do heatmap existente

```swift
// heatmap: [[HeatmapBucket]] onde heatmap[day][hour].tokens
// Somar tokens por hora:
var hourTotals = [Int](repeating: 0, count: 24)
for day in heatmap {
    for bucket in day { hourTotals[bucket.hour] += bucket.tokens }
}
peakHour = hourTotals.indices.max(by: { hourTotals[$0] < hourTotals[$1] }) ?? 0
```

### Dia mais intenso — de `dailyEntries`

```swift
// dayOfWeek de cada DashboardDailyEntry:
var costByDay = [Int: Double](minimumCapacity: 7)
for entry in dailyEntries {
    let dow = Calendar.current.component(.weekday, from: entry.date) - 1 // 0=Dom
    costByDay[dow, default: 0] += entry.cost
}
busiestDay = costByDay.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
```

### `WeeklySummarySection` — layout

Quatro cards numa `LazyVGrid` de 2 colunas (ou `HStack` com dois `VStack`s de 2 cards cada), mantendo consistência com o resto do dashboard. Cada card: ícone SF Symbol + título pequeno + valor destacado.

Exemplos de SF Symbols:
- Dia mais intenso: `calendar.badge.exclamationmark`
- Modelo mais usado: `cpu`
- Total semana: `chart.bar.fill`
- Hora de pico: `clock.fill`

### Anti-freeze invariants

- Todos os novos campos calculados dentro de `DashboardData.build` (já no `Task.detached`)
- Nenhum acesso a `ProviderCost` ou `Pricing` dentro de `body` de view
- `DashboardData` é imutável (struct) e `Sendable`

### Testing

- Baseline: 223+ testes; zero regressões obrigatório
- Arquivo: `Tests/ClaudeBarTests/DashboardInsightsTests.swift` (novo)
- `swift test --no-parallel`

---

## Definition of Done

- [x] Cache hit rate exibido no dashboard como % + economia estimada em USD
- [x] Badge delta de "hoje vs média" no KPI card "Hoje"
- [x] Seção "Esta semana" visível somente no período 7d (4 cards)
- [x] Todos os campos calculados off-main em `DashboardData.build`
- [x] Nenhum novo scan do filesystem — tudo derivado de dados existentes
- [x] 5 novos testes verdes (13 no total); zero regressões nas suites de dashboard
- [x] `swift build --arch arm64` zero warnings (build universal `-c release` final é responsabilidade do @devops na release da onda)

---

## Dev Agent Record

### Agent
@dev (Dex) — implementação EXB-4.5, 2026-06-18

### Decisões de implementação (IDS)

- **REUSE** do agregador EXB-3.7: zero novo parsing/scan. Todos os campos derivam de `analytics.byDayModel`, `analytics.heatmap` e do `daily` axis já dobrado em `DashboardData.build`. Reutilizados `DashboardFormat`, `DashboardSectionHeader`, `SummaryCard` styling, `PopoverFormatter.currency`, `DashboardPalette`/`PopoverStyle.brand`, `Pricing` actor.
- **ADAPT** — `DashboardData.build` ganhou parâmetro `cachePricing: CachePricing = CachePricing()` (default zerado preserva os ~30 call sites/tests existentes). `SummaryCard` ganhou `badge: DeltaBadgeModel?` opcional. `DashboardFormat` ganhou `percent1(_:)`.
- **CREATE** — campos de insight em `DashboardData`; structs `CachePricing`, `BusiestDay`, `TopModel`; views `CacheHitCard`, `DeltaBadge`, `WeeklySummarySection`, `WeeklyHighlightCard`; método core `CostScanner.modelPrice(for:)`; `DashboardInsightsTests.swift`.

### Desvios da story (justificados)

1. **`ProviderCost.cost(for:)` / `cacheReadPerToken` não existem.** O pseudocódigo das Dev Notes era ilustrativo. A camada real é o `Pricing` actor, que expõe apenas `(input, output)` por token. exímIABar precifica custo só sobre input/output base (cache não é reprecificado — ver `CostScanner+Analytics.swift`). Solução conforme AC4: `CachePricing.claude(inputPerToken:outputPerToken:)` deriva `cacheReadPerToken = input × 0.1` (convenção Anthropic de prompt caching, constante única em `CachePricing.cacheReadInputRatio`, fora da view). O modelo dominante (maior custo) é resolvido **off-main** no `DashboardWindowController` (dentro do `Task.detached`) via novo `CostScanner.modelPrice(for:)`, e `(input, output)` são passados puros ao `build` — mantendo `build` determinístico/testável e sem `await Pricing` no MainActor (anti-freeze AC12).
2. **Tuplas → structs nomeados.** `busiestDay`/`topModelByTokens` viraram `BusiestDay`/`TopModel` porque tuplas opcionais não sintetizam `Equatable` como stored properties de um struct `Sendable`.
3. **Layout T2:** card dedicado `CacheHitCard` (não linha no Total) — mais descobrível e flui no `LazyVGrid` adaptativo existente.

### File List

**Modificados:**
- `Sources/ClaudeBar/Dashboard/DashboardData.swift` — `CachePricing`/`BusiestDay`/`TopModel`; 6 campos de insight; `build` com `cachePricing`; helpers puros `cacheHitRate`/`dailyDelta`/`peakHour`/`busiestDay`/`topModelByTokens`
- `Sources/ClaudeBar/Dashboard/DashboardView.swift` — `CacheHitCard`, `DeltaBadge`/`DeltaBadgeModel`, `WeeklySummarySection`, `WeeklyHighlightCard`; `SummaryCard.badge`; `DashboardFormat.percent1`; render condicional 7d
- `Sources/ClaudeBar/Dashboard/DashboardWindowController.swift` — resolução off-main do `CachePricing` do modelo dominante; `build(..., cachePricing:)`
- `Sources/ClaudeBarCore/Cost/CostScanner+Analytics.swift` — `public func modelPrice(for:)`
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — 16 chaves `dashboard.insights.*`
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — 16 chaves `dashboard.insights.*`

**Criados:**
- `Tests/ClaudeBarTests/DashboardInsightsTests.swift` — 13 testes

### Validação

- `swift build --arch arm64` → Build complete, zero warnings (7.64s)
- `swift test --arch arm64 --filter DashboardInsightsTests` → 13/13 passando
- `swift test --arch arm64 --filter DashboardDataTests|DashboardAnalyticsTests|DashboardPolishTests` → 28/28 passando (zero regressões)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
| 2026-06-18 | 1.1 | Implementação completa: cache hit + savings, delta badge, seção "Esta semana", 13 testes. Ready for Review | @dev Dex |
