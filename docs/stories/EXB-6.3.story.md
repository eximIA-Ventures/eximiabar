# Story EXB-6.3: O que comeu a semana (desde o último reset, por projeto e por agente)

**ID:** EXB-6.3
**Status:** Draft
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
- [ ] T1 `WeeklyAttributionScanner` + modelo (AC2, AC3)
- [ ] T2 Período e plumbing do `resetsAt` até o Dashboard (AC1)
- [ ] T3 Seção na tela (AC4)
- [ ] T4 Testes com fixtures (AC5), strings (AC6)

## Dev Agent Record
_(preenchido na implementação)_

## Change Log
| Data | Mudança | Autor |
|:---|:---|:---|
| 2026-11-25 | Story criada | @dev (Dex) |
