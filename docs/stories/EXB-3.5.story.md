# Story EXB-3.5: Liquid Glass Nativo (macOS 26)

**ID:** EXB-3.5
**Status:** Done
**Depends on:** EXB-3.1 (TransparencyLevel enum + Appearance pane + SettingsStore wiring), EXB-1.3 (NSPanel architecture)
**Epic:** EPIC-EXB
**Wave:** Onda 6 (v1.3.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** user on macOS 26 (Tahoe),
**I want** the popover, Settings window, and Dashboard to use the native Liquid Glass effect introduced in macOS 26,
**so that** the app feels at home on the new OS while degrading gracefully to the existing NSVisualEffectView glass on macOS < 26.

---

## Acceptance Criteria

1. **Painel (UsagePanelController):** em `#available(macOS 26.0, *)`, substituir o `NSVisualEffectView` por `NSGlassEffectView`; o `hostingView` (NSHostingView com o SwiftUI content) é instalado como `contentView` da glass view, não como irmão; `cornerRadius` igual ao valor atual do `PopoverStyle`; `style` mapeado da preferência `TransparencyLevel`: `.standard → NSGlassEffectView.Style.regular`, `.frosted → NSGlassEffectView.Style.clear`. Em macOS < 26: comportamento atual (NSVisualEffectView com material determinado por `TransparencyLevel`) preservado sem alterações.
2. **Settings window (SettingsWindowController):** mesma adoção condicional com `#available(macOS 26.0, *)`; em macOS 26 usar `NSGlassEffectView` com `hostingView` como `contentView`; em macOS < 26 manter `NSVisualEffectView.underWindowBackground`.
3. **Dashboard window (DashboardWindowController):** idem; adoção condicional; fallback para comportamento atual de EXB-2.3/3.2.
4. **Mapeamento `TransparencyLevel` → efeito macOS 26:**
   - `.opaque` → sem glass (manter fundo sólido como hoje — `NSVisualEffectView` removido ou `isHidden = true`)
   - `.standard` → `NSGlassEffectView` com `style: .regular`
   - `.frosted` → `NSGlassEffectView` com `style: .clear`
   Os labels do Picker na `AppearancePaneView` podem ser atualizados para melhor descrever os novos efeitos (ex: "Líquido" para `.clear`) — manter exatamente 3 níveis, aplicação imediata.
5. **Janela hospedeira** permanece borderless e transparente: `isOpaque = false`, `backgroundColor = .clear` — o vidro é da view, não da janela. Não alterar a estrutura de `NSPanel` da EXB-1.3.
6. **Legibilidade do conteúdo:** auditar textos secundários (`foregroundStyle(.secondary)`, `.tertiary`) nas views do popover e Settings em dark e light mode sobre o vidro líquido; se contraste insuficiente, ajustar para `.primary` ou adicionar `.shadow(radius: 1)` cirurgicamente.
7. **Testes:** teste do mapeamento `TransparencyLevel → NSGlassEffectView.Style` (os 3 casos) para macOS 26; build em macOS 26 sem warnings de deprecation; `swift test` sem regressões.

---

## Tasks

- [x] **T1 — Verificar API no SDK local** (pré-requisito — não pular)
  - [x] `find $(xcrun --show-sdk-path) -name "NSGlassEffectView.h"` — header presente: `…/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h`
  - [x] grep AppKit headers — propriedades confirmadas (ver Dev Notes → "API confirmada via SDK local")
  - [x] Documentado nos Dev Notes (nomes de propriedades + `API_AVAILABLE(macos(26.0))` + `NS_SWIFT_NAME`)
  - [x] SwiftUI `.glassEffect(_:in:)` — informativo, não usado (AppKit `NSGlassEffectView` é a via adotada)

- [x] **T2 — Extensão do SettingsStore / TransparencyLevel** (AC4)
  - [x] `glassStyle: NSGlassEffectView.Style?` (`@available(macOS 26.0, *)`) em `TransparencyLevel`: `.opaque → nil`, `.standard → .regular`, `.frosted → .clear`
  - [x] Labels do Picker mantidos (decisão `[AUTO-DECISION]`): `Opaque/Standard/Frosted` (en) e `Opaco/Padrão/Vidro` (pt-BR) já descrevem bem os efeitos; "Vidro" já é apto para `.clear`/Liquid. Alterar quebraria 4 testes existentes sem ganho funcional → T7 fica N/A.

- [x] **T3 — UsagePanelController: adoção de NSGlassEffectView** (AC1, AC5)
  - [x] Helper `GlassEffectBridge.makeGlassView(contentView:cornerRadius:style:)` em `Sources/ClaudeBar/Support/GlassEffectBridge.swift`
  - [x] `applyTransparency` é o ponto de adoção `if #available(macOS 26.0, *) { glass } else { NSVisualEffectView existente }` (chamado no init para semear)
  - [x] `hostingView` instalado como `glassView.contentView` (NÃO addSubview) — verificado em runtime (`GlassRuntimeSmoke`)
  - [x] `applyTransparency` atualizado: macOS 26 → swap `glassView.style` / route `.opaque` ao effectView; macOS < 26 → swap `effectView.material`

- [x] **T4 — SettingsWindowController: adoção de NSGlassEffectView** (AC2, AC5)
  - [x] `if #available(macOS 26.0, *) { NSGlassEffectView } else { NSVisualEffectView }` em `applyTransparency` (semeado em `open()`)
  - [x] `applyTransparency` com ambos os branches; `.opaque` → `NSVisualEffectView(.underWindowBackground)`
  - [x] `isOpaque = false`, `backgroundColor = .clear` permanecem (AC5)

- [x] **T5 — DashboardWindowController: adoção de NSGlassEffectView** (AC3, AC5)
  - [x] Adoção condicional; Dashboard é `NSWindow` — host vira `glassView.contentView`; fallback < 26 = content view simples (EXB-2.3/3.2)
  - [x] `isOpaque = false`/`.clear` no caminho glass; `.opaque`/`< 26` mantêm o content view simples. Provider de transparência ligado em `ClaudeBarApp` (live + seed)

- [x] **T6 — Legibilidade** (AC6)
  - [x] Grep por `.secondary`/`.tertiary` em Popover/ e Settings/ — hits listados nos Dev Notes
  - [x] Auditoria: valores críticos (percentuais, custo de hoje/30d, tokens, títulos, pace primário) já são `.primary`; `.secondary` cobre apenas labels auxiliares (reset time, pace secundário, sub-linhas por modelo) — nível semântico correto e vibrancy-aware sobre Liquid Glass
  - [x] Conclusão (documentada nos Dev Notes): nenhum override necessário — forçar `.primary` achataria a hierarquia visual e contraria a guideline de Liquid Glass da Apple

- [x] **T7 — Localização** — N/A (labels mantidos em T2; nenhuma string alterada)

- [x] **T8 — Testes** (AC7)
  - [x] `Tests/ClaudeBarTests/GlassEffectTests.swift`: mapeamento `.standard→.regular`, `.frosted→.clear`, `.opaque→nil`, paridade glass/material e wiring do bridge (contentView/cornerRadius/style)
  - [x] `Tests/ClaudeBarTests/GlassRuntimeSmoke.swift` (extra): drive do `UsagePanelController` real — glass como contentView do panel, host dentro do subtree do glass, transição glass↔opaque↔glass
  - [x] `swift build -c release` zero warnings (rebuild limpo: `WARNING_COUNT: 0`)
  - [x] `swift test --no-parallel` sem regressões — 212 testes / 30 suites verdes (baseline 201 + EXB-3.6 + 5 novos)

---

## Dev Notes

### API confirmada (tratar como fato — fornecida pelo orquestrador)

```
Header: NSGlassEffectView.h
Disponibilidade: API_AVAILABLE(macos(26.0))

NSGlassEffectView : NSView
  var contentView: NSView?         // a view que vai DENTRO do vidro
  var cornerRadius: CGFloat
  var tintColor: NSColor?          // optional tint
  var style: NSGlassEffectView.Style

NSGlassEffectView.Style
  .regular   // vidro padrão (equivalente a .popover frosted)
  .clear     // vidro límpido (máximo translucidez — Liquid Glass)

NSGlassEffectContainerView : NSView  (macos 26)
  var spacing: CGFloat             // merge visual de efeitos próximos

SwiftUI: .glassEffect(_:in:)       // disponível em macOS 26 para views internas
```

O dev DEVE confirmar os nomes exatos das propriedades via `grep` no SDK antes de codificar (T1). Se alguma propriedade diferir do fornecido acima, usar o nome real do SDK.

#### API confirmada via SDK local (T1 — output real, macOS 26.3.1 / Swift 6.2.3)

Header: `…/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h`

```objc
typedef NS_ENUM(NSInteger, NSGlassEffectViewStyle) {
    NSGlassEffectViewStyleRegular,   // → Swift: NSGlassEffectView.Style.regular
    NSGlassEffectViewStyleClear      // → Swift: NSGlassEffectView.Style.clear
} API_AVAILABLE(macos(26.0)) NS_SWIFT_NAME(NSGlassEffectView.Style);

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectView: NSView
@property (nullable, strong) __kindof NSView *contentView;   // a view DENTRO do vidro
@property CGFloat cornerRadius;
@property (nullable, copy) NSColor *tintColor;
@property NSGlassEffectViewStyle style;
@end

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectContainerView: NSView   // não usado nesta story
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat spacing;
@end
```

Confere 100% com o bloco "API confirmada" fornecido pelo orquestrador. Nota crítica do header (citada literalmente): *"NSGlassEffectView only guarantees the contentView will be placed inside the glass effect; arbitrary subviews aren't guaranteed specific behavior with regard to z-order"* — por isso TODO host é instalado via `contentView`, nunca `addSubview`.

#### Descobertas de runtime (verificadas em macOS 26.3.1, não documentadas no header)

1. **Propagação de tamanho:** com o host usando `translatesAutoresizingMaskIntoConstraints = false`, `NSGlassEffectView` propaga o *fitting size* do host para cima (como o NSVisualEffectView com constraints). Probe: panel 200pt → 452pt após `glass.contentView = host`. **Logo o painel continua sendo dimensionado pelo SwiftUI (AC2/AC20).** Setar autoresizing no host quebraria isso (clip/altura fixa).
2. **`_ContentHolderView`:** o glass embrulha o `contentView` numa view privada `_ContentHolderView`. Portanto `host.superview` é o holder, não o glass; `glass.contentView` (a property) retorna o host corretamente. O teste de runtime usa `host.isDescendant(of: glass)` em vez de identidade exata de superview.

#### Auditoria de legibilidade (AC6) — conclusão

Hits de `.secondary`/`.tertiary`: `MetricRow.swift` (reset time, pace secundário), `UsageCardView.swift` (labels, chevron, sub-linhas por modelo), panes de Settings (subtítulos/labels via componentes compartilhados). **Os valores contraste-críticos já são `.primary`** (sem `.foregroundStyle`): percentuais (`popover.metric.percent_left`), custo de hoje/30d (`popover.cost.today`/`.last_30_days`), contagens de tokens, títulos de seção, pace primário. Os hits `.secondary` são exclusivamente labels auxiliares — nível semântico correto e *vibrancy-aware*, que é a escolha recomendada pela Apple sobre Liquid Glass. **Nenhum override aplicado:** forçar `.primary` achataria a hierarquia visual e contrariaria a design language do macOS 26.

### File List

**Novos:**
- `Sources/ClaudeBar/Support/GlassEffectBridge.swift` — helper `@MainActor` `makeGlassView(contentView:cornerRadius:style:)` (`@available(macOS 26.0, *)`)
- `Tests/ClaudeBarTests/GlassEffectTests.swift` — mapeamento `TransparencyLevel → glassStyle` (3 casos) + paridade + wiring do bridge
- `Tests/ClaudeBarTests/GlassRuntimeSmoke.swift` — smoke de runtime do `UsagePanelController` real (glass como contentView, transições)

**Modificados:**
- `Sources/ClaudeBar/App/SettingsStore.swift` — `glassStyle` computed var em `TransparencyLevel`
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — adoção condicional NSGlassEffectView + `applyTransparency` OS-aware + re-parent do host
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — idem (host retido para re-parent; cornerRadius 0)
- `Sources/ClaudeBar/Dashboard/DashboardWindowController.swift` — idem + `transparencyProvider` para semear/atualizar o glass
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — wiring do `transparencyProvider` do dashboard + dashboard no callback `onTransparencyChange` live

**Sem alteração (decisão T2/T7):** `AppearancePaneView.swift`, `en.lproj`/`pt-BR.lproj/Localizable.strings` (labels mantidos).

### Padrão de wiring (ContentView dentro de NSGlassEffectView)

```swift
@available(macOS 26.0, *)
private func setupGlassPanel() {
    let glassView = NSGlassEffectView()
    glassView.cornerRadius = 12  // mesmo valor do PopoverStyle
    glassView.style = settings.transparencyLevel.glassStyle
    glassView.frame = panel.contentView!.bounds
    glassView.autoresizingMask = [.width, .height]

    let hostingView = NSHostingView(rootView: UsageCardView(...))
    glassView.contentView = hostingView      // ← chave: contentView, não addSubview

    panel.contentView = glassView
    panel.isOpaque = false
    panel.backgroundColor = .clear
}
```

### Mapeamento TransparencyLevel → efeito por OS

| TransparencyLevel | macOS < 26 | macOS 26 |
|---|---|---|
| `.opaque` | NSVisualEffectView oculto / fundo sólido | idem (sem NSGlassEffectView) |
| `.standard` | `NSVisualEffectView(.popover)` | `NSGlassEffectView(.regular)` |
| `.frosted` | `NSVisualEffectView(.hudWindow)` | `NSGlassEffectView(.clear)` |

### Anti-freeze invariants

- A troca de glass style (`glassView.style = newStyle`) é AppKit puro em `@MainActor` — zero I/O, correto
- `SettingsStore` callbacks via `onTransparencyChange` — mantidos do EXB-3.1; apenas adicionar o branch macOS 26 dentro de `applyTransparency`
- NSPanel architecture (EXB-1.3) intocada: `NSPanel` é o container; o NSGlassEffectView substitui o NSVisualEffectView como `contentView` do panel, não altera a classe do panel

### Auditoria de legibilidade (AC6) — hits esperados

Usar como ponto de partida:
```bash
grep -rn "\.secondary\|\.tertiary\|foregroundStyle" Sources/ClaudeBar/Popover/ --include="*.swift"
grep -rn "\.secondary\|\.tertiary\|foregroundStyle" Sources/ClaudeBar/Settings/ --include="*.swift"
```

Para cada hit: avaliar se o texto é legível sobre vidro translúcido. `MetricRow` (label + value pairs) e `UsageCardView` são os candidatos mais críticos.

### Source tree esperado

**Novo:**
- `Sources/ClaudeBar/Support/GlassEffectBridge.swift` (opcional — ou inline em cada controller)
- `Tests/ClaudeBarTests/GlassEffectTests.swift`

**Modificados:**
- `Sources/ClaudeBar/App/SettingsStore.swift` — `glassStyle` computed var em `TransparencyLevel`
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — `#available(macOS 26.0, *)` branch
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — idem
- `Sources/ClaudeBar/Dashboard/DashboardWindowController.swift` — idem
- `Sources/ClaudeBar/Settings/AppearancePaneView.swift` — atualizar labels se necessário
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — atualizar se labels mudaram
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — idem

### Testing

- Framework: Swift Testing ou XCTest (seguir padrão do repo)
- Arquivo: `Tests/ClaudeBarTests/GlassEffectTests.swift`
- `@available(macOS 26.0, *)` guard obrigatório nos testes de glass style
- Para código em `#else` (macOS < 26), confirmar que testes existentes do EXB-3.1 (`AppearanceTests.swift`) continuam passando — são exatamente esses testes que cobrem o fallback
- Baseline: 201 testes; zero regressões
- `swift test` serial (`--no-parallel`) para evitar flake de keychain

---

## Definition of Done

- [x] Painel usa `NSGlassEffectView` em macOS 26; `NSVisualEffectView` em macOS < 26
- [x] Settings window usa `NSGlassEffectView` em macOS 26; fallback preservado
- [x] Dashboard window usa `NSGlassEffectView` em macOS 26; fallback preservado
- [x] Mapeamento `TransparencyLevel → glassStyle` correto (3 casos)
- [x] Aplicação imediata ao mudar Appearance pane funciona em macOS 26 (callback `onTransparencyChange` → `applyTransparency` em painel/settings/dashboard; swap de `style` em runtime, verificado)
- [x] Janela permanece borderless/transparente em ambos os branches (NSPanel `isOpaque=false`/`.clear` intocados; AC5)
- [x] Textos secundários legíveis sobre vidro líquido (auditoria documentada nos Dev Notes — valores críticos já `.primary`)
- [x] `swift build -c release` zero warnings em macOS 26 (rebuild limpo: `WARNING_COUNT: 0`)
- [x] `swift test` sem regressões (baseline 201 testes); novos testes de glass style passando — 212 testes / 30 suites verdes

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-12 | 1.0 | Initial draft — Onda 6 (v1.3.0) | @sm River |
| 2026-06-12 | 1.1 | Implementação completa — NSGlassEffectView em painel/Settings/Dashboard com fallback macOS < 26; `glassStyle` mapping; GlassEffectBridge + 5 testes (incl. runtime smoke); auditoria de legibilidade. 212 testes verdes, 0 warnings. Status → Ready for Review | @dev Dex |
| 2026-06-12 | 1.2 | QA Gate PASS — Status: InReview → Done | @qa Quinn |

---

## QA Results — rodada 1

**Gate:** @qa (Quinn) · **Date:** 2026-06-12 · **Criterion:** RESULT, not API-presence (queimados 2x — esta story usa de fato `NSGlassEffectView`, e provei em runtime).

### Build & Tests (RAN, not trusted from the report)
- `swift build -c release` (clean rebuild, `.build/release` removed) → **Build complete! 0 warnings, 0 errors** ✅
- `swift test --no-parallel` (serial, to dodge keychain flake) → **212 tests / 30 suites PASS** in 3.185s ✅
- **Glass suite executed, not availability-skipped** (re-ran in isolation on macOS 26.3.1): `GlassEffectTests` (4 tests) + `GlassRuntimeSmoke` (1 test) → **5/5 PASS in 0.083s**. The `#available(macOS 26.0, *)` tests genuinely fired their assertions (not `0 tests`) — this machine is macOS 26, so the glass path was compiled AND executed.

### AC verification (result, file:line — not presence)

| AC | Verdict | Evidence (RESULT, not presence) |
|----|---------|--------------------------------|
| 1 — popover NSGlassEffectView, host as contentView, mapped style, < 26 fallback intact | ✅ | `UsagePanelController.swift:185-244`: `applyTransparency` branches on `#available(macOS 26.0,*)` → `applyGlassTransparency`. `installGlassBacking:238` builds glass via `GlassEffectBridge.makeGlassView(contentView: hostingView, …)` — host is the **glass `contentView`** (line 239), not a sibling. `cornerRadius = PopoverStyle.cornerRadius` (:201). Style from `glassStyle`. < 26 path (`effectView.material`, :188) untouched. **Proven end-to-end by `GlassRuntimeSmoke.panelAdoptsGlassAndHostsAsContentView`** — drives the real controller, asserts `glass.contentView === host`, `host.isDescendant(of: glass)`, style swaps `.clear→.regular`, and `.opaque` → `NSVisualEffectView`. |
| 2 — Settings window conditional adoption + < 26 `.underWindowBackground` | ✅ | `SettingsWindowController.swift:119-176`: glass path (:128) with host as `contentView` (:147); `.opaque`/`< 26` → `installEffectViewBacking` (:157) restores `NSVisualEffectView`. `cornerRadius:0` correct (titled-window frame supplies corners). |
| 3 — Dashboard conditional adoption + EXB-2.3/3.2 fallback | ✅ | `DashboardWindowController.swift:136-172`: glass path (:161) with host as `contentView`; `< 26` early-returns to plain hosting content view (:138); `.opaque` keeps plain content view + solid bg (:139-152). `transparencyProvider` seeds at construction (`ClaudeBarApp.swift:139`), live updates via `onTransparencyChange` (:191). |
| 4 — TransparencyLevel → glassStyle (3 casos) | ✅ | `SettingsStore.swift:159-166`: `.opaque→nil`, `.standard→.regular`, `.frosted→.clear`. **Unit-tested all 3** (`GlassEffectTests.transparencyLevelMapsToGlassStyle` + `opaqueLevelHasNoGlassStyle` + `glassAndMaterialMappingsAgreeOnOpaque` — the last guards the glass/material mappings from drifting). Picker labels kept — justified `[AUTO-DECISION]`, AC4 allows "podem ser atualizados". |
| 5 — window stays borderless/transparent | ✅ | Panel `isOpaque=false`/`backgroundColor=.clear` (`UsagePanelController.swift:96-97`) untouched; NSPanel structure (EXB-1.3) intact — diff shows no change to `KeyablePanel`/`configurePanel`. Settings/Dashboard set `isOpaque=false`/`.clear` on the glass path (`:170-171` dashboard). The glass is the **view**, not the window. |
| 6 — legibility audit (.secondary/.tertiary over glass) | ✅ | Audit documented (Dev Notes): contrast-critical values (percentuais, custo, tokens, títulos, pace primário) já `.primary`; `.secondary` só em labels auxiliares — nível vibrancy-aware correto sobre Liquid Glass. No override correct — forcing `.primary` flattens hierarchy and fights Apple's Liquid Glass guideline. |
| 7 — tests: mapping (3 casos) + no deprecation warnings + no regressions | ✅ | `GlassEffectTests` covers the 3-case mapping + bridge wiring (`bridgeInstallsContentViewAndStyle` asserts `contentView===content`, radius, style, autoresizing). Build is **0 warnings** (no deprecation). 212 tests green (baseline 201 + EXB-3.6 6 + 5 new). |

### Cross-cutting / invariants
- **Anti-freeze preserved** — `glassView.style = newStyle` is pure AppKit on `@MainActor`, zero I/O (same class of work as the EXB-3.1 `material` swap). The transition matrix (frosted→standard→opaque→frosted) re-parents the host with correct `translatesAutoresizingMaskIntoConstraints` handling: `false` for the glass path (so the host's fitting size propagates up — the documented runtime discovery that keeps the panel sized by SwiftUI), `false`+constraints for the effect-view path. **Verified by the runtime smoke's full transition cycle.** ✅
- **NSPanel-not-NSMenu** intact — the glass view replaces the `NSVisualEffectView` as the panel's `contentView`; the `NSPanel` class and run-loop architecture are untouched. ✅
- **Diff scope clean** — commit `53eb7ba` touches exactly the 9 declared files (5 source + 1 bridge + 2 tests + story). No application source outside the glass adoption; no scope creep. ✅
- **EXB-3.6 (bundled in working tree, re-checked per brief)** — filter→scan→aggregation→chart chain re-traced line-by-line: `period.days` drives `span`/`isWithinWindow`; `scanReturnsDistinctDataPerPeriod` proves 7/30/90 yield genuinely distinct data (200≠600 tokens, 1≠2 rows); aggregation in `Task.detached(.utility)` off-main (`DashboardWindowController.loadData:205`); formatters all `static let` (`DashboardFormat`/`TopSessionsTable.dateFormatter`), none in `body`; downsampling structurally satisfied (≤90 pts/series at 90d). 3.6 already PASSED its own round 1 — no regression from 3.5 (3.5 diff doesn't touch Dashboard data/view, only the glass backing). ✅

### Concerns (non-blocking)
1. **Visual validation pending** — Liquid Glass legibility/appearance over real desktop content (dark + light) is a human judgment the dev correctly flagged. The code is sound; final visual sign-off is Hugo's. Not a code defect.
2. **`NSGlassEffectContainerView` not used** — single glass surface per window; the `spacing`-based merge of adjacent effects is unused. Correct for this UI (one card per surface); no action.

### Decision
All 7 ACs implemented and verified **by result** — the glass path was compiled AND executed on macOS 26.3.1, the runtime smoke proves the real controller wires `NSGlassEffectView` with the host as its `contentView` and swaps style correctly, the < 26 fallback is intact, and the 3-level mapping is unit-pinned. Build clean (0 warnings), 212 tests green serially, anti-freeze + NSPanel invariants preserved, diff scope tight. The two concerns are a pending human visual sign-off (correctly flagged) and an unused-API note — neither blocking.

Gate: PASS → docs/qa/gates/EXB-3.5-liquid-glass-macos-26.yml

VERDICT: PASS
