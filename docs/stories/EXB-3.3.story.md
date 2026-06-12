# Story EXB-3.3: Homebrew Tap + Release v1.2.0

**ID:** EXB-3.3
**Status:** Done
**Depends on:** EXB-3.1 (Done), EXB-3.2 (Done), EXB-2.5 (repo público + release infrastructure via GitHub)
**Epic:** EPIC-EXB
**Wave:** Onda 5 (v1.2.0)
**Executor:** @devops
**Quality gate:** @qa

---

## Story

**As a** developer or power user on macOS,
**I want** to install exímIABar via `brew install --cask eximiabar` from a published Homebrew tap,
**so that** I get a reproducible, versioned install with clean uninstall support — and the README clearly documents this path alongside the `make install` alternative.

---

## Acceptance Criteria

1. **Bump versão 1.2.0:** atualizar `CFBundleShortVersionString` e `CFBundleVersion` em `Sources/ClaudeBar/Resources/Info.plist` para `1.2.0`; confirmar que `swift test` passa verde antes de prosseguir.
2. **Build + zip da release:** `swift build -c release`; `ditto -c -k --sequestRsrc --keepParent .build/release/ExímIABar.app ExímIABar-1.2.0.zip` (ou equivalente que produza um zip válido do .app bundle incluindo o helper watchdog).
3. **Push + tag + GitHub release:** `git push origin main`, `git tag v1.2.0`, `git push origin v1.2.0`; `gh release create v1.2.0 ExímIABar-1.2.0.zip --title "v1.2.0" --notes "Onda 5: Glassmorphism REAL, Dashboard Analytics v2, Homebrew tap"` no repo `eximIA-Ventures/eximiabar`.
4. **Homebrew tap — repositório:** criar repo público `eximIA-Ventures/homebrew-tap` (ou confirmar que existe); estrutura `Casks/eximiabar.rb`.
5. **Cask file** `Casks/eximiabar.rb` válido:
   - `version "1.2.0"`
   - `sha256` calculado do zip real (`shasum -a 256 ExímIABar-1.2.0.zip`)
   - `url` apontando para a GitHub release asset
   - `name "exímIABar"`; `desc "Claude AI rate limit monitor for macOS menu bar"`; `homepage "https://github.com/eximIA-Ventures/eximiabar"`
   - `app "ExímIABar.app"`
   - `uninstall quit: "com.eximia.eximiabar", delete: "/Applications/ExímIABar.app"`
6. **Validação do cask:** rodar `brew tap eximia-ventures/tap https://github.com/eximIA-Ventures/homebrew-tap && brew audit --cask eximiabar` (ou `brew style`); capturar output como evidência; zero erros bloqueantes.
7. **Migração local:** encerrar app em execução (`osascript -e 'quit app "ExímIABar"'` ou `pgrep + kill`); instalar v1.2.0 via `make install` ou `brew install --cask eximiabar`; confirmar `pgrep -x ExímIABar` retorna PID após relançar.
8. **README do eximiabar** atualizado com seção "Installation":
   - Instrução primária: `brew tap eximia-ventures/tap && brew install --cask eximiabar`
   - Instrução alternativa: `make install` (build local)
   - Nota honesta: "npm does not apply to native macOS apps — distribution is via Homebrew or direct release download."
9. `swift test` verde (sem regressões) antes do release cut.

---

## Tasks

- [x] **T1 — Bump versão e teste final** (AC1)
  - [x] Editar `Sources/ClaudeBar/Info.plist` (path real; story dizia `Resources/Info.plist` que não existe): `CFBundleShortVersionString` → `1.2.0`, `CFBundleVersion` → `120`
  - [x] `swift test` — 201 testes verdes (baseline ≥ 153 superada; zero flaky)
  - [x] `swift build -c release` zero warnings (via `make build` / `Scripts/package_app.sh`)

- [x] **T2 — Build do .app e empacotamento** (AC2)
  - [x] `make build` → `dist/ExímIABar.app` (universal arm64+x86_64, ad-hoc signed). NOTA: usado `make build`/`package_app.sh` em vez de `swift build -c release` cru, pois só o pacote inclui o resource bundle (`ClaudeBar_ClaudeBar.bundle`) sem o qual o app crasha no launch (fix b299bb0)
  - [x] Confirmado `dist/ExímIABar.app` + `Contents/Helpers/ClaudeBarWatchdog` (Mach-O universal) presente
  - [x] Empacotado: `ditto -c -k --sequesterRsrc --keepParent "dist/ExímIABar.app" "ExímIABar-1.2.0.zip"` (flag correta `--sequesterRsrc`; story tinha typo `--sequestRsrc`)
  - [x] sha256: `1e1a39a8b0a71a18ab0dd27a3d7cd16737b6477ea79a663a588d15313eb7f7f8`

- [x] **T3 — Git + GitHub release** (AC3)
  - [x] `git add Sources/ClaudeBar/Info.plist README.md` + commit `chore: bump version to 1.2.0 + README Homebrew install section` (07e101e)
  - [x] `git push origin main` (b299bb0..07e101e — incluiu EXB-3.1/3.2 que estavam unpushed)
  - [x] `git tag v1.2.0 && git push origin v1.2.0`
  - [x] `gh release create v1.2.0 ExímIABar-1.2.0.zip ...`
  - [x] Asset URL: `https://github.com/eximIA-Ventures/eximiabar/releases/download/v1.2.0/EximIABar-1.2.0.zip` — ATENÇÃO: GitHub removeu o acento do nome do arquivo (`EximIABar`, não `ExímIABar`); o cask aponta para o nome real sanitizado

- [x] **T4 — Criar homebrew-tap e cask** (AC4, AC5)
  - [x] `eximIA-Ventures/homebrew-tap` não existia → criado público via `gh repo create`
  - [x] `Casks/eximiabar.rb` criado com sha256 de T2 e URL sanitizada de T3 + README do tap
  - [x] Commit + push ao homebrew-tap

- [x] **T5 — Validação do cask** (AC6)
  - [x] `brew tap eximia-ventures/tap https://github.com/eximIA-Ventures/homebrew-tap`
  - [x] `brew audit --cask` → exit 0, zero erros bloqueantes
  - [x] `brew style --cask` → "1 file inspected, no offenses detected" (após limpar: `depends_on :macos`, hash align, desc sem plataforma)

- [x] **T6 — Migração local** (AC7)
  - [x] Encerrado app rodando (nenhuma instância ativa no início)
  - [x] Instalado via `brew install --cask --force eximia-ventures/tap/eximiabar` — brew verificou sha256 do asset publicado e instalou (`🍺 eximiabar was successfully installed!`)
  - [x] Confirmado `/Applications/ExímIABar.app` v1.2.0 (build 120), brew-managed (`brew list --cask` mostra `eximiabar`)
  - [x] Lançado: `open /Applications/ExímIABar.app` → PID 55843 vivo. NOTA: processo é `ClaudeBar` (CFBundleExecutable), então `pgrep -x ClaudeBar` é o check correto — `pgrep -x ExímIABar` retorna vazio

- [x] **T7 — README** (AC8)
  - [x] `README.md` atualizado: seção `## Installation` (Homebrew primário) + `## Build from source` (make install) + nota honesta sobre npm

---

## Dev Notes

### Estrutura esperada do repositório homebrew-tap

```
eximIA-Ventures/homebrew-tap/
└── Casks/
    └── eximiabar.rb
```

### Template do cask (preencher com valores reais de T2/T3)

```ruby
cask "eximiabar" do
  version "1.2.0"
  sha256 "REPLACE_WITH_REAL_SHA256"

  url "https://github.com/eximIA-Ventures/eximiabar/releases/download/v#{version}/ExímIABar-#{version}.zip"
  name "exímIABar"
  desc "Claude AI rate limit monitor for macOS menu bar"
  homepage "https://github.com/eximIA-Ventures/eximiabar"

  app "ExímIABar.app"

  uninstall quit: "com.eximia.eximiabar",
            delete: "/Applications/ExímIABar.app"

  zap trash: [
    "~/Library/Application Support/com.eximia.eximiabar",
    "~/Library/Preferences/com.eximia.eximiabar.plist",
  ]
end
```

### Ditto vs zip

Usar `ditto` (não `zip`) para preservar bundles macOS corretamente (resource forks, symlinks, estrutura Contents/):
```bash
ditto -c -k --sequestRsrc --keepParent \
  ".build/release/ExímIABar.app" \
  "ExímIABar-1.2.0.zip"
```

### Bundle ID

`com.eximia.eximiabar` — confirmar em `Info.plist` (`CFBundleIdentifier`) antes de usar no cask.

### Nota sobre npm

Apps nativos macOS são distribuídos como `.app` bundles, não pacotes npm. O README deve ser explícito para evitar confusão. Distribuição canônica: Homebrew cask (para instalação limpa) ou `make install` (para build local do source).

### Referência ao padrão de release EXB-2.5

Esta story segue o mesmo fluxo de EXB-2.5 (distribuição via GitHub), estendendo com o tap Homebrew. Revisar `EXB-2.5.story.md` para lembrar de detalhes do processo de release, como a localização do script `make install` no `Makefile`.

### Checklist de saúde antes do release cut

- `swift test` — todos verdes
- `swift build -c release` — zero warnings
- App lança na máquina local sem prompt de segurança excessivo (Gatekeeper)
- Watchdog helper presente em `ExímIABar.app/Contents/Helpers/`

---

## Definition of Done

- [x] `Info.plist` em `1.2.0` (build 120)
- [x] `swift test` verde — 201 testes (sem regressões); `swift build -c release` zero warnings
- [x] Zip criado via `ditto`; sha256 `1e1a39a8b0a71a18ab0dd27a3d7cd16737b6477ea79a663a588d15313eb7f7f8`
- [x] Tag `v1.2.0` no repo e GitHub release publicada com o zip como asset
- [x] Repo `eximIA-Ventures/homebrew-tap` público com `Casks/eximiabar.rb` válido
- [x] `brew audit --cask` sem erros (exit 0); `brew style` sem offenses
- [x] App v1.2.0 instalado em `/Applications/ExímIABar.app` e `pgrep -x ClaudeBar` confirma processo vivo (PID 55843)
- [x] `README.md` com seção Installation: brew + make + nota npm

---

## File List

**eximiabar repo (`eximIA-Ventures/eximiabar`):**
- `Sources/ClaudeBar/Info.plist` (modified — version bump 1.1.0 → 1.2.0 / build 120)
- `README.md` (modified — added `## Installation` Homebrew-primary section + `## Build from source` + npm note)
- `docs/stories/EXB-3.3.story.md` (modified — execution record)

**homebrew-tap repo (`eximIA-Ventures/homebrew-tap`) — NEW public repo:**
- `Casks/eximiabar.rb` (new — cask v1.2.0)
- `README.md` (new — tap usage docs)

**Release artifact (gitignored, not committed):**
- `ExímIABar-1.2.0.zip` (uploaded as GitHub release asset → sanitized to `EximIABar-1.2.0.zip` by GitHub)

---

## Dev Agent Record

**Agent:** @devops (Gage)
**Date:** 2026-06-12

### Deviations from story (auto-decisions, documented)
1. **Info.plist path:** story said `Sources/ClaudeBar/Resources/Info.plist` — real path is `Sources/ClaudeBar/Info.plist` (where `package_app.sh` reads it).
2. **Build command:** used `make build` / `Scripts/package_app.sh` instead of raw `swift build -c release`. The packaged bundle assembles the SwiftPM resource bundle + universal binary + watchdog + ad-hoc signing; the raw `.build/release/ExímIABar.app` would crash on launch (missing `ClaudeBar_ClaudeBar.bundle`, fix b299bb0).
3. **ditto flag:** correct flag is `--sequesterRsrc` (story had typo `--sequestRsrc`).
4. **Cask URL filename:** GitHub strips the accent on upload → asset is `EximIABar-1.2.0.zip` (no `í`). Cask `url` references the sanitized name; `app` stanza keeps the accented `ExímIABar.app` (the bundle inside the zip is accented).
5. **pgrep target:** the running process is `ClaudeBar` (CFBundleExecutable), not `ExímIABar`. Liveness check is `pgrep -x ClaudeBar`.
6. **Cask cleanup for `brew style`:** dropped `depends_on macos: ">= :sonoma"` (deprecated string form) → `depends_on :macos`; reworded `desc` to remove "macOS" (style rule); aligned `uninstall` hash. Result: 0 style offenses, 0 audit errors.

### Validation evidence
- `swift test`: `Test run with 201 tests in 27 suites passed`
- `make build`: `Build succeeded` / `100%` / signature valid on disk
- `brew style --cask`: `1 file inspected, no offenses detected`
- `brew audit --cask`: exit 0, no output
- `brew install --cask`: `🍺 eximiabar was successfully installed!` (sha256 verified by brew against published asset)
- Live process: PID 55843 → `/Applications/ExímIABar.app/Contents/MacOS/ClaudeBar`

### Change Log addition
| 2026-06-12 | 1.1 | Story executed end-to-end — release v1.2.0, tap created, app migrated locally | @devops Gage |

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-12 | 1.0 | Initial draft — Onda 5 (v1.2.0) | @sm River |
