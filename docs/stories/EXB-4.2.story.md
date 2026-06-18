# Story EXB-4.2: Ícone Customizado do App

**ID:** EXB-4.2
**Status:** Ready for Review
**Depends on:** EXB-4.1 (pode ser paralelizado — não há dependência de código; depende da wave estar estabilizada)
**Epic:** EPIC-EXB
**Wave:** Onda 9 (v1.6.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** macOS user who has exímIABar installed,
**I want** a distinctive app icon that reflects both the eximIA brand and the concept of a rate-limit gauge,
**so that** the app looks professional in Finder, Dock, Spotlight, and the About screen instead of showing a generic placeholder.

---

## Acceptance Criteria

### AC1 — Conceito visual do ícone

1. O ícone usa um **fundo squircle** no estilo macOS Big Sur+ (forma padrão do sistema para app icons).
2. O fundo tem profundidade/gradiente escuro (ex: `#1A1A1A` → `#2D2D2D`, radial ou linear), não flat.
3. Um **arco/anel de medidor (gauge arc)** em terracota `#CC7C5E` ocupa ~70% da circunferência, representando visualmente o conceito de rate-limit. O arco é preenchido e começa das ~8h (sentido horário) indo até ~5h, deixando a lacuna na posição das 6h.
4. O **símbolo eximIA** (`/Users/hugocapitelli/Dev/eximia/JARVIS/LOGO/SVG/SIMBOLO.svg`) é centralizado no ícone, em branco ou tom claro (#F5F5F5), legível sobre o fundo escuro. O símbolo é rasterizado do SVG original — NUNCA redesenhado à mão.

### AC2 — Pipeline de geração dependency-free

5. O script de geração localiza-se em `Scripts/generate_icon.sh` (estender o script existente se houver, criar se não houver).
6. O pipeline usa **apenas ferramentas disponíveis em macOS sem instalação**: `sips`, `rsvg-convert` ou `qlmanage` para rasterizar SVG, `iconutil` para construir o `.icns`. Se `rsvg-convert` não estiver disponível, usar `qlmanage -t -s {size} -o {dir}` como fallback para rasterização do SVG. **Proibido**: ImageMagick, Inkscape, Node.js, Python com dependências externas.
7. O script gera o iconset completo: `icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`, `icon_32x32@2x.png`, `icon_64x64.png` (se necessário), `icon_128x128.png`, `icon_128x128@2x.png`, `icon_256x256.png`, `icon_256x256@2x.png`, `icon_512x512.png`, `icon_512x512@2x.png`, `icon_512x512@2x.png`.
8. O script executa `iconutil -c icns {iconset_dir} -o {output_icns}` para produzir `AppIcon.icns`.
9. O script é idempotente: pode ser executado múltiplas vezes sem deixar artefatos intermediários.

### AC3 — Integração no projeto

10. O `AppIcon.icns` gerado substitui o atual em `Sources/ClaudeBar/Resources/AppIcon.icns` (ou path equivalente no projeto).
11. O `Info.plist` aponta para `AppIcon` (sem extensão, como é padrão do macOS) — verificar se já está correto; corrigir se necessário.
12. `swift build -c release` zero warnings com o novo ícone no bundle.

### AC4 — Legibilidade

13. Em 128px (Finder), o símbolo eximIA é reconhecível e o arco de gauge é visível.
14. Em 16px (menu bar não usa, mas Spotlight usa), a silhueta do fundo squircle + cor terracota do arco é distinguível.
15. O ícone funciona em modo claro e escuro do macOS (fundo escuro já funciona em ambos).

### AC5 — Documentação

16. O script `generate_icon.sh` documenta no cabeçalho: (a) conceito visual aplicado, (b) toolchain usada, (c) path do SVG de origem, (d) como executar.

---

## Tasks

- [x] **T1 — Preparar o SVG do símbolo eximIA** (AC1, AC4)
  - [x] Ler o arquivo `/Users/hugocapitelli/Dev/eximia/JARVIS/LOGO/SVG/SIMBOLO.svg`
  - [x] Confirmar que é um SVG válido, sem dependências de fonte ou imagens externas
  - [x] Copiar para `Scripts/assets/eximia-simbolo.svg` (recursos do pipeline de ícone)

- [x] **T2 — Criar composição do ícone** (AC1, AC2)
  - [x] Gerar PNG de base (fundo squircle + gradiente escuro) via CoreGraphics (`swift`) — gradiente vertical `#2D2D2D→#1A1A1A` + highlight radial sutil
  - [x] Compor o arco do gauge em `#CC7C5E` via CoreGraphics `addArc` (lineCap `.round`, sweep horário ~234°→306° deixando o gap nas 6h, stroke-width proporcional)
  - [x] Compor o símbolo eximIA no centro: paths do `eximia-simbolo.svg` parseados e desenhados em `#F5F5F5`, centralizados e escalados preservando aspect ratio
  - [x] Resultado: PNG de composição em 1024×1024 px

- [x] **T3 — Escrever `Scripts/generate_icon.sh`** (AC2, AC5)
  - [x] Gerar todos os tamanhos via `sips -z {h} {w}` a partir do master 1024×1024
  - [x] Criar `AppIcon.iconset/` (sob temp dir) com os arquivos nomeados conforme Apple conventions
  - [x] Executar `iconutil -c icns AppIcon.iconset -o AppIcon.icns`
  - [x] Limpeza de temporários via `trap cleanup EXIT`; cabeçalho de documentação (conceito, toolchain, source, how-to-run)
  - [x] Testar que o script é executável (`chmod +x`) e idempotente (hashes byte-idênticos em 2 runs)

- [x] **T4 — Integrar no projeto** (AC3)
  - [x] `Sources/ClaudeBar/Resources/AppIcon.icns` substituído (path confirmado em `Package.swift` `resources:`)
  - [x] `Info.plist` → `CFBundleIconFile = AppIcon` confirmado (já correto; verificado também no bundle gerado)
  - [x] `EXIMIA_SIGN_IDENTITY="eximIA Code Signing" make build` zero warnings; `swift build -c release` zero warnings

- [x] **T5 — Verificação visual** (AC4)
  - [x] Extraído o `.icns` (`iconutil -c iconset`) e inspecionados 512px / 128px / 32px / 16px
  - [x] Confirmado: símbolo legível e arco visível em 128px; silhueta squircle + terracota distinguíveis em 16px

---

## Dev Notes

### Assets de origem

| Asset | Path |
|-------|------|
| Símbolo eximIA (SVG) | `/Users/hugocapitelli/Dev/eximia/JARVIS/LOGO/SVG/SIMBOLO.svg` |
| Logos PNG (alternativas) | `/Users/hugocapitelli/Dev/eximia/JARVIS/LOGO/PNG/` |
| Cor terracota da marca | `#CC7C5E` (R:204 G:124 B:94) |
| Cor de fundo escuro | `#1A1A1A` → `#2D2D2D` (sugestão) |
| Cor do símbolo no ícone | `#F5F5F5` (quase branco) |

### Toolchain dependency-free (macOS built-ins)

```bash
# Rasterizar SVG → PNG (opção A: rsvg-convert, se disponível)
rsvg-convert -w 1024 -h 1024 input.svg -o output.png

# Rasterizar SVG → PNG (opção B: qlmanage fallback)
qlmanage -t -s 1024 -o /tmp/icon_dir/ input.svg
# produz input.svg.png — renomear

# Redimensionar PNG
sips -z 512 512 input.png --out output.png

# Construir .icns a partir de iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

### Composição do arco via SVG

O arco do gauge pode ser gerado como um SVG standalone com `path` e depois rasterizado:

```svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <!-- Fundo squircle: usar rect com rx/ry grande ou clip-path -->
  <rect x="0" y="0" width="100" height="100" rx="22" ry="22" fill="#1E1E1E"/>
  <!-- Arco gauge: aproximado via path Arc com stroke -->
  <path d="M 20 75 A 35 35 0 1 1 80 75"
        fill="none" stroke="#CC7C5E" stroke-width="8" stroke-linecap="round"/>
  <!-- Símbolo eximIA: <image> referenciando o SVG externo ou inline -->
</svg>
```

O squircle real (superellipse) do macOS Big Sur pode ser aproximado com `rx="22.37%"` num rect 100×100 — suficientemente próximo para um ícone de app.

### Onde fica o ícone no projeto

Buscar no Package.swift por `resources:` ou em `.xcassets`. Em projetos SwiftPM puros (sem Xcode project), o recurso tipicamente está em:
- `Sources/ClaudeBar/Resources/AppIcon.icns` — verificar se este path existe no código atual antes de substituir.

### Build e test

- Sem novos testes unitários requeridos (ícone é asset visual, não lógica)
- `swift build -c release` deve continuar zero warnings
- `swift test --no-parallel` sem regressões (223+ testes da baseline)
- Verificação manual: executar `make install` ou `swift build -c release` e abrir `.app` no Finder

---

## Definition of Done

- [x] `Scripts/generate_icon.sh` executável, documentado, idempotente
- [x] `AppIcon.icns` com 10 tamanhos gerados a partir do SVG símbolo eximIA real
- [x] Arco gauge `#CC7C5E`, fundo escuro squircle, símbolo eximIA centrado
- [x] `Info.plist` → `CFBundleIconFile = AppIcon` confirmado
- [x] `swift build -c release` zero warnings; ícone visível no bundle
- [x] Preview do `.icns` em 128px: símbolo reconhecível

---

## Dev Agent Record

### Agent Model Used
Opus 4.8 (1M context) — @dev (Dex)

### Implementation Notes / Decisões

**Abordagem de rasterização — desvio justificado vs. story Dev Notes.**
A story sugeriu `rsvg-convert`/`qlmanage` para rasterizar o SVG. Decisão: renderizar o
ícone **inteiro** via CoreGraphics (`swift`), incluindo o símbolo eximIA — parseando
diretamente os dois `<path>` do `eximia-simbolo.svg` com um mini-parser de path-data
(suporta `M m L l H h V v C c S s Z z`).

Razões (IDS — REUSE do padrão existente + ADAPT):
- `rsvg-convert` **não está disponível** nesta máquina (`which rsvg-convert` → not found);
  restariam só `qlmanage` (adiciona padding imprevisível, não recolore o fill `#231f20`
  para branco) — exigindo um segundo passo de tinting de qualquer forma.
- O repo **já tinha** o padrão CoreGraphics-via-swift no `generate_icon.sh` original
  (renderização do placeholder "eB"). Estender esse padrão é REUSE, não nova dependência.
- CoreGraphics dá controle preciso: recolor para `#F5F5F5`, gradiente do squircle, arco
  do gauge e centralização — tudo determinístico (hashes byte-idênticos entre runs).
- 100% dependency-free e dentro das ferramentas built-in sancionadas (swift + sips +
  iconutil). Nenhuma ferramenta proibida (ImageMagick/Inkscape/Node/Python-deps).

O símbolo é **rasterizado fielmente do SVG original** (nunca redesenhado à mão) — o
parser apenas converte os comandos de path do próprio arquivo da marca.

**Composição visual final:**
- Squircle (Big Sur grid: inset ~8.5%, corner radius 22.37% do lado) com gradiente
  vertical `#2D2D2D→#1A1A1A` + highlight radial sutil no topo (profundidade).
- Arco gauge `#CC7C5E`, raio 35.5% / largura 5.5% do squircle, lineCap round, sweep
  horário de ~234° (8h) a ~306° (4h) — gap centrado nas 6h (~108° / ~30%).
- Símbolo eximIA `#F5F5F5`, ocupando ~40% (box) centrado dentro do anel.

**Verificações:** idempotência (sha256 idêntico em 2 runs), zero artefatos residuais
(`trap cleanup EXIT` + temp dir), build assinado zero warnings, `.icns` válido no bundle
(`CFBundleIconFile=AppIcon`), 237 testes verdes (sem regressão; baseline 230+).

### Debug Log References
- `EXIMIA_SIGN_IDENTITY="eximIA Code Signing" make build` → Build succeeded, codesign valid, 0 warnings
- `swift build -c release` → 0 warnings
- `swift test --no-parallel` → Test run with 237 tests in 33 suites passed
- `generate_icon.sh` x2 → AppIcon.icns sha256 idêntico (idempotente)

### File List

**Added:**
- `Scripts/assets/eximia-simbolo.svg` — cópia do símbolo eximIA oficial (source do pipeline)

**Modified:**
- `Scripts/generate_icon.sh` — reescrito: composição CoreGraphics (squircle + gauge arc + símbolo SVG real), iconset via sips, .icns via iconutil; idempotente e documentado
- `Sources/ClaudeBar/Resources/AppIcon.icns` — regenerado a partir do símbolo eximIA real (10 tamanhos)
- `docs/stories/EXB-4.2.story.md` — tasks/DoD/Dev Agent Record/Change Log/Status

**Removed:**
- `Scripts/app-icon-source.png` — placeholder "eB" obsoleto (não mais referenciado)

### Completion Notes
- Todos os 16 ACs satisfeitos (AC1–AC5).
- `Info.plist` já apontava `CFBundleIconFile=AppIcon` — nenhuma correção necessária (AC3 #11).
- Strings: nenhuma string de UI nova introduzida (ícone é asset visual) — N/A para localização.
- Nenhum teste unitário novo (ícone é asset, não lógica) — alinhado às Dev Notes da story.
- Hugo valida o visual antes do release (commit local, sem push).

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
| 2026-06-18 | 1.1 | Implementação: ícone customizado (squircle dark + gauge arc terracota + símbolo eximIA real via CoreGraphics). All ACs done. 237 testes verdes. Status → Ready for Review | @dev Dex |
