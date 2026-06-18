# Story EXB-4.1: Heatmap Fix — Escala Logarítmica e Contraste

**ID:** EXB-4.1
**Status:** Ready for Review
**Depends on:** EXB-3.7 (Dashboard polish — heatmap baseline `ActivityHeatmapChart`, `HeatmapLegend`, `HeatmapTooltip`, `DashboardFormat.tokenCount`, brand color `#CC7C5E`; 223 testes verdes)
**Epic:** EPIC-EXB
**Wave:** Onda 9 (v1.6.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** user who monitors my Claude usage in the dashboard,
**I want** a heatmap where every cell with tokens is clearly visible regardless of the usage peak,
**so that** I can actually read my activity patterns instead of seeing a nearly-invisible grid against a dark background.

---

## Acceptance Criteria

### AC1 — Escala logarítmica (ou por percentil) na dimensão de cor

1. A escala de cor do heatmap usa transformação NÃO-LINEAR: logarítmica (`log1p`) ou por quantil/percentil — a decisão fica com o dev, documentada como desvio se for percentil. A escala LINEAR de 0 a `max` é eliminada completamente.
2. A função de mapeamento `color(for: Int) -> Color` (ou equivalente) reside em um tipo dedicado `HeatmapColorScale` (struct ou enum), testável isoladamente, não inline na view.
3. A transformação usa `log1p` para evitar `log(0)` em células zero: `normalizedValue = log1p(Double(tokens)) / log1p(Double(maxTokens))`.

### AC2 — Contraste mínimo garantido

4. Toda célula com `tokens > 0` mapeia para uma cor com luminância relativa suficiente para ser distinguível do fundo do card (mínimo visível). Critério prático: `normalizedValue` nunca cai abaixo de `0.08` para células não-zero.
5. O gradiente usa a cor da marca `#CC7C5E` como extremo superior — idêntico ao baseline EXB-3.7 (`Color.brandOrange`).
6. Células com `tokens == 0` recebem uma cor neutra distinta (ex: `Color.secondary.opacity(0.10)`) que não seja confundível com uma célula de baixo-não-zero. O contraste visual entre "zero" e "tem alguma atividade" deve ser imediatamente perceptível.

### AC3 — Legenda coerente com a transformação

7. A `HeatmapLegend` exibe os valores reais (em K/M/B via `DashboardFormat.tokenCount`) nos pontos âncora da escala: zero, mediana do log-range (ou p50), e máximo. Nenhum label exibe notação científica.
8. A legenda indica visualmente (label de texto ou tooltip) que a escala é logarítmica (ex: rodapé "Escala log" / "Log scale").

### AC4 — Teste de cobertura da função de cor

9. Dado um conjunto com 1 pico de 238.9M tokens e os demais valores no range 100K–5M, a função `HeatmapColorScale.normalized(tokens:max:)` retorna valores que cobrem pelo menos 4 faixas perceptíveis (ex: resultados distintos para 100K, 1M, 10M, 238.9M).
10. A célula zero (`tokens == 0`) retorna `normalized = 0.0` exatamente.

### AC5 — Regressão e build

11. `swift build -c release` zero warnings (clean `.build`).
12. `swift test --no-parallel` sem regressões da baseline de 223 testes; pelo menos **4 novos testes unitários** cobrindo: `log1p` normalização (4 valores), zero case, contraste mínimo (valor não-zero >= 0.08), legenda tokens formatados (sem sci-notation).

---

## Tasks

- [x] **T1 — Criar `HeatmapColorScale`** (AC1, AC2, AC4) — `Sources/ClaudeBar/Dashboard/`
  - [x] `enum HeatmapColorScale` com `static func normalized(tokens: Int, max: Int) -> Double` usando `log1p` (enum-namespace; AC2 admite struct ou enum)
  - [x] `static func color(tokens: Int, max: Int) -> Color`: retorna `Color.secondary.opacity(0.10)` (`zeroFill`) para zero; para não-zero aplica `brand.opacity(max(0.08, normalized))`
  - [x] Lógica de escala movida de `ActivityHeatmapChart` para este tipo; escala linear anterior eliminada

- [x] **T2 — Atualizar `ActivityHeatmapChart`** (AC1, AC2, AC3) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [x] `chartForegroundStyleScale` contínuo + `.foregroundStyle(by:)` removidos; agora `.foregroundStyle(HeatmapColorScale.color(tokens:max:))` por célula
  - [x] `max` capturado uma vez (`let max = maxTokens`) antes do `Chart`, nunca dentro do closure
  - [x] Anti-freeze: nenhum formatter/cálculo pesado em `body`; `HeatmapColorScale` é puro/static

- [x] **T3 — Atualizar `HeatmapLegend`** (AC3) — `Sources/ClaudeBar/Dashboard/DashboardView.swift`
  - [x] 3 pontos âncora: `0`, `HeatmapColorScale.logMidpoint(max:)` (`exp(log1p(max)/2) - 1`), `max`
  - [x] Label "Escala log" / "Log scale" (localizado) no rodapé da legenda
  - [x] Todos os labels via `DashboardFormat.tokenCount` — zero sci-notation

- [x] **T4 — Localização** (AC5) — `en.lproj` + `pt-BR.lproj`
  - [x] `dashboard.heatmap.log_scale` = "Log scale" / "Escala log"

- [x] **T5 — Testes** (AC4, AC5) — `Tests/ClaudeBarTests/`
  - [x] `HeatmapColorScaleTests.swift` (novo): 7 testes cobrindo AC4/AC5 (incl. AC9, AC10, AC11/#4, AC12)
  - [x] `swift test --no-parallel` 237 testes verdes (baseline 223 → +7 novos + restante; floor 227 superado)

---

## Dev Notes

### Baseline do código (EXB-3.7)

| Arquivo | Relevância |
|---------|-----------|
| `Sources/ClaudeBar/Dashboard/DashboardView.swift` | `ActivityHeatmapChart` (~linha 1092), `HeatmapLegend` (~linha 1189), `HeatmapTooltip` (~linha 1163), `Color.brandOrange` (~linha 1066) |
| `Sources/ClaudeBar/Dashboard/DashboardData.swift` | `HeatmapBucket` (struct com `dayOfWeek: Int`, `hour: Int`, `tokens: Int`), `heatmap: [[HeatmapBucket]]` (7×24) |
| `Tests/ClaudeBarTests/DashboardPolishTests.swift` | Testes de referência para formatação K/M/B e heatmap |

### Escala atual (a remover)

O EXB-3.7 implementou o gradiente assim:
```swift
.chartForegroundStyleScale(range: [Color.clear, .brandOrange])
```
Isso passa a escala LINEAR diretamente ao Swift Charts, que normaliza de 0 a max. Para dados com distribuição exponencial (1 pico alto, muitos valores baixos), a grande maioria das células cai no terço inferior — quase invisível.

### Implementação log1p recomendada

```swift
struct HeatmapColorScale {
    static func normalized(tokens: Int, max: Int) -> Double {
        guard max > 0 else { return 0 }
        guard tokens > 0 else { return 0 }
        let v = log1p(Double(tokens)) / log1p(Double(max))
        return max(0.08, min(1.0, v))  // clamp: min 0.08 para não-zero
    }

    static func color(tokens: Int, max: Int) -> Color {
        guard tokens > 0 else { return Color.secondary.opacity(0.10) }
        let n = normalized(tokens: tokens, max: max)
        // Interpolar entre .clear e .brandOrange manualmente,
        // ou usar opacidade: Color.brandOrange.opacity(n)
        return Color.brandOrange.opacity(n)
    }
}
```

Alternativa via `Color.brandOrange.opacity(n)` é mais simples que interpolação RGB manual e produz resultado visual equivalente para gradientes escuros-para-cor.

### HeatmapLegend — pontos âncora logarítmicos

```swift
// 3 pontos âncora:
// p0 = 0 (zero)
// p1 = Int(exp(log1p(Double(maxTokens)) / 2) - 1)  // médio no espaço log
// p2 = maxTokens
let p1 = Int(exp(log1p(Double(maxTokens)) / 2) - 1)
```

Label "Escala log" / "Log scale" pode ser um `Text` pequeno (`.caption2`) abaixo dos swatches da legenda.

### Anti-freeze invariants (obrigatórios — transversais ao epic)

- `max` do heatmap calculado uma vez em `ActivityHeatmapChart.body` (ou como `let` capturado), nunca dentro do closure do `RectangleMark`
- Nenhum `DateFormatter` ou `NumberFormatter` instanciado dentro de `body`
- `HeatmapColorScale` é puro (static functions), zero estado, nenhum risco de main-thread

### Testing

- Framework: XCTest (padrão do repo) ou Swift Testing — ver `Tests/ClaudeBarTests/`
- Baseline: 223 testes (EXB-3.7); zero regressões obrigatório
- Arquivo alvo: `Tests/ClaudeBarTests/HeatmapColorScaleTests.swift` (novo)
- Testes mínimos (AC12): `normalizedZeroReturnsZero`, `normalizedNonZeroMinimum008`, `normalized4DistinctBands`, `legendLabelsNoScientificNotation`
- `swift build -c release` zero warnings (clean `.build`)
- `swift test --no-parallel`

---

## Definition of Done

- [x] `HeatmapColorScale` isolada e testável, com escala `log1p`
- [x] Células não-zero visíveis (mínimo 0.08 de opacidade/luminância relativa)
- [x] Células zero em cor neutra distinta (`Color.secondary.opacity(0.10)`)
- [x] `HeatmapLegend` com 3 pontos âncora logarítmicos + label "Escala log"
- [x] 7 novos testes verdes; zero regressões (237 testes totais; floor 227 superado)
- [x] `swift build -c release` zero warnings (clean `.build`)

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Date:** 2026-06-18 · **Model:** Opus 4.8

### Validação com dados reais (`~/.claude/projects`)

Critério OLHO confirmado quantitativamente sobre 1.833 arquivos JSONL / 52.938 linhas de uso (98/168 células não-zero, pico 480.5M, mediana 62.3M):

| Célula | Linear (a remover) | Log1p (implementado) |
|--------|-------------------:|---------------------:|
| Pico 480.5M | 100.00% | 100.00% |
| Mediana 62.3M | **12.96%** (quase invisível) | **89.78%** (clara) |
| 4.4M | **0.91%** (invisível) | **76.52%** (visível) |
| 1.4M (menor) | **0.29%** (invisível) | **70.70%** (visível) |

A escala linear empurrava a maioria das células ao terço inferior de opacidade; log1p eleva toda atividade ao range visível. Caso AC4 (pico 238.9M + 100K–5M) valida 4 faixas distintas (0.5968 / 0.7161 / 0.8355 / 1.0).

### Decisões / Desvios (IDS)

- **CREATE** `HeatmapColorScale.swift` — nenhum tipo similar existia (Glob/Grep confirmaram).
- **REUSE** `PopoverStyle.brand` (`#CC7C5E`) — a story referenciava `Color.brandOrange`, que **não existe** no código; `PopoverStyle.brand` é o token canônico do `#CC7C5E` (baseline EXB-3.7). **Desvio justificado:** usado o token real.
- **Tipo `enum`** em vez de `struct` — namespace de funções puras static, não instanciável. AC2 admite "struct ou enum".
- **Escala = logarítmica** (`log1p`), não percentil — implementação primária da story, sem desvio.

### File List

| Arquivo | Mudança |
|---------|---------|
| `Sources/ClaudeBar/Dashboard/HeatmapColorScale.swift` | **NOVO** — escala log1p pura (normalized/color/logMidpoint) |
| `Sources/ClaudeBar/Dashboard/DashboardView.swift` | `ActivityHeatmapChart.chart` (per-cell `HeatmapColorScale.color`), `HeatmapLegend` (3 âncoras log + label "Escala log") |
| `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` | `dashboard.heatmap.log_scale` = "Log scale" |
| `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` | `dashboard.heatmap.log_scale` = "Escala log" |
| `Tests/ClaudeBarTests/HeatmapColorScaleTests.swift` | **NOVO** — 7 testes (AC4/AC5) |

### Build & Test

- `swift build -c release` (clean `.build`): **Build complete! zero warnings**
- `swift test --no-parallel`: **237 tests in 33 suites passed** (HeatmapColorScaleTests 7/7 verdes)
- `EXIMIA_SIGN_IDENTITY="eximIA Code Signing" make build`: assinado e verificado — `dist/ExímIABar.app` (7.7M)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |

---

## QA Results — rodada 1

**Gate:** @qa (Quinn) · **Date:** 2026-06-18 · **Commit:** `1554740` (local, no push) · **Criterion:** RESULTADO, não presença

### 1. AC-by-AC (resultado verificado, não documentação)

| AC | Requisito | Evidência (arquivo:linha) | Veredicto |
|----|-----------|---------------------------|-----------|
| AC1-#1 | Escala NÃO-linear; linear `0..max` eliminada | `HeatmapColorScale.swift:39-43` (log1p) + `DashboardView.swift` diff: `chartForegroundStyleScale` REMOVIDO, `.foregroundStyle(by:)` REMOVIDO | ✅ |
| AC1-#2 | `color(for:)` em tipo dedicado, testável, não inline | `HeatmapColorScale.swift:20,51` (enum, static) — lógica movida da view | ✅ |
| AC1-#3 | `log1p` p/ evitar `log(0)` | `HeatmapColorScale.swift:41` `log1p(Double(tokens)) / log1p(Double(max))` | ✅ |
| AC2-#4 | Não-zero nunca abaixo de `0.08` | `HeatmapColorScale.swift:42` clamp `Swift.max(0.08, …)`; teste `normalizedNonZeroMinimum008` verde | ✅ |
| AC2-#5 | Extremo superior = `#CC7C5E` | `PopoverStyle.swift:12` = RGB(204,124,94) = `#CC7C5E`; usado em `color()`:53 e legenda | ✅ |
| AC2-#6 | Zero = cor neutra distinta | `HeatmapColorScale.swift:28,52` `zeroFill = Color.secondary.opacity(0.10)`; teste `zeroCellUsesNeutralFillDistinctFromBrand` verde | ✅ |
| AC3-#7 | Legenda: 3 âncoras K/M/B, sem sci-notation | `DashboardView.swift` legend diff: anchors `[0, logMidpoint, max]` via `DashboardFormat.tokenCount`; teste `legendLabelsNoScientificNotation` verde | ✅ |
| AC3-#8 | Indica escala log (label) | `DashboardView.swift` `Text(L("dashboard.heatmap.log_scale"))`; en="Log scale", pt-BR="Escala log" | ✅ |
| AC4-#9 | ≥4 faixas perceptíveis (pico 238.9M + 100K–5M) | teste `normalized4DistinctBands` verde (`Set.count == 4`, estritamente crescente) | ✅ |
| AC4-#10 | Zero → `normalized == 0.0` exato | `HeatmapColorScale.swift:40` guard; teste `normalizedZeroReturnsZero` verde (inclui `max==0` e degenerados) | ✅ |
| AC5-#11 | `swift build -c release` zero warnings (clean) | RODADO por mim: `rm -rf .build && swift build -c release` → `Build complete! (18.44s)`, zero warnings | ✅ |
| AC5-#12 | `swift test --no-parallel` sem regressões, ≥4 novos testes | RODADO por mim: **237 tests / 33 suites passed** (3.341s). HeatmapColorScaleTests = **7/7 verdes** (>4 exigidos) | ✅ |

**12/12 ACs implementados e verificados.**

### 2. Build + Test (rodados pelo gate, não confiando no relatório)

- `rm -rf .build && swift build -c release` → **Build complete! (18.44s), zero warnings**.
- `swift test --no-parallel` → **237 tests in 33 suites passed (3.341s)**. Serial, **sem prompt de keychain**, sem hang — confirmado contra a flakiness histórica.
- Baseline 223 → 237 (+14; os 7 de `HeatmapColorScale` confirmados nominalmente no output). Floor 227 superado.

### 3. Específico da story (4.1) — a função de cor é log e células com atividade ficam visíveis?

- **Log, não linear:** `normalized` é exatamente `log1p(tokens)/log1p(max)`. Teste `normalizedMatchesLog1pFormula` pina a fórmula (`abs(…) < 1e-12`) sobre o pico real 480.5M — blindagem contra refactor silencioso para outra curva.
- **Visibilidade garantida por RESULTADO:** o clamp `0.08` + o teste `normalizedNonZeroMinimum008` provam que mesmo 1 token contra 1B mapeia ≥ 0.08. A validação OLHO do dev (mediana 12.96%→89.78%, menor célula 0.29%→70.70% sobre 1.833 JSONL reais) é coerente com a matemática verificada. **Efeito real, não presença de código.**
- **Anti-freeze (invariante transversal do epic):** `let max = maxTokens` capturado **uma vez** antes do `Chart` (`DashboardView.swift:1089-1091`), nunca dentro do closure do `RectangleMark`. `HeatmapColorScale` é enum puro/static, zero estado, zero `DateFormatter`/`NumberFormatter` em `body`. `maxTokens` é flatMap+max sobre grid fixo 7×24 (168 itens) — custo trivial. ✅
- **IDS — desvio justificado e correto:** story citava `Color.brandOrange` (inexistente no código). Dev usou `PopoverStyle.brand` = `#CC7C5E` (token canônico real, baseline EXB-3.7). Confirmei a equivalência RGB. `grep brandOrange` em `Sources/` = zero ocorrências. Desvio aceito.

### 4. Regressão de features anteriores

- Suite completa (33 suites, 237 testes) verde — inclui filtros, banner, cache, keychain CLI (EXB-3.8), dashboard polish (EXB-3.7). Zero regressões.
- O único ponto de toque na view foi `ActivityHeatmapChart.chart` + `HeatmapLegend`; o restante de `DashboardView` intacto (diff cirúrgico, 66 linhas, +46/-20).
- Keychain serializado e isolado (commit `5ffbe1a` anterior) — teste serial não promptou.

### Observação (não-bloqueante)

- O escopo deste gate é **EXB-4.1**. As stories 4.2–4.5 referenciadas no briefing existem como arquivos untracked (`EXB-4.2..4.5.story.md`) mas **não foram implementadas neste commit** e não são objeto desta rodada. Quando entrarem em InReview, gates próprios (símbolo eximIA real do LOGO + `.icns` regenerado, taxa suavizada off-main, hotkey global + render anti-freeze, cache hit rate + reuso de agregador).

### Veredicto

Resultado real entregue: a escala é genuinamente logarítmica (fórmula pinada por teste), toda célula com atividade clareia o piso de contraste 0.08 (provado por teste, não por inspeção visual apenas), zero é distinto, legenda log-coerente sem sci-notation, build limpo, 237 testes verdes em serial sem keychain. Nenhum "presença sem efeito" detectado.

**VERDICT: PASS**
