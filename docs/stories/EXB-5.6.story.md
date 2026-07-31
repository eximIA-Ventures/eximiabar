# Story EXB-5.6: Release v2.4.0

**ID:** EXB-5.6
**Status:** InProgress — release preparada e verificada localmente; corte público retido aguardando GO humano nos gates AC0.4–0.6
**Depends on:** EXB-5.1, EXB-5.2, EXB-5.3, EXB-5.4, EXB-5.5 (todas `Done`) — última por construção, corta a release do código completo da onda
**Epic:** EPIC-EXB
**Wave:** Onda 10 (v2.4.0)
**Executor:** @devops
**Quality gate:** @qa
**Complexity:** S (release mecânica, padrão já provado nas Ondas 4/5 e `EXB-3.3`; risco baixo, todas as armadilhas já documentadas)

---

## Story

**As a** exímIABar user,
**I want** instalar a v2.4.0 (multi-conta Claude + provider Codex) via Homebrew ou release direta,
**so that** eu tenha acesso à nova capacidade de workspace multi-conta de forma versionada e reproduzível, com o cask/README atualizados.

---

## Acceptance Criteria

### AC0 — Gates de saúde ANTES do release cut (bloqueantes)

> Adicionados pelo @po: eram apenas "Dev Notes" (sugestão), mas são as condições que definem se a onda pode ser distribuída. Um item de Wave DoD que não é AC de nenhuma story não é verificado por ninguém.

0.1. **Todas as 5 stories anteriores em `Done`** (não `InReview`) — verificar por `grep -H "^\*\*Status:\*\*" docs/stories/EXB-5.[1-5].story.md`.
0.2. **Anti-freeze (T-R18, `EXB-5.5` AC2.3):** `grep -rnE "NSPopUpButton|NSMenu\(|(^|[^A-Za-z])Menu\s*[{(]|\.menuStyle|MenuPickerStyle" Sources/ClaudeBar/ --include="*.swift" | grep -v "App/ClaudeBarApp.swift"` → **zero** ocorrências. Output colado na story.
0.3. **Keychain (R16), o gate que custou a Onda `EXB-3.8`:** 30 min de uso contínuo do app instalado, **zero** diálogos Allow/Deny. Registrar hora de início/fim como evidência. Um pop-up = release **abortada**, não "aceita com ressalva".
0.4. **D-C a olho:** trocar o foco para uma conta arquivada, `quit`, relançar → o painel abre na conta `.live`, nunca na arquivada.
0.5. **Menu bar ancorada a olho:** trocar o foco no switcher **não** altera o medidor da menu bar.
0.6. **Codex ausente:** renomear temporariamente `~/.codex/auth.json` → o provider Codex some do switcher **sem** erro nem linha vermelha; restaurar o arquivo ao fim.

### AC1–AC8 — Release

1. **Bump versão 2.4.0:** atualizar `CFBundleShortVersionString` e `CFBundleVersion` em `Sources/ClaudeBar/Info.plist` (path real confirmado na `EXB-3.3`, não `Resources/Info.plist`) para `2.4.0`; confirmar `swift test` verde antes de prosseguir.
2. **Build + empacotamento:** usar `make build` / `Scripts/package_app.sh` (não `swift build -c release` cru — o pacote inclui o resource bundle sem o qual o app crasha no launch, conforme lição registrada na `EXB-3.3`); empacotar via `ditto -c -k --sequesterRsrc --keepParent dist/ExímIABar.app ExímIABar-2.4.0.zip`.
3. **Push + tag + GitHub release:** `git push origin main`, `git tag v2.4.0`, `git push origin v2.4.0`; `gh release create v2.4.0 ExímIABar-2.4.0.zip --title "v2.4.0" --notes "Onda 10: multi-conta Claude (roster + captura automática no login) + provider Codex enxuto (OAuth via ~/.codex/auth.json)"` no repo `eximIA-Ventures/eximiabar`.
4. **Homebrew cask:** atualizar `Casks/eximiabar.rb` no repo `eximIA-Ventures/homebrew-tap` — `version "2.4.0"`, `sha256` recalculado do zip real (`shasum -a 256 ExímIABar-2.4.0.zip`), `url` apontando para o asset da nova release (atenção ao nome sanitizado sem acento pelo GitHub, conforme lição da `EXB-3.3`).
5. **Validação do cask:** `brew audit --cask` (ou `brew style --cask`) sem erros bloqueantes; capturar output como evidência.
6. **Migração local:** encerrar instância em execução (`pgrep -x ClaudeBar` + kill, ou `osascript -e 'quit app "ExímIABar"'`); instalar v2.4.0 via `make install` ou `brew install --cask --force eximia-ventures/tap/eximiabar`; confirmar `pgrep -x ClaudeBar` retorna PID após relançar (nome real do processo, não `ExímIABar`, conforme lição da `EXB-3.3`).
7. **README:** atualizar seção de funcionalidades mencionando o suporte multi-conta Claude e o provider Codex; manter as instruções de instalação (Homebrew + `make install`) já existentes.
8. `swift test` verde (sem regressões da baseline pré-onda) antes do release cut.

---

## Tasks

- [x] **T0 — Gates de saúde bloqueantes** (AC0) — 3 de 6 fechados por medição, 3 pendentes de olho humano (ver Evidências)
- [x] **T1 — Bump versão e teste final** (AC1) — `Sources/ClaudeBar/Info.plist` em `2.4.0`
- [x] **T2 — Build + empacotamento** (AC2) — `make build`, `ditto`
- [ ] **T3 — Git + GitHub release** (AC3) — **BLOQUEADO**: aguarda GO humano (AC0.4–0.6 abertos)
- [ ] **T4 — Atualizar cask Homebrew** (AC4) — **PREMISSA CAÍDA**: cask parado na `1.4.1`, não é o canal ativo
- [ ] **T5 — Validação do cask** (AC5) — depende de T4
- [x] **T6 — Migração local** (AC6) — v2.4.0 instalada e rodando (PID 54147)
- [x] **T7 — README** (AC7) — seção `## Features` com multi-conta + Codex

---

## Evidências de execução (@devops Gage, 2026-07-31)

### AC0 — gates bloqueantes

| Gate | Veredito | Evidência |
|:---|:---|:---|
| 0.1 stories `Done` | **PASS** | `grep -H "^\*\*Status:\*\*" docs/stories/EXB-5.[1-5].story.md` → 5/5 `Done` |
| 0.2 anti-freeze ampliado | **PASS** | grep do AC0.2 → **zero** ocorrências (exit 1) |
| 0.3 keychain 30 min (R16) | **PASS (instrumentado)** | 19:49:18 → 20:19:19, 179 amostras a cada 10s, `keychain_prompts=0`, `app_not_running_samples=0` |
| 0.4 D-C a olho | **PENDENTE HUMANO** | coberto por teste verde `focusResetsToLiveOnFreshAppStateConstruction()` (×2 suítes), mas o check é visual |
| 0.5 menu bar ancorada a olho | **PENDENTE HUMANO** | coberto por teste verde `menuBarNeverChangesWhenFocusChanges()`, mas o check é visual |
| 0.6 Codex ausente a olho | **PENDENTE HUMANO** | coberto por teste verde `codexAbsentProducesNoPane()`; **não** renomeei o `~/.codex/auth.json` real para não contaminar o gate 0.3 em curso nem mexer em credencial do Senhor sem supervisão |

**Método do gate 0.3 (declarado para não superestimar a prova):** o diálogo Allow/Deny do keychain é apresentado pelo processo `SecurityAgent`; o monitor (`/tmp/exb-keychain-smoke.sh`) amostrou sua presença a cada 10 s durante os 30 min, junto com a vitalidade do `ClaudeBar`. Isso é medição real, não simulação, mas **não é um olho humano na tela** — um prompt que surgisse e fosse dispensado dentro da mesma janela de 10 s escaparia. Como prompts de keychain permanecem abertos até interação, considero a amostragem adequada, e registro a limitação em vez de omiti-la.

### AC1–AC8

| Item | Resultado |
|:---|:---|
| Suíte de testes | **403/403 verdes** em 49 suítes, 15.9 s, via `Scripts/run-tests.sh` (exit 0) |
| `swift build -c release --arch arm64` | **Build complete**, zero warnings |
| `Info.plist` | `CFBundleShortVersionString` e `CFBundleVersion` = `2.4.0` |
| Assinatura | identidade estável `eximIA Code Signing` (`56FE9DFF…`); `valid on disk` + `satisfies its Designated Requirement` |
| Binário | universal — `lipo -info` → `x86_64 arm64` |
| Zip | `ExímIABar-2.4.0.zip`, 3,6 MB |
| sha256 | `a929f131f08ec1d8fefd2e218e3887c8001fd100ef7a22a81dd42b288c9f02f8` |
| Instalação | `/Applications/ExímIABar.app` = `2.4.0`; `pgrep -x ClaudeBar` → **54147** |
| Codex ao vivo | `GET wham/usage` → **HTTP 200**, `plan_type: plus`, `rate_limit.primary_window.limit_window_seconds: 604800` |

### Achados que alteram o plano da story

1. **`make build` estava quebrado nesta máquina.** O modo multi-arch do SwiftPM delega ao `xcbuild`, que só existe com Xcode completo — mesma classe de lacuna que o `Scripts/run-tests.sh` já contornava para o swift-testing. Corrigido em `Scripts/package_app.sh`: cada arquitetura é construída em separado e fundida com `lipo`, **preservando o binário universal** do artefato distribuído (nenhuma regressão de compatibilidade Intel).
2. **AC4/AC5 partem de premissa caída.** O cask `eximia-ventures/homebrew-tap` está na **`1.4.1`**, nove releases atrás do app (`2.3.2`). O canal de distribuição real, confirmado no README (`## Releases` → `Auto-updater`) e nas notas da `v2.3.2` ("Atualize pelo próprio app em Verificar atualizações"), é **GitHub Releases + auto-updater in-app**. Ressuscitar o cask fazendo-o saltar `1.4.1 → 2.4.0` é decisão de distribuição do Senhor, não consequência mecânica desta release — **não executado**.
3. **PII de terceiro barrada antes do commit.** A `EXB-5.4` continha `rinacapitelli@gmail.com` (conta Codex secundária) e o `account_id` real como evidência de teste. O repositório é **público** e esse endereço **nunca esteve no histórico** (`git log -S` vazio), ao contrário do e-mail do Senhor, que já é público como autor dos commits. Ambos os valores foram redigidos; a evidência preserva o valor probatório (o ponto era a correspondência, não o literal).

---

## Dev Notes

### Padrão de release a seguir (lições da `EXB-2.5` e `EXB-3.3`)

- Path real do `Info.plist`: `Sources/ClaudeBar/Info.plist` (não `Sources/ClaudeBar/Resources/Info.plist`)
- Usar `make build`/`Scripts/package_app.sh`, nunca `swift build -c release` cru para o artefato distribuído — falta o resource bundle e o watchdog
- Flag correta do `ditto`: `--sequesterRsrc` (não `--sequestRsrc`)
- GitHub sanitiza o acento no nome do asset (`ExímIABar-X.zip` → `EximIABar-X.zip`); o cask deve apontar para o nome real do asset publicado, mas o `app` stanza mantém o nome acentuado do bundle
- Processo real em execução é `ClaudeBar` (`CFBundleExecutable`), não `ExímIABar` — usar `pgrep -x ClaudeBar`

### Checklist de saúde antes do release cut

- `swift test` — todos verdes, incluindo os novos testes de `EXB-5.1` a `EXB-5.5`
- `swift build -c release` — zero warnings
- Grep de anti-freeze (`T-R18` da `EXB-5.5`): `grep -rn "NSPopUpButton\|NSMenu(" Sources/ClaudeBar/Popover/` retorna vazio
- App lança na máquina local sem prompt de segurança excessivo (Gatekeeper) nem pop-up de keychain (30 min de uso contínuo, `R16`)

### Notas de release sugeridas (conteúdo)

> Onda 10 (v2.4.0): suporte a múltiplas contas Claude com captura automática no login (roster somente-leitura de contas arquivadas) e novo provider Codex enxuto via OAuth (`~/.codex/auth.json`). Switcher inline no popover para trocar entre contas/provedores sem afetar o ícone da menu bar.

---

## Definition of Done

- [ ] AC0 integralmente cumprida (5 gates bloqueantes), evidências registradas na story
- [ ] `Info.plist` em `2.4.0`
- [ ] `swift test` verde (sem regressões); `swift build -c release` zero warnings
- [ ] Zip criado via `ditto`; sha256 documentado
- [ ] Tag `v2.4.0` no repo e GitHub release publicada com o zip como asset
- [ ] `Casks/eximiabar.rb` atualizado no `homebrew-tap`, `brew audit --cask` sem erros
- [ ] App v2.4.0 instalado em `/Applications/ExímIABar.app`; `pgrep -x ClaudeBar` confirma processo vivo
- [ ] `README.md` menciona multi-conta Claude + provider Codex

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-07-31 | 1.0 | Initial draft — Onda 10 (v2.4.0) | @sm River |
| 2026-07-31 | 1.1 | Validação @po: **GO 8/10**. Adicionada AC0 com 6 gates bloqueantes pré-release que estavam apenas em Dev Notes (sugestão) e no Wave DoD (sem dono): stories `Done`, grep anti-freeze ampliado, 30 min sem pop-up de keychain (R16 — o risco que custou a `EXB-3.8` inteira), e checks a olho de D-C, menu bar ancorada e Codex ausente. Item de Wave DoD que não é AC de nenhuma story não é verificado por ninguém. Complexidade estimada. Status → Ready. | @po Pax |

| 2026-07-31 | 1.2 | Execução @devops: AC0.1/0.2/0.3 fechados por medição (403/403 testes, grep limpo, 30 min instrumentados sem prompt de keychain); v2.4.0 empacotada, assinada, universal e instalada. `package_app.sh` corrigido para máquina sem Xcode. **Corte público retido**: AC0.4–0.6 são gates "a olho" e AC4/AC5 partem de premissa caída (cask defasado 9 releases). PII de terceiro redigida antes do commit. | @devops Gage |
