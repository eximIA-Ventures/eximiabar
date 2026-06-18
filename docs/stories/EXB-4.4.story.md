# Story EXB-4.4: Menu Bar Inteligente + Hotkey Global

**ID:** EXB-4.4
**Status:** Draft
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

- [ ] **T1 — `MenuBarContent` enum e `HotkeyBinding` struct** (AC1, AC4) — `Sources/ClaudeBarCore/Model/` ou `Sources/ClaudeBar/App/SettingsStore.swift`
  - [ ] `enum MenuBarContent: String, Codable, CaseIterable { case none, percentRemaining, timeUntilReset, costToday, sparkline }`
  - [ ] `struct HotkeyBinding: Codable { var modifiers: Int; var keyCode: Int }` (raw Int para Codable simples)
  - [ ] Adicionar `menuBarContent: MenuBarContent` e `globalHotkey: HotkeyBinding?` a `SettingsStore` com defaults (`.none`, `HotkeyBinding(modifiers: optionCmd, keyCode: cKeyCode)`)

- [ ] **T2 — Sparkline renderer** (AC2, AC3) — `Sources/ClaudeBar/StatusItem/SparklineRenderer.swift` (novo)
  - [ ] `static func render(samples: [Double], size: NSSize) -> NSImage` — off-main, `NSBitmapImageRep`, `isTemplate = true`
  - [ ] Array vazio ou 1 ponto: linha reta horizontal em y=50%
  - [ ] N pontos: escalar Y por `max(sample)`, segmentos `NSBezierPath`

- [ ] **T3 — Atualizar `StatusItemController`** (AC1, AC3) — `Sources/ClaudeBar/StatusItem/StatusItemController.swift`
  - [ ] Observar `SettingsStore.menuBarContent` (ou receber via `DisplaySnapshot`) — rebuildContent ao mudar
  - [ ] Switch por `menuBarContent`: `.none` → só ícone; `.percentRemaining` → existente `MenuBarDisplayText`; `.timeUntilReset` → novo helper; `.costToday` → de `DisplaySnapshot.costToday`; `.sparkline` → `SparklineRenderer.render`
  - [ ] Tudo off-main via `Task.detached`; set `button.image` / `button.title` no `@MainActor`

- [ ] **T4 — Hotkey manager** (AC4) — `Sources/ClaudeBar/App/GlobalHotkeyManager.swift` (novo)
  - [ ] `@MainActor class GlobalHotkeyManager`
  - [ ] `func register(binding: HotkeyBinding, action: @escaping () -> Void)`
  - [ ] Usa `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` + checar `modifierFlags` e `keyCode`
  - [ ] `func unregister()` — remover monitor quando binding mudar
  - [ ] Wired em `AppState` ou `ClaudeBarApp` (chamado após settings carregam)

- [ ] **T5 — Settings UI — seção Display/Menu Bar** (AC1, AC4, AC5) — `Sources/ClaudeBar/Settings/`
  - [ ] Novo pane ou secção no pane existente: picker para `menuBarContent`, campo de captura para hotkey
  - [ ] Campo de captura: `NSTextField` com `keyDown` override para capturar a combinação e salvar em `SettingsStore`

- [ ] **T6 — Localização** (AC5) — `en.lproj` + `pt-BR.lproj`

- [ ] **T7 — Testes** (AC6) — `Tests/ClaudeBarTests/`
  - [ ] `MenuBarContentTests.swift` ou adicionar a `SettingsStoreTests.swift`
  - [ ] 4+ testes (AC6)

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

- [ ] 5 opções de conteúdo na menu bar (none, %, timeUntilReset, cost, sparkline) — preferência em Settings
- [ ] Sparkline renderizado off-main, `isTemplate = true`, fallback linha reta
- [ ] Hotkey global `⌥⌘C` (configurável) abre/fecha painel sem foco
- [ ] Hotkey persistido em `SettingsStore`; campo de captura no Settings
- [ ] Aviso de Acessibilidade se `AXIsProcessTrusted() == false`
- [ ] 4 novos testes verdes; zero regressões
- [ ] `swift build -c release` zero warnings

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
