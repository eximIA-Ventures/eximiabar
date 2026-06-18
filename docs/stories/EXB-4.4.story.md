# Story EXB-4.4: Menu Bar Inteligente + Hotkey Global

**ID:** EXB-4.4
**Status:** Ready for Review
**Depends on:** EXB-1.2 (StatusItemController, IconRenderer, MenuBarDisplayText — baseline da menu bar), EXB-1.5 (SettingsStore, Settings window — panes e preferências), EXB-4.3 (DisplaySnapshot.forecasts — para opção "tempo até reset")
**Epic:** EPIC-EXB
**Wave:** Onda 9 (v1.6.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** power user who keeps exímIABar always running,
**I want** to configure what the menu bar shows next to the icon and open the panel with a keyboard shortcut,
**so that** I get the information I care about at a glance and can summon the panel without moving the mouse.

---

## Acceptance Criteria

### AC1 — Preferência do conteúdo da menu bar

1. Em Settings → nova seção "Display" (ou "Menu Bar" se já existir), um segmented control ou picker oferece 5 opções de conteúdo:
   - `none` — apenas o ícone do medidor (comportamento atual)
   - `percentRemaining` — "87%" (sessão restante)
   - `timeUntilReset` — "2h34" (tempo até reset da sessão de 5h)
   - `costToday` — "$1.23" (custo do dia via CostScanner)
   - `sparkline` — mini-sparkline do uso recente (últimas horas)
2. A preferência é persistida em `SettingsStore.menuBarContent: MenuBarContent` (enum com os 5 casos acima; raw value String para Codable).
3. A alteração da preferência aplica-se **imediatamente** ao `NSStatusItem` sem reiniciar o app.

### AC2 — Mini-sparkline na menu bar

4. Quando `menuBarContent == .sparkline`, o `NSStatusItem` renderiza um mini-sparkline compacto dos últimos N pontos de utilização da sessão (N = últimas 6–8 amostras de `ExhaustionPredictor` ou `AppState`, o que estiver disponível).
5. O sparkline é desenhado via `NSBitmapImageRep` (mesmo padrão do `IconRenderer` — off-main, `isTemplate = true`) como uma sequência de segmentos de linha verticais, altura proporcional à utilização. Largura total <= 32px, altura <= 18px.
6. Se não houver amostras suficientes (<= 2 pontos), o sparkline exibe uma linha reta horizontal neutra — nunca crash ou espaço vazio inesperado.

### AC3 — Render do status item — padrão anti-freeze

7. O método `StatusItemController.updateContent(snapshot: DisplaySnapshot?)` calcula o texto/sparkline em `Task.detached`, constrói o `NSImage` ou `String` e aplica no `button` apenas no `@MainActor`. Zero I/O síncrono no main thread.
8. O render do sparkline segue o padrão do `IconRenderer`: `NSBitmapImageRep` desenhado off-main, imagem retornada como `NSImage` com `isTemplate = true`.

### AC4 — Hotkey global configurável

9. O app registra um **atalho global de teclado** para abrir/fechar o painel (popover `NSPanel`). Default sugerido: `⌥⌘C`.
10. O atalho é implementado via `NSEvent.addGlobalMonitorForEvents(matching:)` com `NSEventMask.keyDown` — **sem dependências externas** (não usar HotKey.swift de terceiros, não usar Carbon `RegisterEventHotKey` se requerer entitlements adicionais).
11. O atalho é configurável pelo usuário em Settings → seção "Menu Bar" / "Display": campo de captura de tecla (clicar no campo → pressionar nova combinação → salvar). Exibe o atalho atual como texto (ex: "⌥⌘C").
12. O atalho funciona mesmo quando o app não está em foco (é global). Quando o painel já estiver aberto, o atalho o fecha.
13. O atalho é persistido em `SettingsStore.globalHotkey: HotkeyBinding?` (struct com `modifiers: NSEvent.ModifierFlags`, `keyCode: UInt16`; `Codable` via raw values inteiros).

### AC5 — Localização

14. Todas as novas strings de Settings (labels do picker, label "Hotkey" / "Atalho", placeholder "Clique para capturar") localizadas em `en.lproj` e `pt-BR.lproj`.

### AC6 — Regressão e build

15. `swift build -c release` zero warnings (clean `.build`).
16. `swift test --no-parallel` sem regressões (223+ testes baseline); pelo menos **4 novos testes unitários**: `menuBarContentRoundtrip` (Codable), `sparklineEmptyFallback` (array vazio → linha reta), `sparklineMinPoints` (2 pontos → sem crash), `hotkeyBindingCodable`.

---

## Tasks

- [x] **T1 — `MenuBarContent` enum e `HotkeyBinding` struct** (AC1, AC4) — `Sources/ClaudeBar/App/SettingsStore.swift` + `KeyCodes.swift`
  - [x] `enum MenuBarContent: String, Codable, CaseIterable { case none, percentRemaining, timeUntilReset, costToday, sparkline }`
  - [x] `struct HotkeyBinding: Codable { var modifiers: Int; var keyCode: Int }` (raw Int para Codable simples) + `displayString` e `defaultBinding` (⌥⌘C)
  - [x] Adicionar `menuBarContent: MenuBarContent` (default `.none`) e `globalHotkey: HotkeyBinding?` (default `⌥⌘C`) a `SettingsStore`, com persistência (JSON do hotkey + flag `globalHotkeyCleared` para distinguir limpo×fresh) e callbacks

- [x] **T2 — Sparkline renderer** (AC2, AC3) — `Sources/ClaudeBar/StatusItem/SparklineRenderer.swift` (novo)
  - [x] `static func render(samples: [Double], size: NSSize) -> NSImage` — off-main, `NSBitmapImageRep`, `isTemplate = true`
  - [x] Array vazio ou 1 ponto: linha reta horizontal neutra em y=50%
  - [x] N pontos: escalar Y por `max(sample)`, polyline `NSBezierPath`; tamanho ≤ 28×14 pt (≤ 32×18)
  - [x] Fonte de dados: `ExhaustionPredictor.recentUtilizations(windowId:limit:)` (novo, Core) → `DisplaySnapshot.sparklineSamples` preenchido off-main em `AppState.enrich`

- [x] **T3 — Atualizar `StatusItemController`** (AC1, AC3) — `Sources/ClaudeBar/StatusItem/StatusItemController.swift`
  - [x] `menuBarContent` orthogonal a `displayMode`: ícone (meter/brand) + conteúdo (none/%/time/cost/sparkline)
  - [x] Switch por `menuBarContent`: `.none` → só ícone; `.percentRemaining` → `MenuBarContentText`/`MenuBarDisplayText`; `.timeUntilReset` → `MenuBarContentText`; `.costToday` → `DisplaySnapshot.cost.today`; `.sparkline` → composite ícone + `SparklineRenderer.render`
  - [x] Tudo off-main via `Task.detached`; `button.image`/`button.title` no `@MainActor`; composite via `NSBitmapImageRep` (off-main-safe)

- [x] **T4 — Hotkey manager** (AC4) — `Sources/ClaudeBar/App/GlobalHotkeyManager.swift` (novo)
  - [x] `@MainActor class GlobalHotkeyManager`
  - [x] `func register(binding:action:)` — global monitor (`addGlobalMonitorForEvents`) + local monitor (para janelas do próprio app) + checagem `modifierFlags`/`keyCode`
  - [x] `func unregister()` — remove ambos os monitores quando binding muda
  - [x] `AXIsProcessTrusted()` gate antes do monitor global; in-app sempre funciona; popover sempre acessível por clique (additive)
  - [x] Wired em `ClaudeBarApp` (registra após settings; re-registra via `onGlobalHotkeyChange`)

- [x] **T5 — Settings UI — seção Display/Menu Bar** (AC1, AC4, AC5) — `Sources/ClaudeBar/Settings/`
  - [x] Seção "Menu Bar" do `PreferencesDisplayPane`: picker para `menuBarContent`, campo de captura para hotkey, hint de Acessibilidade quando não-trusted
  - [x] `HotkeyCaptureField` (NSViewRepresentable): clicar → capturar combo → salvar; Esc cancela, Delete limpa, exige modificador real

- [x] **T6 — Localização** (AC5) — `en.lproj` + `pt-BR.lproj` (13 chaves novas em cada)

- [x] **T7 — Testes** (AC6) — `Tests/ClaudeBarTests/MenuBarContentTests.swift` + `ExhaustionPredictorTests.swift`
  - [x] 4 obrigatórios: `menuBarContentRoundtrip`, `sparklineEmptyFallback`, `sparklineMinPoints`, `hotkeyBindingCodable` + 11 adicionais (15 novos no total)

---

## Dev Notes

### Arquivos de referência (baseline EXB-1.2)

| Arquivo | Papel |
|---------|-------|
| `Sources/ClaudeBar/StatusItem/StatusItemController.swift` | `@MainActor`; cria `NSStatusItem`; `update(snapshot:)` — ponto de extensão principal |
| `Sources/ClaudeBar/StatusItem/IconRenderer.swift` | Padrão de render off-main com `NSBitmapImageRep`; `isTemplate = true` |
| `Sources/ClaudeBar/StatusItem/MenuBarDisplayText.swift` | `displayText(session:pace:) -> String?` — já implementado para `.percentRemaining` |
| `Sources/ClaudeBar/Settings/SettingsStore.swift` | Preferências via `@AppStorage` ou `UserDefaults`; ponto de adição de novas prefs |
| `Sources/ClaudeBar/Settings/` panes | Estrutura de panes existente — adicionar "Display" pane ou seção |

### Global monitor — sem entitlements extras

`NSEvent.addGlobalMonitorForEvents(matching:)` requer que o app tenha **Accessibility permission** (ou rode como trusted process). O macOS 14+ pode exigir que o usuário aprove explicitamente. A implementação deve:
1. Verificar `AXIsProcessTrusted()` antes de registrar o monitor
2. Se não for trusted: exibir aviso no Settings ("Para usar hotkey global, conceda acesso em Preferências do Sistema → Privacidade → Acessibilidade")
3. O painel ainda abre normalmente via clique no ícone — hotkey é additive

```swift
if AXIsProcessTrusted() {
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        // checar modifiers + keyCode
    }
}
```

### Sparkline — render compacto

```swift
// NSBitmapImageRep 64×18 @2x = 128×36 px real
// samples: [0.0...1.0], cada amostra = coluna vertical
// altura da coluna = sample * 18pt
let rep = NSBitmapImageRep(...)
let context = NSGraphicsContext(bitmapImageRep: rep)
// para cada i, x = i * (64/N), yTop = 18 - sample[i]*18
// linha de min-height 2px para valores próximos de zero
```

### `timeUntilReset` helper

```swift
func formatTimeUntilReset(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let mins = minutes % 60
    return hours > 0 ? "\(hours)h\(mins < 10 ? "0" : "")\(mins)" : "\(minutes)min"
}
```

### Anti-freeze invariants

- Nenhum cálculo de sparkline ou texto em `update(snapshot:)` diretamente no `@MainActor`
- `Task.detached(priority: .userInteractive)` para builds de imagem (latência visível)
- `GlobalHotkeyManager` delega ação ao `@MainActor` via `DispatchQueue.main.async` ou `Task { @MainActor in ... }`

### Testing

- Baseline: 223+ testes; zero regressões
- `swift test --no-parallel`
- Arquivo: contribuir a `SettingsStoreTests.swift` existente ou criar `MenuBarContentTests.swift`

---

## Definition of Done

- [x] 5 opções de conteúdo na menu bar (none, %, timeUntilReset, cost, sparkline) — preferência em Settings
- [x] Sparkline renderizado off-main, `isTemplate = true`, fallback linha reta
- [x] Hotkey global `⌥⌘C` (configurável) abre/fecha painel sem foco
- [x] Hotkey persistido em `SettingsStore`; campo de captura no Settings
- [x] Aviso de Acessibilidade se `AXIsProcessTrusted() == false`
- [x] 4 novos testes verdes (15 novos no total); zero regressões (262 testes verdes)
- [x] `swift build -c release` zero warnings

---

## Dev Agent Record

### Agent Model Used
Dex (@dev) — Opus 4.8

### Implementation Notes / Decisions

- **Sparkline data source [AUTO-DECISION]:** the sparkline reads recent **session** utilization from the existing `ExhaustionPredictor` actor (added `recentUtilizations(windowId:limit:)`), surfaced through a new `DisplaySnapshot.sparklineSamples` populated off-main in `AppState.enrich`. Reason: the predictor is the single source of utilization history (EXB-4.3) — no duplicate buffer, samples already cross the actor boundary off the MainActor.
- **Hotkey transport [AUTO-DECISION]:** used `NSEvent.addGlobalMonitorForEvents` per AC10/AC11 (NOT Carbon `RegisterEventHotKey`, despite the spawn briefing mentioning it — AC10 is authoritative and forbids Carbon if it needs entitlements). Added a companion **local** monitor so the shortcut also fires while one of the app's own windows is key (global monitors skip the active app); the global monitor is gated behind `AXIsProcessTrusted()` and never prompts. The popover stays reachable by click regardless (additive).
- **menuBarContent is orthogonal to displayMode:** `displayMode` still picks the icon (meter/brand); `menuBarContent` picks the trailing content. For `.percentRemaining` in brand mode the existing F2 pace suffix is preserved.
- **Cleared-hotkey persistence:** a `globalHotkeyCleared` flag distinguishes "user cleared → nil" from "fresh install → ⌥⌘C default" across restart.
- **Off-main compositing:** icon + sparkline are combined via `NSBitmapImageRep` (not `NSImage.lockFocus`, which is main-thread affine), mirroring `IconRenderer`.

### File List

**New:**
- `Sources/ClaudeBar/App/KeyCodes.swift` — virtual-key-code → display-name lookup (no Carbon)
- `Sources/ClaudeBar/App/GlobalHotkeyManager.swift` — global + local key-down monitors, AX gate
- `Sources/ClaudeBar/StatusItem/SparklineRenderer.swift` — off-main template sparkline + flat fallback
- `Sources/ClaudeBar/StatusItem/MenuBarContentText.swift` — percent / cost / time-until-reset helpers
- `Sources/ClaudeBar/Settings/HotkeyCaptureField.swift` — NSViewRepresentable shortcut recorder
- `Tests/ClaudeBarTests/MenuBarContentTests.swift` — 14 tests (model, renderer, helpers, persistence)

**Modified:**
- `Sources/ClaudeBar/App/SettingsStore.swift` — `MenuBarContent` enum, `HotkeyBinding` struct, `menuBarContent`/`globalHotkey` props + persistence + callbacks
- `Sources/ClaudeBar/App/DisplaySnapshot.swift` — `sparklineSamples` field threaded through inits/copies
- `Sources/ClaudeBar/App/AppState.swift` — `enrich` reads session sparkline samples off-main
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — wires `GlobalHotkeyManager` + content-change callback
- `Sources/ClaudeBar/StatusItem/StatusItemController.swift` — content switch + off-main composite
- `Sources/ClaudeBar/Settings/PreferencesDisplayPane.swift` — content picker + hotkey field + AX hint
- `Sources/ClaudeBarCore/Prediction/ExhaustionPredictor.swift` — `recentUtilizations(windowId:limit:)`
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — 13 new keys
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — 13 new keys
- `Tests/ClaudeBarCoreTests/ExhaustionPredictorTests.swift` — `recentUtilizationsReturnsTailOldestFirst`

### Validation

- `swift build --arch arm64` — Build complete, zero warnings (validated at each task)
- `swift build -c release --arch arm64` — Build complete, zero warnings
- `swift test --arch arm64 --no-parallel` — **262 tests, 35 suites, all passing** (baseline 223+ → +15 new, zero regressions)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
| 2026-06-18 | 1.1 | Implemented all ACs — menu bar content + global hotkey | @dev Dex |
