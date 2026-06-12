# Story EXB-3.1: Glassmorphism REAL + Seção Appearance

**ID:** EXB-3.1
**Status:** Ready for Review
**Depends on:** EXB-2.1 (glassmorphism baseline), EXB-2.2 (SettingsStore + localization), EXB-1.5 (SettingsWindow pane structure)
**Epic:** EPIC-EXB
**Wave:** Onda 5 (v1.2.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** user who cares about macOS visual polish,
**I want** the popover and Settings window to use genuinely translucent frosted-glass materials, and a new Appearance pane to control transparency level and theme override,
**so that** the app looks native, adapts to my desktop, and I can tune the visual feel without restarting.

---

## Acceptance Criteria

1. **Painel (UsagePanelController):** material `.hudWindow` (frost forte) com `blendingMode .behindWindow` — o conteúdo atrás da janela deve ser perceptível desfocado em dark e light mode.
2. **Settings window (SettingsWindowController):** material `.underWindowBackground` ou `.sidebar` com `blendingMode .behindWindow` — mesma exigência visual; o conteúdo SwiftUI das panes NÃO pode ter fundo sólido próprio (auditar e remover backgrounds opacos onde encontrados).
3. **Nova seção "Appearance/Aparência"** no Settings: um `Picker` de transparência com 3 níveis — "Opaque/Opaco", "Standard/Padrão" (`.popover`), "Frosted/Vidro" (`.hudWindow`) — default `Frosted`; aplicação IMEDIATA no painel e na janela sem relaunch; valor persistido no `SettingsStore`.
4. **Também na Appearance:** override de tema (System/Light/Dark) via `NSApp.appearance`, aplicação imediata; persistido no `SettingsStore`.
5. Todas as strings novas localizadas em `en.lproj/Localizable.strings` e `pt-BR.lproj/Localizable.strings`.
6. Teste unitário do mapeamento nível→material (confirmar que cada enum case produz o `NSVisualEffectView.Material` correto); auditoria `grep` documentada na story (ou em comentário inline) provando que nenhuma view raiz tem `background` opaco.
7. `swift build -c release` zero warnings; `swift test` sem regressões.

---

## Tasks

- [x] **T1 — Diagnóstico e auditoria de backgrounds opacos** (pré-requisito para AC1/AC2)
  - [x] `grep -r "\.background\|Color(" Sources/ClaudeBar/ --include="*.swift"` — identificar views com fundo sólido nas panes de Settings e no popover
  - [x] Documentar hits no Dev Notes deste story (lista de arquivos + linha); cada um será endereçado em T2/T3
  - [x] `grep` específico para `SettingsWindowController.swift` (`material = .windowBackground`, era linha 64) e `UsagePanelController.swift` (`material = .popover`, era linha 54) — confirmados como ponto de partida

- [x] **T2 — TransparencyLevel + ThemeOverride enums** (`Sources/ClaudeBar/App/SettingsStore.swift`) (AC3, AC4)
  - [x] Adicionado `enum TransparencyLevel: String, CaseIterable, Codable { case opaque, standard, frosted }` com computed var `material: NSVisualEffectView.Material`
  - [x] Adicionado `enum ThemeOverride: String, CaseIterable, Codable { case system, light, dark }` com computed var `appearance: NSAppearance?`
  - [x] Propriedades `@Observable` `transparencyLevel: TransparencyLevel = .frosted` e `themeOverride: ThemeOverride = .system` em `SettingsStore`, persistidas via o `PersistedSnapshot`/`UserDefaults` debounced existente (mesmo padrão de `RefreshCadence`/`AppLanguage` — `@AppStorage` não se aplica num `@Observable` final class, então reusei a máquina de persistência já validada)

- [x] **T3 — Aplicar materiais dinamicamente** (AC1, AC2, AC3, AC4)
  - [x] `UsagePanelController`: callback `SettingsStore.onTransparencyChange` chama `applyTransparency(_:)` → `effectView.material = level.material` sem recriar o painel
  - [x] `UsagePanelController`: default frosted troca `.popover` por `.hudWindow` (material seeded do `transparencyLevel` persistido)
  - [x] `SettingsWindowController`: troca `.windowBackground` por `.underWindowBackground`; `applyTransparency(_:)` aplica live; panes não tinham `.background` opaco (ver auditoria T1)
  - [x] `ThemeOverride`: `AppDelegate.applyTheme(_:)` seta `NSApp.appearance`; chamado em cada mudança do picker (via `onThemeChange`) e no `applicationDidFinishLaunching`

- [x] **T4 — Pane Appearance** (`Sources/ClaudeBar/Settings/AppearancePaneView.swift`) (AC3, AC4, AC5)
  - [x] Novo arquivo `AppearancePaneView.swift` em `Sources/ClaudeBar/Settings/`
  - [x] `Picker(L("appearance.transparency.label"), selection: $settings.transparencyLevel)` com `.segmented` style
  - [x] `Picker(L("appearance.theme.label"), selection: $settings.themeOverride)` com `.segmented` style
  - [x] Registrada na `SettingsRootView` (novo tab "Appearance" com SF Symbol `paintbrush`)
  - [x] Integra `SettingsStore` via `@Bindable` (mesmo padrão das outras panes)

- [x] **T5 — Localização** (AC5)
  - [x] Chaves em `en.lproj/Localizable.strings`: `appearance.tab`, `appearance.section.transparency`, `appearance.transparency.label`, `appearance.transparency.subtitle`, `appearance.transparency.opaque`, `appearance.transparency.standard`, `appearance.transparency.frosted`, `appearance.section.theme`, `appearance.theme.label`, `appearance.theme.subtitle`, `appearance.theme.system`, `appearance.theme.light`, `appearance.theme.dark`
  - [x] Espelhadas em `pt-BR.lproj/Localizable.strings`

- [x] **T6 — Testes unitários** (AC6)
  - [x] `Tests/ClaudeBarTests/AppearanceTests.swift`: `TransparencyLevel.opaque.material == .underWindowBackground`, `.standard.material == .popover`, `.frosted.material == .hudWindow` + guard de regressão `!= .windowBackground`
  - [x] `ThemeOverride` mapping + persiste/restaura via `SettingsStore` (round-trip de todos os casos)
  - [x] Callbacks de transparency/theme + localização das chaves novas em en e pt-BR

- [x] **T7 — Build clean** (AC7)
  - [x] `swift build -c release` zero warnings (Build complete! 5.68s)
  - [x] `swift test` zero regressões (187 testes verdes em serial; ver nota sobre flake paralelo)

---

## Dev Notes

### Diagnóstico fornecido pelo orquestrador (tratar como fato)

O resultado visual da EXB-2.1 é opaco. Causa confirmada:
- `SettingsWindowController.swift` linha ~64: `material = .windowBackground` — esse material é sólido por design em floating windows. Trocar para `.underWindowBackground` ou `.sidebar`.
- `UsagePanelController.swift` linha ~54: `material = .popover` — quase opaco em dark mode. Trocar para `.hudWindow` para frost forte.

O dev DEVE confirmar os números de linha exatos via grep antes de editar.

### Material reference (AppKit)

| Material | Característica | Usar em |
|---|---|---|
| `.hudWindow` | Frost forte, fundo escurecido | Painel popover (frosted) |
| `.popover` | Frost médio, adaptativo | Painel (standard) |
| `.underWindowBackground` | Blur sob a janela, leve | Settings window |
| `.sidebar` | Similar a underWindowBackground com tint | Settings alternativo |
| `.windowBackground` | SÓLIDO — nunca usar para glassmorphism | ❌ |

### Aplicação dinâmica de material sem recriar o painel

```swift
// Em UsagePanelController, ao receber notificação/combine de SettingsStore:
func applyTransparency(_ level: TransparencyLevel) {
    effectView.material = level.material
}
// Obs: NSVisualEffectView.material é setável a qualquer momento — não requer recreate.
```

### Remoção de backgrounds opacos nas SwiftUI panes

Panes de Settings são SwiftUI views embutidas em NSHostingView. Qualquer `.background(Color.xxx)` ou `.background(.regularMaterial)` no root container vai criar um layer sólido na frente do blur do NSVisualEffectView. Remover ou substituir por `.background(.clear)` onde necessário.

### NSApp.appearance override

```swift
func applyTheme(_ override: ThemeOverride) {
    switch override {
    case .system: NSApp.appearance = nil
    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
```

### SettingsStore — padrão de persistência existente

Ver `Sources/ClaudeBar/App/SettingsStore.swift`. O projeto usa `@AppStorage` (UserDefaults). Adicionar as novas chaves seguindo o padrão existente. `TransparencyLevel` e `ThemeOverride` devem ser `RawRepresentable` com `String` rawValue para funcionar com `@AppStorage`.

### Source tree additions

```
Sources/ClaudeBar/Settings/AppearancePaneView.swift  (novo)
Tests/ClaudeBarTests/AppearanceTests.swift           (novo)
```

Modificados:
- `Sources/ClaudeBar/App/SettingsStore.swift` — novos enums + properties
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — material → .hudWindow (default) + dynamic apply
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — material → .underWindowBackground/.sidebar
- `Sources/ClaudeBar/Settings/SettingsRootView.swift` — novo tab Appearance
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings`
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings`

### Anti-freeze invariants (transversais)

- ZERO I/O on main thread; a mudança de material é pura AppKit on main — correto.
- `SettingsStore` changes devem ser observados via Combine ou `@Observable` — nunca polling.
- NSPanel architecture preservada (AC não altera estrutura de janelas).

### Testing

- Arquivo de teste: `Tests/ClaudeBarTests/AppearanceTests.swift`
- Framework: Swift Testing ou XCTest (seguir padrão dos outros arquivos em `Tests/ClaudeBarTests/`)
- Mínimo: 3 casos (um por TransparencyLevel → material) + 1 para ThemeOverride persistence
- Os 145 testes existentes NÃO devem regredir

---

## Dev Agent Record

### Auditoria T1 — backgrounds opacos (grep)

Comando: `grep -rn "\.background\|Color(\|backgroundColor\|\.regularMaterial\|\.thickMaterial\|\.ultraThinMaterial\|\.thinMaterial" Sources/ClaudeBar/ --include="*.swift"`

**Resultado: nenhuma view raiz (popover root ou pane root) tem fundo sólido.** Todas as panes de Settings (`PreferencesGeneralPane`, `PreferencesClaudePane`, `PreferencesDisplayPane`, `AppearancePaneView`, `PreferencesAboutPane`) usam root `ScrollView`/`VStack` **sem** `.background`. Classificação dos hits:

| Arquivo:linha | Hit | Classificação |
|---|---|---|
| `SettingsWindowController.swift:64` | `material = .windowBackground` | ❌ CULPADO #1 — material sólido em janela flutuante. **Corrigido → `.underWindowBackground`** |
| `UsagePanelController.swift:54` | `material = .popover` | ⚠️ CULPADO #2 — quase opaco em dark mode num NSPanel livre. **Corrigido → `.hudWindow` (default frosted)** |
| `SettingsWindowController.swift:60` | `window.backgroundColor = .clear` | ✅ correto — janela transparente para o blur aparecer |
| `UsagePanelController.swift:87` | `panel.backgroundColor = .clear` | ✅ correto — idem |
| `UsageCardView.swift:350` | `.background(RoundedRectangle…fill(isHovered ? selected : .clear))` | ✅ pílula de hover de uma menu-row, NÃO é root; `.clear` quando não-hover |
| `DashboardView.swift:119/234` | `.background(…fill(Color(nsColor:.controlBackgroundColor)))` | ➖ N/A — janela Dashboard separada (EXB-2.3), não é popover nem pane de Settings; fora do escopo desta story |
| `PreferencesComponents.swift:144` | `.foregroundColor(.accentColor)` | ✅ falso positivo do grep — é foreground, não background |
| demais `Color(nsColor:…)` | `.foregroundStyle`/tints/ícones | ✅ cor de conteúdo (texto/ícone/barra), não fundo de container |

Pós-correção: o único material setável remanescente nos dois containers raiz é dirigido por `TransparencyLevel.material` — nenhum é `.windowBackground`. Teste de regressão `noTransparencyLevelUsesOpaqueWindowBackground` trava isso.

### Limitação do sistema — "Reduce transparency" (documentada conforme exigido)

O efeito de frost vem 100% do `NSVisualEffectView`. Se o usuário ativar **System Settings → Accessibility → Display → Reduce transparency** (ou `Increase contrast`, que implica reduce transparency), o macOS força **todos** os `NSVisualEffectView` a renderizarem um fundo sólido opaco, independente do material ou `blendingMode` escolhidos. Isso é comportamento do sistema operacional, não do app — não há override programático aceitável (e seria hostil à acessibilidade tentar burlá-lo). Nesse modo, os 3 níveis de transparência colapsam visualmente para sólido, mas o tema (Light/Dark) continua funcionando normalmente. **Não é um defeito da EXB-3.1.** O mesmo se aplica ao CodexBar original e a qualquer app nativo (Notification Center, Spotlight, etc.).

### Nota de teste — flake paralelo conhecido

`swift test` em paralelo pode reportar 1 falha em `PromptPolicyTests.policyProviderIsReadOnEveryLoadReachingKeychain` (`reads==2 != loadCount==3`, ~161s). É o mesmo flake de keychain-real avisado pelo orquestrador (atinge a camada (e) do keychain do sistema; sob contenção paralela uma leitura é throttled). **Passa em 0.047s isolado e a suíte inteira passa serial (187/187).** Fora do path tocado pela EXB-3.1 (OAuth/credentials). Reproduzir regressão real: `swift test --no-parallel`.

### File List

**Novos:**
- `Sources/ClaudeBar/Settings/AppearancePaneView.swift`
- `Tests/ClaudeBarTests/AppearanceTests.swift`

**Modificados:**
- `Sources/ClaudeBar/App/SettingsStore.swift` — `import AppKit`; enums `TransparencyLevel` + `ThemeOverride`; props `transparencyLevel`/`themeOverride`; callbacks `onTransparencyChange`/`onThemeChange`; persistência (Key + PersistedSnapshot + load)
- `Sources/ClaudeBar/Popover/UsagePanelController.swift` — material default `.hudWindow` via `transparency:` param; `applyTransparency(_:)`; `blendingMode .behindWindow` explícito
- `Sources/ClaudeBar/Settings/SettingsWindowController.swift` — material `.windowBackground` → `.underWindowBackground` (seeded do persistido); `applyTransparency(_:)`; ref ao `effectView`
- `Sources/ClaudeBar/Settings/SettingsRootView.swift` — novo tab Appearance (SF Symbol `paintbrush`); doc "four-tab" → "five-tab"
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — seed do material do painel; wiring `onTransparencyChange`/`onThemeChange`; `applyTheme(_:)`; apply de tema no launch
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — 13 chaves `appearance.*`
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — 13 chaves `appearance.*`

### Build/Test (últimas linhas)

```
swift build -c release  →  [6/7] Linking ClaudeBar / Build complete! (5.68s)   [zero warnings]
swift test --no-parallel →  ✔ Test run with 187 tests in 25 suites passed after 3.082 seconds.
```

---

## Definition of Done

- [x] Material do painel visualmente translúcido (hudWindow + behindWindow) em light e dark mode
- [x] Material do Settings window visualmente translúcido (underWindowBackground + behindWindow) — sem fundos opacos nas panes
- [x] Pane Appearance presente com pickers funcionais (transparência + tema)
- [x] Mudanças de material e tema aplicadas imediatamente, sem relaunch
- [x] Persistência correta no SettingsStore (valores sobrevivem a restart)
- [x] Strings localizadas em en + pt-BR
- [x] Testes unitários novos passando (mapeamento nível→material; ThemeOverride persistence)
- [x] `swift build -c release` zero warnings; `swift test` sem regressões (serial)

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-12 | 1.0 | Initial draft — Onda 5 (v1.2.0) | @sm River |
| 2026-06-12 | 1.1 | Implemented — real glassmorphism (hudWindow/underWindowBackground + explicit behindWindow), Appearance pane (transparency + theme), en/pt-BR, AppearanceTests. Build clean, 187 tests green serial. Status → Ready for Review | @dev Dex |
