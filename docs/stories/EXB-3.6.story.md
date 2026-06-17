# Story EXB-3.6: Dashboard — Filtros, Performance e Completude Visual

**ID:** EXB-3.6
**Status:** InReview
**Depends on:** EXB-3.2 (Dashboard Analytics v2 — periodo picker, DashboardModel, charts baseline), EXB-3.1 (SettingsStore com TransparencyLevel)
**Epic:** EPIC-EXB
**Wave:** Onda 6 (v1.3.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** user who relies on the dashboard to track my Claude usage,
**I want** period filters that actually change what I see, a UI that never stutters when switching periods, and charts with proper legends, axis labels, hover values, and empty states,
**so that** the dashboard is a trustworthy, fast, and visually complete analytics tool.

---

## Acceptance Criteria

### BUG 1 — Filtros de período não funcionam

1. Trocar o segmented control `7d / 30d / 90d` altera visivelmente os dados de **todos** os gráficos e KPIs sem reabrir a janela.
2. Teste unitário cobrindo `DashboardData.build` com cada período (7/30/90) retornando contagens de dias distintas — i.e., dados de 90 dias NÃO são idênticos aos de 7 dias quando as entradas cobrem janelas diferentes.

**Investigação obrigatória (raiz do bug — o dev DEVE confirmar qual causa está ativa antes de codificar a fix):**
- `DashboardModel.period` é `@Observable`? A mudança do Picker está bindada a ele ou a uma cópia local?
- `DashboardWindowController.loadData` é disparado quando `period` muda? Ou está chamado apenas no `windowDidLoad`?
- `DashboardData.build(from:period:)` usa o parâmetro `period` para filtrar `UsageAnalytics.entries`? Ou aplica sempre a janela de 30d ignorando o parâmetro?
- O cache incremental (`[DashboardPeriod: (data, scannedAt)]`) é invalidado ao mudar de período, ou serve dados estale do período anterior?

### BUG 2 — Travamento ao abrir/trocar período

3. Abrir o dashboard e trocar qualquer período NÃO bloqueia a UI: a janela exibe um estado de loading (progress indicator ou texto "Carregando…") enquanto os dados são computados em background.
4. A agregação completa (`CostScanner.scanAnalytics`, `DashboardData.build`) corre em `Task.detached(priority: .utility)` fora da MainActor; nenhum desses caminhos é chamado diretamente no body SwiftUI ou no `@MainActor`.
5. O resultado da agregação por período é cacheado em memória (`[DashboardPeriod: DashboardData]`); um segundo acesso ao mesmo período não dispara novo scan.
6. Formatters (`DateFormatter`, `NumberFormatter`) são instâncias **estáticas** (ou do tipo `@MainActor` compartilhado por toda a view) — nunca criados dentro de `body` ou dentro de loops de chart.
7. Cada série de gráfico (`CostPerDayChart`, `StackedTokensChart`, `ActivityHeatmapChart`) contém no máximo **~100 pontos** por série por chart. Para janelas de 90d com granularidade diária isso é atendido naturalmente (90 pontos); o heatmap 7×24 = 168 células é aceitável. Qualquer futura granularidade sub-diária DEVE aplicar downsampling/bucketing antes de passar os dados ao `Chart`.
8. Os caminhos pesados do dashboard estão instrumentados com `os_signpost` (categoria `"DashboardPerf"`, pelo menos: início/fim do `scanAnalytics`, início/fim do `DashboardData.build`, apply no MainActor).

### MELHORIA 3 — Gráficos e legendas mais completos

9. Todo chart com múltiplas séries (custo acumulado, tokens empilhado, heatmap) exibe **legenda visível** via `.chartLegend(.visible)` ou legenda customizada inline.
10. Eixos formatados:
    - Custo (USD): exibido como `$0.00` para valores < $1 e `$X.XXK` para >= $1000 via `AxisValueLabel`.
    - Tokens: exibido como `XK` (milhares) ou `XM` (milhões) via `AxisValueLabel`.
    - Datas no eixo X: formato `dd/MM` via `AxisValueLabel` com `Date.FormatStyle`.
11. Hover / seleção em charts: ao clicar ou hover em um ponto/barra, um overlay (`.chartOverlay` + `annotation`) exibe o valor exato (custo com 4 casas decimais, tokens, data).
12. Escala de cores por modelo **consistente entre gráficos**: o mesmo modelo tem a mesma cor no donut, na tabela e no gráfico de tokens empilhado. Usar `chartForegroundStyleScale(domain:range:)` com um dicionário fixo de modelos→cores, derivado dos dados do período ao abrir a janela.
13. Cada seção do dashboard tem **título** (e.g., "Custo por Dia", "Tokens por Tipo", "Heatmap de Atividade") e **subtítulo** com o intervalo de datas do período selecionado (e.g., "01/06 – 12/06").
14. Cada card de gráfico exibe o **total do período** como número de destaque no topo do card (ex: "Total: $12.34" para custo, "Total: 1.2M tokens" para tokens).
15. **Empty states**: quando não há dados no período selecionado, cada chart/tabela exibe uma view elegante ("Sem dados no período" com ícone SF Symbol adequado) em vez de gráfico vazio ou erro.
16. Todas as novas strings localizadas em `en.lproj` e `pt-BR.lproj`.

---

## Tasks

- [x] **T0 — Diagnóstico e root cause do BUG 1** (AC1 pré-requisito) — ver Dev Notes › Diagnóstico
  - [x] Grep do controller/data/view — wiring confirmado **correto**
  - [x] Filtro de data confirmado **correto** (`isWithinWindow`); BUG 1 não é de dados
  - [x] Binding do Picker confirmado correto (`Binding(get:set:)` → `model.selectPeriod`)
  - [x] Causa raiz documentada nos Dev Notes (probe empírico com dados reais)

- [x] **T1 — Fix: wiring do picker ao DashboardModel** (AC1) — wiring já estava correto; fix real foi o loading state (T3)
  - [x] `Picker` já bindado a `model.period` via `selectPeriod`
  - [x] `selectPeriod` já dispara `onPeriodChange` → `loadData(for:)`
  - [x] `@Observable DashboardModel` já propaga corretamente

- [x] **T2 — Fix: filtro de data em DashboardData.build** (AC1, AC2) — filtro já correto; testes adicionados
  - [x] `period.days` filtra via `isWithinWindow` em `scanAnalytics` (confirmado por probe: 7d=$413, 30d=$1622, 90d=$1876)
  - [x] Testes de período adicionados (`DashboardPeriodFilterTests.scanReturnsDistinctDataPerPeriod`)

- [x] **T3 — Fix: performance (main thread + formatters + signpost)** (AC3–AC8)
  - [x] `isRefreshing: Bool` em `DashboardModel` + `RefreshBanner` não-bloqueante no `DashboardView` (AC3) — **fix real do BUG 1**
  - [x] `loadData` já em `Task.detached(.utility)` + `apply` em `@MainActor`; auditado, nenhum path pesado na main (AC4)
  - [x] Cache `[DashboardPeriod: DashboardData]` checado antes do scan; ativo p/ todos os 3 períodos (AC5)
  - [x] **mtime pre-filter** adicionado em `scanAnalytics` — root cause do BUG 2 (ver Dev Notes); zero `DateFormatter()`/`NumberFormatter()` em `body` (AC6)
  - [x] Pontos por série documentados nos Dev Notes (AC7)
  - [x] 4 `os_signpost` (`OSSignposter`, categoria `DashboardPerf`): scanAnalytics, makeAnalytics, DashboardData.build, applyOnMain (AC8)

- [x] **T4 — Legendas e eixos** (AC9, AC10)
  - [x] `.chartLegend(.visible)` em cost / tokens / heatmap
  - [x] Eixo Y custo: `DashboardFormat.axisCurrency` (`$0.00` / `$X.XK`)
  - [x] Eixo Y tokens: `DashboardFormat.axisTokens` (`XK`/`XM`)
  - [x] Eixo X datas: `DashboardFormat.dayMonth` (`dd/MM`)

- [x] **T5 — Hover/annotation** (AC11)
  - [x] `CostPerDayChart`: `.chartOverlay` + `onContinuousHover` + `RuleMark.annotation` com custo 4 casas + tokens
  - [~] `StackedTokensChart`: hover não aplicado (desvio justificado — ver Dev Notes); AC11 exige "pelo menos CostPerDayChart"

- [x] **T6 — Escala de cores consistente** (AC12)
  - [x] `DashboardPalette` ramp estável + `sortedModelNames` (ordem por custo)
  - [x] `ModelCostDonut` e `ModelBreakdownTable` (swatch) compartilham a mesma escala
  - [x] `chartForegroundStyleScale(domain:range:)` no donut

- [x] **T7 — Títulos, subtítulos e totais por card** (AC13, AC14)
  - [x] `DashboardSectionHeader`: título `.headline` + subtítulo de range `dd/MM – dd/MM`
  - [x] Total do período no header de cada card de chart (`dashboard.total.cost` / `dashboard.total.tokens`)

- [x] **T8 — Empty states** (AC15)
  - [x] `ChartEmptyState` por chart quando o período não tem dados; SF Symbol por contexto (`chart.bar.xaxis`, `square.stack.3d.up`, `flame`)

- [x] **T9 — Localização** (AC16)
  - [x] Novas chaves em `en.lproj` e `pt-BR.lproj` (`loading.message`, `empty.period`, `total.cost`, `total.tokens`)
  - [x] Títulos, subtítulos, empty states e labels todos via `L(...)`

- [x] **T10 — Testes unitários** (AC2 + regressão)
  - [x] `DashboardPeriodFilterTests.swift` (período distinto + mtime floor + stale-skip) + totais/cores em `DashboardDataTests`
  - [x] `swift test` 207 testes (201 baseline + 6 novos); sem regressões (flakes pré-existentes documentados)
  - [x] `swift build -c release` zero warnings

---

## Dev Notes

### Contexto de estado do código (EXB-3.2 como baseline)

O dashboard foi implementado em EXB-3.2 (InReview QA PASS) com os seguintes arquivos relevantes:

**Núcleo do problema — rastrear a cadeia:**
```
DashboardView.swift        → Picker de período → DashboardModel.period
DashboardWindowController  → DashboardModel (@Observable) + loadData(for:)
DashboardData.swift        → build(from: UsageAnalytics, period: DashboardPeriod, now: Date)
CostScanner+Analytics.swift → scanAnalytics(...) → UsageAnalytics (entries com timestamps)
DashboardPeriod.swift      → enum 7d/30d/90d com var windowDays: Int
```

A fix do BUG 1 DEVE garantir que `DashboardData.build` filtra `UsageAnalytics.entries` por `Date.now - period.windowDays` dias. Inspecionar `DashboardData.swift` em busca de `windowDays` ou `period` no método `build` — se estiver hardcoded como `30` ou ausente, essa é a causa raiz.

### Padrão de async seguro (EXB-3.2 + epic anti-freeze)

```swift
// Em DashboardWindowController:
func loadData(for period: DashboardPeriod) {
    model.isLoading = true
    scanTask?.cancel()
    scanTask = Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        let analytics = await CostScanner.shared.scanAnalytics(...)
        let data = DashboardData.build(from: analytics, period: period, now: .now)
        guard !Task.isCancelled, data.period == period else { return }
        await MainActor.run {
            self.model.data = data
            self.model.isLoading = false
        }
    }
}
```

O padrão de cancelação + guard `data.period == period` já existe em EXB-3.2 (`DashboardWindowController.swift:139,154`). Verificar se está funcionando para todos os 3 períodos.

### os_signpost (AC8)

```swift
import os.log
private let log = OSLog(subsystem: "com.eximia.eximiabar", category: "DashboardPerf")
private let signposter = OSSignposter(logHandle: log)

// Uso:
let id = signposter.makeSignpostID()
let state = signposter.beginInterval("scanAnalytics", id: id)
defer { signposter.endInterval("scanAnalytics", state) }
```

### Formatters estáticos (AC6)

```swift
// NUNCA dentro de body ou chart closure:
// ❌ Text(DateFormatter().string(from: date))

// CORRETO — static let fora de body:
private static let dayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "dd/MM"; return f
}()
```

### Swift Charts — hover overlay (AC11)

```swift
Chart { ... }
.chartOverlay { proxy in
    GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase,
                   let date: Date = proxy.value(atX: location.x) {
                    selectedDate = date
                }
            }
    }
}
.chartBackground { proxy in
    if let selectedDate, let cost = data.cost(for: selectedDate) {
        // annotation view
    }
}
```

### Empty state pattern

```swift
@ViewBuilder
private func chartOrEmpty<C: View>(_ isEmpty: Bool, empty icon: String, _ key: LocalizedStringKey, @ViewBuilder chart: () -> C) -> some View {
    if isEmpty {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(key).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 120)
    } else {
        chart()
    }
}
```

### Source tree esperado

**Modificados:**
- `Sources/ClaudeBar/Dashboard/DashboardData.swift` — fix filtro de período; modelColorMap; totalForPeriod
- `Sources/ClaudeBar/Dashboard/DashboardView.swift` — legendas; eixos; hover; títulos/subtítulos; empty states; totais por card
- `Sources/ClaudeBar/Dashboard/DashboardWindowController.swift` — isLoading state; signposts; audit async
- `Sources/ClaudeBarCore/Cost/CostScanner+Analytics.swift` — signposts
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — novas chaves
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — novas chaves

**Possivelmente novo:**
- `Tests/ClaudeBarCoreTests/DashboardPeriodFilterTests.swift` (ou adicionar a `CostScannerAnalyticsTests`)

### Anti-freeze invariants (transversais)

Todos os princípios do epic se aplicam:
- ZERO I/O ou agregação na main thread
- Formatters estáticos (nunca em `body`)
- `Chart` com dados pré-computados, não computados dentro da view
- Cache `[DashboardPeriod: DashboardData]` acessado apenas em `@MainActor`

### Testing

- Framework: Swift Testing ou XCTest (seguir padrão do repo — ver `Tests/ClaudeBarCoreTests/`)
- Testes de período mínimos (AC2): fixture com entries em datas dia 0, dia -15, dia -95 → assert contagens por período
- Baseline atual: 201 testes; zero regressões obrigatório
- `swift test` (serial: `--no-parallel` para evitar flake de keychain)
- `swift build -c release` zero warnings

---

---

## Diagnóstico (T0 — root cause empírico, antes de qualquer edição)

Reproduzido contra os JSONL reais da máquina (`~/.claude/projects`: 21 projetos, **1949 arquivos, 1.1 GB**). Probe temporário mediu `scanAnalytics` para 7/30/90 dias.

### Probe pré-fix (smoking gun)

```
window=7d   elapsed=21.976s  rows=16  cost=$413.97   tokens=9.3M
window=30d  elapsed=22.388s  rows=58  cost=$1622.23  tokens=39.2M
window=90d  elapsed=22.983s  rows=78  cost=$1876.80  tokens=44.2M
```

### BUG 1 — "filtros não funcionam": **não é bug de dados**

O wiring (Picker → `selectPeriod` → `onPeriodChange` → `loadData`) e o filtro (`CostScanner.isWithinWindow` em `scanAnalytics`) estavam **corretos**. O probe prova que os 3 períodos retornam dados genuinamente distintos ($413 vs $1622 vs $1876). A causa raiz do sintoma de produção:

- Cada scan leva **~22 segundos**. Em `loadData`, ao trocar de período com conteúdo na tela, o código mantinha o `state == .loaded` **antigo** sem indicador de loading (`if case .loaded = model.state {}` → no-op). Durante 22 s o usuário vê os gráficos do período anterior, congelados, sem feedback → lê como "o filtro não fez nada / travou".
- **Fix:** flag `isRefreshing` no `DashboardModel` + `RefreshBanner` flutuante não-bloqueante (AC3). O picker agora dá feedback imediato; ao concluir, os gráficos trocam visivelmente.

### BUG 2 — travamento: **scan lê 1 GB inteiro toda vez**

Raiz: `scanAnalytics` enumera e faz `JSONSerialization` linha-a-linha de **todos os 1949 arquivos**, e só então descarta as linhas fora da janela (`isWithinWindow` roda *depois* do parse). O filtro de janela quase não muda o tempo (7d≈22.0s, 90d≈23.0s) porque o custo é o I/O+parse de 1 GB, não o número de linhas in-window.

Distribuição por mtime (validação da hipótese):

| Janela | Arquivos que *podem* ter dados in-window | Total | Bytes lidos hoje |
|--------|------------------------------------------|-------|------------------|
| 7d  | 285 (100 MB) | 1949 (1 GB) | **10× a mais que o necessário** |
| 30d | 1858 | 1949 | — |
| 90d | 1949 | 1949 | (máquina muito usada) |

- **Fix:** **mtime pre-filter** em `analyticsJSONLFiles`. Um arquivo cuja `contentModificationDate` é anterior ao piso da janela (`windowFileFloor` = início do 1º dia − 1 dia de folga) não pode conter nenhuma entrada in-window, então é **pulado sem abrir FileHandle**. Fail-open se mtime ausente.
- **Probe pós-fix:** `7d 21.9s → 9.2s` (~2.4× mais rápido, pula ~85% dos arquivos). 30d/90d permanecem I/O-bound em ~1 GB (a máquina é muito ativa, quase tudo é recente) — variam com o page cache do SO. O que garante AC3/AC4 nesses casos é a arquitetura: scan **off-MainActor** + banner de loading + cache por período (o custo é pago **uma vez por período por abertura**, não a cada interação).

### Contagem de pontos por série (AC7)

| Chart | Pontos por série @ 90d | Limite | OK? |
|-------|------------------------|--------|-----|
| CostPerDayChart (barras) | 90 | ~100 | ✅ |
| CostPerDayChart (linha acumulada) | 90 | ~100 | ✅ |
| StackedTokensChart (por token type) | 90 | ~100 | ✅ (4 séries × 90) |
| ActivityHeatmapChart | 168 células (7×24) | aceito pela AC | ✅ |

Granularidade diária mantém ≤ 100 pts/série naturalmente. Sub-diária futura exigiria bucketing (documentado, não necessário agora).

---

## File List

**Modificados:**
- `Sources/ClaudeBarCore/Cost/CostScanner+Analytics.swift` — mtime pre-filter (`windowFileFloor`, `AnalyticsFile`, `analyticsJSONLFiles(in:window:now:)`); `OSSignposter perfSignposter` (categoria `DashboardPerf`); 2 intervalos de signpost + 1 evento
- `Sources/ClaudeBar/Dashboard/DashboardWindowController.swift` — `isRefreshing` no `DashboardModel`; loading não-bloqueante ao trocar período; signpost `applyOnMain`; wiring de `isRefreshing` no `DashboardRoot`
- `Sources/ClaudeBar/Dashboard/DashboardData.swift` — `totalCost`/`totalTokens`/`totalHeatmapTokens` (AC14); `rangeStart`/`rangeEnd` (AC13); `sortedModelNames` (AC12); signpost `DashboardData.build`
- `Sources/ClaudeBar/Dashboard/DashboardView.swift` — `RefreshBanner` (AC3); `DashboardFormat` (formatters estáticos, AC6/AC10); `DashboardPalette` (AC12); `DashboardSectionHeader` (AC13/AC14); `ChartEmptyState` (AC15); refactor de cost/tokens/donut/table/heatmap para assinatura `data:`; hover/annotation no CostPerDayChart (AC11); eixos formatados (AC10); legendas (AC9)
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — `loading.message`, `empty.period`, `total.cost`, `total.tokens`
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — idem em pt-BR

**Novos:**
- `Tests/ClaudeBarCoreTests/DashboardPeriodFilterTests.swift` — período distinto (AC1/AC2), `windowFileFloor` (AC4), stale-file-skip
- (testes adicionados a `Tests/ClaudeBarTests/DashboardDataTests.swift` — totais AC14, ordem de cores AC12)

---

## Definition of Done

- [x] Trocar período no Picker altera visivelmente todos os KPIs e gráficos (BUG 1 corrigido — feedback + troca visível)
- [x] Testes unitários de filtro de período passando (7d/30d/90d retornam contagens distintas)
- [x] Abrir dashboard e trocar período nunca congela a UI (loading state visível) (BUG 2 corrigido — off-main + banner + mtime pre-filter)
- [x] Formatters estáticos — zero `DateFormatter()` / `NumberFormatter()` dentro de `body`
- [x] 4+ `os_signpost` instrumentando caminhos pesados (scanAnalytics, makeAnalytics, build, applyOnMain)
- [x] Todos os charts têm legenda visível
- [x] Eixos formatados: custo $, tokens K/M, datas dd/MM
- [x] Hover/annotation funciona em pelo menos CostPerDayChart
- [x] Cores de modelo consistentes entre donut e tabela
- [x] Títulos e subtítulos presentes em cada seção de chart
- [x] Totais do período visíveis em cada card de gráfico
- [x] Empty states elegantes para períodos sem dados
- [x] Strings localizadas en + pt-BR
- [x] `swift build -c release` zero warnings; `swift test` sem regressões (207 testes; flakes pré-existentes de timing documentados)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-12 | 1.0 | Initial draft — Onda 6 (v1.3.0) | @sm River |

---

## QA Results — rodada 1

**Gate:** @qa (Quinn) · **Date:** 2026-06-12 · **Criterion:** RESULT, not API-presence (queimados 2x).

### Build & Tests (RAN, not trusted)
- `swift build -c release` → **Build complete, 0 warnings, 0 errors** ✅
- `swift test --no-parallel` (serial, to dodge keychain flake) → **207 tests / 28 suites PASS** ✅ — no flake reproduced this run; the dev-noted `SettingsStoreTests.debouncedSaveCoalescesRapidMutations` timing flake did **not** fire serially. Baseline 201 + 6 new = 207.

### AC verification (file:line or FALTANDO)

| AC | Verdict | Evidence (result, not presence) |
|----|---------|--------------------------------|
| 1 — filter changes all charts/KPIs | ✅ | Chain traced live: `DashboardView.swift:114` Picker → `DashboardWindowController.swift:27` `selectPeriod` (guards `period != self.period`) → `:90` `onPeriodChange`→`loadData` → `:146` `scanAnalytics(windowDays:)` → `:148` `build(from:period:)` → `:168` `apply` with `guard data.period == model.period`. Connected end-to-end. |
| 2 — unit test: distinct counts per period | ✅ | `DashboardPeriodFilterTests.swift:73` proves **different data**: 7d=1 row/200 tok, 30d=2 rows/600 tok, 90d=2 rows/600 tok; explicit `week.count != quarter.count` and `totalTokens(week) != totalTokens(month)`. Not a stale repeat. |
| 3 — period switch never blocks UI | ✅ | `DashboardWindowController.swift:136-141` flips `isRefreshing` (keeps prior charts) when `.loaded`, else `.loading`; `DashboardView.swift:44-52` floats non-blocking `RefreshBanner`. |
| 4 — aggregation off-MainActor | ✅ | `scanAnalytics`+`build` invoked **only** inside `Task.detached(priority:.utility)` (`DashboardWindowController.swift:145-148`); grep confirms no other call site. `scanAnalytics` is actor-isolated, never `@MainActor`. |
| 5 — per-period in-memory cache | ✅ | `cache[period]` checked at `:127` before any scan; cache hit applies instantly with no re-scan. Fingerprint invalidation at `:162`. |
| 6 — static formatters, none in body | ✅ | All 4 formatter constructions are safe: `DashboardFormat.dayMonth` (`static let`, :144), `TopSessionsTable.dateFormatter` (`static let`, :767), `csvExport` ISO formatter (off-main `Task.detached`, :231), `fileDateTag` (one-shot NSSavePanel callback, :194). **Zero** inside any `body`. |
| 7 — ≤~100 pts/series + downsampling | ✅ (acceptable) | Daily granularity → 90d = 90 pts/series structurally; heatmap 168 cells explicitly accepted by AC. No sub-daily granularity exists, so no bucketing needed now; documented as future requirement (Dev Notes). |
| 8 — os_signpost on heavy paths | ✅ | `OSSignposter` category `DashboardPerf`: `scanAnalytics` interval (`CostScanner+Analytics.swift:32`), `makeAnalytics` (:51), `DashboardData.build` (`DashboardData.swift:130`), `applyOnMain` (`DashboardWindowController.swift:158`). 4 intervals + 1 event. |
| 9 — visible legend on multi-series | ✅ | `.chartLegend(.visible)` on cost (`:419`), tokens (`:545`), heatmap (`:757`). Donut `.hidden` (`:590`) is correct — its legend is the breakdown table. |
| 10 — formatted axes | ✅ | `axisCurrency` (`$X.XK`/`$X.XX`, :158), `axisTokens` (`XK`/`XM`, :166), `dayMonth` (`dd/MM`, :144) wired into `AxisValueLabel` on both charts. |
| 11 — hover overlay w/ exact value | ✅ | `CostPerDayChart` `.chartOverlay`+`onContinuousHover` (:420-435), plot-origin corrected (`location.x - origin.x`), `RuleMark.annotation` → `HoverAnnotation` with 4-decimal cost (`preciseCurrency`) + tokens. AC requires "≥ CostPerDayChart" — met. StackedTokens hover omitted (justified: 4-series stack has no single hover value). |
| 12 — consistent model→color | ✅ | `DashboardPalette.scale(for: sortedModelNames)` (stable cost-desc order) shared by donut `chartForegroundStyleScale` (:589) and table swatches (:600-603). `sortedModelNamesFollowCostDescending` test pins the order. |
| 13 — section title + date-range subtitle | ✅ | `DashboardSectionHeader` (:204) with `rangeSubtitle(rangeStart,rangeEnd)` on cost/tokens/models/heatmap. |
| 14 — per-card period total highlight | ✅ | `total:` arg on each header: `total.cost` (cost card), `total.tokens` (tokens + heatmap). `DashboardData.totalCost/totalTokens` summed; `periodTotalsSumTheWindow` test asserts 3.0 / 335. |
| 15 — empty states | ✅ | `ChartEmptyState` per chart gated on `hasData` with context SF Symbols (`chart.bar.xaxis`, `square.stack.3d.up`, `flame`). |
| 16 — localized en + pt-BR | ✅ | 4 new keys present in **both** bundles: `loading.message`, `empty.period`, `total.cost`, `total.tokens` (grep-confirmed). |

### Cross-cutting / anti-freeze invariants
- **NSPanel-not-NSMenu** preserved — popover architecture untouched by this commit (diff scope: Dashboard + CostScanner + tests + strings only). ✅
- **Zero I/O on main thread** — full scan + parse + build all off-main; `apply` on MainActor is pure value assignment. ✅
- **BUG 2 root cause real**: mtime pre-filter (`windowFileFloor`, fail-open on missing mtime) skips out-of-window files unread; `staleFileIsSkippedRecentFileIsScanned` proves the skip path doesn't drop real data (total==100, stale 9999-token file never read). ✅

### Gate item 4 (EXB-3.5 glassmorphism) — note
The brief referenced `NSGlassEffectView` / `#available`. **This codebase uses `NSVisualEffectView` + `TransparencyLevel.material`** (`UsagePanelController.swift:168`), not `NSGlassEffectView`; there is no `#available` glass gate. That's a **brief-vs-code naming mismatch, not a defect** — the real transparency mechanism (live `effectView.material` swap, pure main-thread AppKit, no I/O) is sound and was **not touched** by the EXB-3.6 commit (`git diff HEAD~1` confirms no Popover/Settings files changed). No regression possible from 3.6.

### Concerns (non-blocking)
1. **30d/90d remain I/O-bound (~38–44s on a 1 GB / ~1949-file history).** mtime filter only meaningfully helps 7d. UI never freezes (off-main + banner + once-per-open cache), so ACs hold, but a future incremental index would close the gap. Out of scope here — accepted as documented tech debt.
2. **StackedTokensChart has no hover** (justified). AC11 satisfied by CostPerDayChart; acceptable.
3. **Pre-existing timing flakes** (`SettingsStoreTests`/keychain) noted by dev; did not reproduce serially. Not introduced by this story.

### Decision
All 16 ACs implemented and verified **by result** (distinct per-period data proven, aggregation proven off-main, formatters proven static, downsampling structurally satisfied). Build clean, 207 tests green serially, anti-freeze invariants intact. The 3 concerns are documented tech debt / justified deviations, none blocking. Dev correctly held the push pending Hugo's visual validation.

VERDICT: PASS
