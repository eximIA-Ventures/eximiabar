# Story EXB-4.5: Insights de Eficiência no Dashboard

**ID:** EXB-4.5
**Status:** Draft
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

- [ ] **T1 — Estender `DashboardData`** (AC1, AC2, AC3, AC4) — `Sources/ClaudeBar/Dashboard/DashboardData.swift`
  - [ ] Adicionar campos: `cacheHitRate: Double`, `estimatedCacheSavings: Double`, `dailyDelta: Double?` (nil se sem dados hoje), `peakHour: Int`, `busiestDay: (dayOfWeek: Int, cost: Double)?`, `topModelByTokens: (name: String, tokens: Int)?`
  - [ ] Calcular tudo em `DashboardData.build(from:period:now:)` a partir de dados já existentes (`heatmap`, `byModel`, `dailyEntries`, `UsageAnalytics.entries`)
  - [ ] `cacheHitRate`: somar `cacheReadTokens` e `inputTokens` de todos os `DashboardDailyEntry` do período
  - [ ] `estimatedCacheSavings`: buscar preços via `ProviderCost` — aceitar que preços podem variar por modelo; usar preço médio ponderado ou preço do modelo dominante
  - [ ] `dailyDelta`: `dailyEntries` do dia atual vs `averageDailyCost`; se não há entrada de hoje, `nil`
  - [ ] `peakHour`: argmax de `sum(tokens)` por hora sobre todo o heatmap
  - [ ] `busiestDay`: argmax de custo por dayOfWeek sobre `dailyEntries` (0=Dom, 6=Sáb)

- [ ] **T2 — KPI/Badge de cache hit rate** (AC1) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [ ] Adicionar KPI card "Cache Hit" exibindo `cacheHitRate` como "63.4%" + linha secundária "~$0.48 economizados"
  - [ ] Ou integrar como linha adicional no card "Total" existente (decisão de layout — documentar como nota)

- [ ] **T3 — Badge de comparação com média** (AC2) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [ ] No KPI card "Hoje": adicionar badge de delta abaixo do valor (texto + cor: vermelho se > 0, verde se < 0, neutro se zero/nil)
  - [ ] Formato: "+32% acima da média" / "-15% abaixo da média" / "Na média" / "Sem uso hoje"

- [ ] **T4 — Seção "Esta semana"** (AC3) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [ ] `WeeklySummarySection`: 4 cards (dia mais intenso, modelo top, total semana, hora de pico)
  - [ ] Condicional: `if data.period == .sevenDays`
  - [ ] Usar `DashboardSectionHeader` existente; estilos dos KPI cards existentes

- [ ] **T5 — Localização** (AC5) — `en.lproj` + `pt-BR.lproj`
  - [ ] Todas as novas chaves (cache hit, savings, delta labels, weekly summary labels)

- [ ] **T6 — Testes** (AC6) — `Tests/ClaudeBarTests/`
  - [ ] `DashboardInsightsTests.swift` (novo) ou adicionar a `DashboardDataTests.swift`
  - [ ] 5+ testes (AC6)

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

- [ ] Cache hit rate exibido no dashboard como % + economia estimada em USD
- [ ] Badge delta de "hoje vs média" no KPI card "Hoje"
- [ ] Seção "Esta semana" visível somente no período 7d (4 cards)
- [ ] Todos os campos calculados off-main em `DashboardData.build`
- [ ] Nenhum novo scan do filesystem — tudo derivado de dados existentes
- [ ] 5 novos testes verdes; zero regressões
- [ ] `swift build -c release` zero warnings

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
