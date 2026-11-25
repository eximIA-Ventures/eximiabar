# Story EXB-6.4: Cortes no Dashboard e exportação só CSV

**ID:** EXB-6.4
**Status:** Done
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
- [x] T1 Heatmap com alternância Semana/Ano (AC1)
- [x] T2 Remover fluxo e Pareto, colunas na tabela (AC2)
- [x] T3 Seletor no breakdown (AC3)
- [x] T4 Resumo do topo (AC4)
- [x] T5 Exportação só CSV e deleções (AC5, AC6)
- [x] T6 README e prints

## Dev Agent Record

### Contagem de blocos (AC7)
- **Antes (17):** Cobertura, Volume, Custo, Semana (só 7d), rótulo "Gráficos", Tokens empilhados, Custo/dia, Modelos (rosca+tabela), Modelos por dia, Tabela de projetos, Pareto, Fluxo, Cascata, Heatmap, Calendário anual, Histograma, Top sessões.
- **Depois (12 fixos + 2 contextuais):** Resumo, Cobertura, Volume, Tokens empilhados, Custo/dia, Modelos, Modelos por dia, Tabela de projetos (com % e % acum.), Cascata, Atividade (hora×dia / ano), Histograma, Top sessões; contextuais: "O que comeu a semana" (só "Desde o reset") e Semana (só 7d).
- Não chegou a ~11 fixos. Os cortes aprovados (fluxo, Pareto, calendário fundido) mais a troca da grade de custo de 5 cartões pelo resumo de 3 números dão 12. Os próximos candidatos (cascata, histograma) não estavam no escopo aprovado e ficam para o dono decidir.

### Decisões
- `[AUTO-DECISION]` O resumo de 3 números **substitui** a seção de custo de 5 cartões (total, hoje, duas médias, projeção) em vez de somar-se a ela. (motivo: total e projeção apareceriam duas vezes; as médias de custo eram redundantes com as médias de tokens do Volume; a ressalva "não é fatura" foi mantida sob o resumo.)
- Variação vs período anterior: trecho de mesmo tamanho imediatamente antes (`DashboardSpan.anterior()`), lido em memória por uma porta própria (`DashboardSource.periodoAnterior`), para não alterar a lista de intervalos que os testes de "zero I/O" do `fatiar` fixam. Só compara quando o trecho anterior foi observado por inteiro; senão o cartão diz "sem período anterior completo" (via `DeltaBadge`, contexto `.periodo`).
- Pareto: `ParetoCurva` (derivação existente e testada) virou as colunas "%" e "% acum." da tabela; a view do gráfico foi removida, a derivação fica.
- Breakdown por modelo: `ModelMetric` (tokens/custo) ordena rosca e tabela; ângulo da rosca segue a mesma métrica; coluna "% do custo".
- Exportação: `ClaudeBarCore/Export/` inteiro removido (XLSX, ZIP, painel HTML/SVG/JSON, pacote, CSVs tidy), mais `PainelExport`, `PainelExportPlanilha`, `ExportFormato` e 10 arquivos de teste. O botão "Exportar CSV" grava `DashboardData.csvExport()` direto. `docs/architecture/onda-11-exportacao.md` fica como registro histórico do que existiu.
- Strings órfãs removidas: `dashboard.flow.*`, `dashboard.pareto.*`, `dashboard.export.(format|hint|period)*`, `dashboard.section.cost`, `dashboard.cost.total/today`. `DesignTokens.meterAccentText` ficou órfão com EXB-6.2 e saiu.
- Limite do render: `Picker(.segmented)` não aparece no `ImageRenderer` (placeholder amarelo); os prints passam `mostraSeletor: false`. Os seletores só foram verificados por build/teste, não por imagem.

### Verificação
- `swift build --arch arm64` verde, sem warnings nos arquivos tocados.
- `Scripts/run-tests.sh` → 638 testes / 84 suítes verdes (761 antes desta story: −~125 testes do motor de exportação removido, +7 novos em `DashboardCutsTests`).
- `grep -rn "xlsx\|XLSX" Sources` → vazio (exit 1), e travado por teste.
- Prints regenerados: `docs/images/{popover,popover-ultra,popover-multi-account,dashboard-since-reset,dashboard-models,dashboard-models-by-day}.png`, conferidos por Read.

## File List
- Removidos: `Sources/ClaudeBarCore/Export/*` (13), `Sources/ClaudeBar/Dashboard/{DashboardFluxo,ExportFormato,PainelExport,PainelExportPlanilha}.swift`, `Tests/ClaudeBarCoreTests/{ExportDiaLocal,ExportPackage,ExportSampleWorkbook,ExportTestSupport,PainelHTML,PainelSampleData,XLSXChart,XLSXWriter,ZIPWriter}*.swift`, `Tests/ClaudeBarTests/PainelExportTests.swift`
- Alterados: `Sources/ClaudeBar/Dashboard/{DashboardView,DashboardData,DashboardPeriod,DashboardRangeModel,DashboardWindowController,DashboardCobertura}.swift`, `Sources/ClaudeBar/Design/DesignTokens.swift`, strings EN/PT-BR, `README.md`, `docs/images/*.png`
- Testes: `Tests/ClaudeBarTests/DashboardCutsTests.swift` (novo), `DashboardHierarchyTests`, `DashboardRepresentacoesTests`, `DashboardDimensoesTests`, `DashboardCardLabelFitTests`, `DashboardVizRenderer*`, `ReadmeScreenshotRenderer`

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada | @dev (Dex) |
| 2026-11-25 | Implementada, Done | @dev (Dex) |
