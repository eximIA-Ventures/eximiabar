# Story EXB-6.4: Cortes no Dashboard e exportação só CSV

**ID:** EXB-6.4
**Status:** Draft
**Depends on:** EXB-6.3 (a seção nova entra na ordem final)
**Epic:** EPIC-EXB
**Wave:** Onda 11 (v2.8 "Confiança e foco")
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** L (muita deleção; risco é código/teste órfão)

---

## Story

**As a** usuário do Dashboard,
**I want** menos blocos e uma única forma de ler cada coisa,
**so that** a tela responda às perguntas em vez de oferecer 17 gráficos.

---

## Acceptance Criteria

1. **Calendário anual fundido ao heatmap**: fica um bloco (heatmap dia×hora) com alternância "Semana / Ano" (o calendário anual vira a outra granularidade do mesmo bloco).
2. **Removidos**: fluxo de projetos (`ProjectFlowChart`/`DashboardFluxo`) e curva de Pareto (`ProjectParetoChart`/`DashboardPareto`); a tabela de projetos ganha coluna "% acum." (Pareto) e "%".
3. **Breakdown por modelo com ordem única**: donut e tabela ordenados pela mesma métrica, com seletor Tokens/Custo; tabela com coluna "% do custo".
4. **Resumo de 3 números no topo**: gasto no período, projeção, variação vs período anterior (reusa `MetricCard`/`DeltaBadge`); sem período anterior coberto, a variação diz "sem base".
5. **Exportação só CSV**: removidos XLSX, painel HTML e pacote; o botão exporta CSV direto. `grep -rn "xlsx\|XLSX" Sources` → vazio.
6. **Código e testes órfãos removidos**; `swift build` sem símbolos mortos referenciados; suíte verde.
7. Contagem de blocos registrada antes/depois.

## Tasks
- [ ] T1 Heatmap com alternância Semana/Ano (AC1)
- [ ] T2 Remover fluxo e Pareto, colunas na tabela (AC2)
- [ ] T3 Seletor no breakdown (AC3)
- [ ] T4 Resumo do topo (AC4)
- [ ] T5 Exportação só CSV e deleções (AC5, AC6)
- [ ] T6 README e prints

## Dev Agent Record
_(preenchido na implementação)_

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada | @dev (Dex) |
