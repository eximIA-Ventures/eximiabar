# Story EXB-6.3: O que comeu a semana (desde o último reset, por projeto e por agente)

**ID:** EXB-6.3
**Status:** Done
**Depends on:** —
**Epic:** EPIC-EXB
**Wave:** Onda 11 (v2.8 "Confiança e foco")
**Executor:** @dev
**Quality gate:** @qa
**Complexity:** M

---

## Story

**As a** usuário que bateu no limite semanal,
**I want** ver desde o último reset quanto cada projeto e cada agente/subagente consumiu,
**so that** eu saiba o que cortar antes de a semana acabar.

---

## Acceptance Criteria

1. **Período novo** no Dashboard: "Desde o reset" (`DashboardPeriod.sinceReset`). Início = `resetsAt` da janela semanal − 7 dias (dia local). Sem janela semanal conhecida, cai em 7 dias e diz isso na seção.
2. **Atribuição** (`WeeklyAttribution`, em `ClaudeBarCore`): varre os JSONL desde o início, incluindo `subagents/agent-*.jsonl`; deduplica `messageId:requestId`; classifica cada mensagem em **principal** (arquivo de sessão, `isSidechain` falso) ou **subagente** (arquivo em `subagents/` ou `isSidechain: true`). Nome do subagente: `agentType` do `.meta.json` irmão, senão `<nome>` de `agent-<nome>-<hash>.jsonl`, senão "subagente".
3. **Peso**: custo estimado por tabela embutida (proxy do consumo de cota); cada fatia vira `share × p.p. consumidos da semana` (`weekly.utilization`).
4. **Tela**: seção "O que comeu a semana" com duas listas (por projeto, por agente), cada linha com p.p. e %, rotulada "proporção estimada". Só aparece no período "Desde o reset".
5. **Testes com fixtures**: diretório temporário com sessão principal + 2 subagentes (um nomeado por meta.json, um pelo nome do arquivo) + linha anterior ao início (ignorada) + duplicata (contada 1×); asserções de share, nomes e p.p.
6. EN e PT-BR.

## Tasks
- [x] T1 `WeeklyAttributionScanner` + modelo (AC2, AC3)
- [x] T2 Período e plumbing do `resetsAt` até o Dashboard (AC1)
- [x] T3 Seção na tela (AC4)
- [x] T4 Testes com fixtures (AC5), strings (AC6)

## Dev Agent Record

### Decisões
- Scanner próprio (`WeeklyAttributionScanner`, `ClaudeBarCore/Cost/WeeklyAttribution.swift`) em vez de nova dimensão no cache incremental do analytics: a semana é uma janela curta, lida por porta própria (`DashboardSource.atribuirSemana`), chamada só no período "Desde o reset" e memorizada por início de janela no `DashboardRangeModel`. O invariante "trocar a faixa não lê o disco" do `fatiar` fica intacto.
- Peso = custo estimado pela tabela embutida (`Pricing.fallbackPrice`), inclusive cache; p.p. = `share × weekly.utilization` da conta da barra.
- Nome do subagente: `agentType`/`name` do `.meta.json` irmão → `agent-<nome>-<hash>` → "subagente". Medido nesta máquina: 1.399 arquivos `agent-<hash>` (nome só no meta.json) e 2 com nome no arquivo; ambos cobertos.
- Desempenho medido (`EXB_BENCH_WEEK=1`, debug, ~/.claude real: 171 arquivos / ~1,1 GB na semana): 15,1 s serial → 3,1 s com pré-filtro de bytes + `concurrentPerform` por arquivo. Roda fora do main, sob o banner de atualização.
- Sem `resetsAt` semanal conhecido, o período cai em 7 dias e a seção diz isso ("reset semanal desconhecido").

### Verificação
- `Scripts/run-tests.sh` 761 testes / 91 suítes verdes; fixtures em `WeeklyAttributionTests` (principal + 2 subagentes + linha antes da janela + chunk duplicado) e `DashboardSinceResetTests` (período, anexação só em `.sinceReset`, cache por início).
- Visual: `docs/images/dashboard-since-reset.png` conferido por Read.
- Real (bench): principal 48%, `aiox-dev` 13,5%, `aiox-ux` 5,2%… nomes resolvidos pelo meta.json.

## File List
- `Sources/ClaudeBarCore/Cost/WeeklyAttribution.swift` (novo)
- `Sources/ClaudeBar/Dashboard/DashboardSemana.swift` (novo), `DashboardPeriod.swift`, `DashboardData.swift`, `DashboardRangeModel.swift`, `DashboardWindowController.swift`, `DashboardView.swift`, `PainelExport.swift`
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` (`semanaProvider`)
- `Sources/ClaudeBar/Resources/{en,pt-BR}.lproj/Localizable.strings`
- `Tests/ClaudeBarCoreTests/WeeklyAttributionTests.swift`, `Tests/ClaudeBarTests/DashboardSinceResetTests.swift`, `Tests/ClaudeBarTests/ReadmeScreenshotRenderer.swift`

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada | @dev (Dex) |
| 2026-11-25 | Implementada, Done | @dev (Dex) |
