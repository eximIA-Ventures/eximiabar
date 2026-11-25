# Story EXB-6.2: Popover direto (ritmo em linguagem de decisão, gravidade, ações em ícones)

**ID:** EXB-6.2
**Status:** Draft
**Depends on:** EXB-6.1 (marcador `~` no `MetricRow`)
**Epic:** EPIC-EXB
**Wave:** Onda 11 (v2.8 "Confiança e foco")
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M

---

## Story

**As a** usuário do exímIABar,
**I want** que o popover me diga o que fazer (vai acabar? quanto sobra?) e só fique vermelho quando houver risco,
**so that** eu leia a situação num relance sem decodificar "reserve - 30%".

---

## Acceptance Criteria

### AC1 — Ritmo em linguagem de decisão (`Popover/UsagePaceText.swift`)
1.1. Em déficit com esgotamento antes do reset: "No ritmo atual, acaba ~<dia abreviado> <hora>h" (EN: "At this pace, runs out ~<day> <h>").
1.2. Caso contrário (no ritmo ou com folga): "Sobra ~N% até o reset" (N = 100 − uso projetado no reset, inteiro, ≥ 0).
1.3. O "esperado" deixa de ser número no texto: vira o tique do trilho com tooltip ("Esperado agora: N%").
1.4. Testes determinísticos com `now`, `calendar` e `locale` injetados.

### AC2 — Cor por gravidade, paleta de estado separada da de modelos (`Design/DesignTokens.swift`)
2.1. `DesignTokens.StatePalette` com 3 níveis: neutro → âmbar (déficit de ritmo ou ≥ 70%) → vermelho (esgota antes do reset ou ≥ 90%).
2.2. Número e barra do `MetricRow` e da `ModelRow` usam a paleta de estado; neutro não é a cor da marca.
2.3. `DesignTokens.ModelPalette` (ramp do Dashboard) não contém âmbar, vermelho nem terracota: Opus deixa de parecer alerta. Teste compara cada swatch com as cores de estado.

### AC3 — Ações em barra de ícones
3.1. As linhas de ação viram uma barra de ícones no rodapé, cada uma com tooltip (`.help`) que inclui o atalho; atalhos ⌘R/⌘D/⌘,/⌘Q mantidos.
3.2. "Status Page": não existe dado de incidente no app (verificado: só um stub em `IconRenderer`), então fica como ícone discreto (opacidade reduzida), sem destaque.
3.3. Quit acessível como ícone da barra, com tooltip "Sair (⌘Q)".

### AC4 — Ultra
4.1. Linha "N× seu plano" também no Ultra **se** o preço estiver na tabela; o preço do Ultra não é publicado/conhecido no código, então a linha é omitida sem inventar (teste trava que `ultra.approxMonthlyPriceUSD == nil` e que o card não mostra "×").

### AC5 — Localização
5.1. Todas as strings novas em EN e PT-BR; `LocalizationTests` verde.

---

## Tasks
- [ ] T1 `UsagePaceText` novo texto + tooltip do tique (AC1)
- [ ] T2 Paletas de estado e de modelos (AC2)
- [ ] T3 Barra de ícones (AC3)
- [ ] T4 Ultra sem inventar preço (AC4)
- [ ] T5 Strings e testes (AC5)

## Verificação
- `swift build --arch arm64`, `Scripts/run-tests.sh`, prints do README

## Dev Agent Record
_(preenchido na implementação)_

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada | @dev (Dex) |
