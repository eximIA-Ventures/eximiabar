# Story EXB-1.2: Status Item + Menu Bar Icon

**ID:** EXB-1.2
**Status:** Done
**Depends on:** EXB-1.1 (provides `UsageSnapshot`, `RateWindow`)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** macOS user with exímIABar running,
**I want** a live meter icon in the menu bar that visually encodes my Claude session and weekly usage at a glance,
**so that** I can see my rate limit status without opening any window.

---

## Acceptance Criteria

1. The app is a `LSUIElement` agent (no Dock icon, no app menu) — set `LSUIElement = YES` in `Info.plist` and `NSPrincipalClass = NSApplication`.
2. `NSStatusItem` is created with `.variableLength`. `button.imageScaling = .scaleNone`.
3. The icon is rendered at 18×18 pt logical size, drawn into an `NSBitmapImageRep` at 2× scale (36×36 px), resulting in an `NSImage` with `isTemplate = true`. The system tints it automatically with `labelColor` in both light and dark mode.
4. Pixel grid: all coordinates snapped to 0.5 pt. Two horizontal bars:
   - Session bar: `RectPx(x:3, y:19, w:30, h:12)` (in the 36×36 bitmap)
   - Weekly bar: `RectPx(x:3, y:5, w:30, h:8)`
   - Both have **corner radius 0** (Claude style — blocky, not rounded).
5. Fill proportional to `remaining/100` — a bar at 87.5% remaining is 87.5% filled from the left.
6. Visual layer ordering per pixel (α blending with `.clear` for cutouts — no opacity trickery): track fill `labelColor` α0.28, track stroke 1 pt `labelColor` α0.44, progress fill `labelColor` α1.0.
7. Stale state (last successful fetch > 5 min ago): fill α0.55, stroke α0.28, track α0.18.
8. Error state: icon dims to the stale alphas.
9. Crab cutouts drawn with blend mode `.clear` over the filled icon (these are transparent "holes"):
   - Lateral arms: 3 px wide each side of both bars
   - 4 legs: 2×3 px each, below the weekly bar
   - Eyes: 2×5 px vertical slots on the session bar, "close" from top on blink (P2 — implement the static shape; skip blink animation)
   Exact coordinates: reference `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:257-336` (Claude style block, lines 257–336).
10. Weekly bar absent (no `seven_day` data): render bar dimmed at α0.45. Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:671-710`.
11. Incident overlay (P2 features, but shape must be present for toggle): minor incident = 4 pt filled circle in the lower-right corner; major = "!" glyph (2×6 rect + 2×2 dot). Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:935-968`. For P0/P1 builds, overlay is always hidden.
12. LRU icon cache: 64 slots, keyed by a quantized state tuple (utilization quantized to 0.1% steps, stale bool, error bool). Cache hit returns existing `NSImage` without re-rendering. Reference: `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:31-70`.
13. **Brand icon + % mode (F2, P1):** when `displayMode == .brandIcon`, the status item shows the Claude SVG template icon (16×16 from `Resources/ProviderIcon-claude.svg`) plus a title string `" 87%"` (session remaining) or `"87% · +5%"` if pace >0. Reference: `_reference_codexbar/Sources/CodexBar/MenuBarDisplayText.swift:4-37` and `ProviderBrandIcon.swift`.
14. Icon updates are dispatched on the main thread. The `IconRenderer` class itself is stateless (pure function per render call) — it MUST NOT hold `@MainActor` state.
15. **Anti-freeze:** `IconRenderer` does all drawing in an `NSBitmapImageRep` context off-main, returns the completed `NSImage`. The `StatusItemController` receives the image and sets `button.image` on MainActor only.
16. `swift build` for the `ClaudeBar` target succeeds, zero new warnings.

---

## Tasks

- [x] **T1 — App scaffold** (`Sources/ClaudeBar/App/`)
  - [x] `ClaudeBarApp.swift`: `@main struct ClaudeBarApp: App` body creates `AppState` and `StatusItemController`. In `applicationDidFinishLaunching`: create `NSStatusItem`, wire `AppState` observer.
  - [x] `Info.plist`: `LSUIElement = YES`, `CFBundleIdentifier = com.eximia.eximiabar`, `NSPrincipalClass = NSApplication`
  - [x] `AppState.swift` stub (minimal — `@MainActor @Observable class AppState`; `var snapshot: DisplaySnapshot? = nil`). Full implementation in S4.

- [x] **T2 — IconRenderer** (`Sources/ClaudeBar/StatusItem/IconRenderer.swift`)
  - [x] Port the Claude-style render block from `_reference_codexbar/Sources/CodexBar/IconRenderer.swift:257-336` into a new file. Adapt: rename `Codex` → `ClaudeBar`; remove multi-provider dispatch; keep only the Claude variant.
  - [x] Implement `render(session: RateWindow?, weekly: RateWindow?, isStale: Bool, hasError: Bool) -> NSImage` as a static function
  - [x] Implement LRU cache (64 slots, 0.1% quantization) around the static renderer (AC12)
  - [x] Implement weekly-absent dim logic (AC10)
  - [x] Implement static crab cutout shapes (AC9) — blink animation deferred to P2

- [x] **T3 — Brand icon mode** (`Sources/ClaudeBar/StatusItem/`)
  - [x] `ProviderBrandIcon.swift`: load `Resources/ProviderIcon-claude.svg` as `NSImage` with `isTemplate = true`
  - [x] `MenuBarDisplayText.swift`: `func displayText(session: RateWindow?, pace: Double?) -> String?` — returns `" 87%"` or `"87% · +5%"` per AC13. Reference: `_reference_codexbar/Sources/CodexBar/MenuBarDisplayText.swift:4-37`
  - [x] Add `Resources/ProviderIcon-claude.svg` — copy from `_reference_codexbar/Sources/CodexBar/Resources/ProviderIcon-claude.svg`

- [x] **T4 — StatusItemController** (`Sources/ClaudeBar/StatusItem/StatusItemController.swift`)
  - [x] `@MainActor class StatusItemController`
  - [x] Creates `NSStatusItem` with `.variableLength` (AC2)
  - [x] `func update(snapshot: DisplaySnapshot?)`: calls `IconRenderer.render(...)` off-main via `Task.detached`, then applies `button.image` on `MainActor`
  - [x] Respects `displayMode` setting from `SettingsStore` (stub: default `.meterIcon`; full wiring in S5)
  - [x] Click on status item triggers popover show (hook only — popover implementation in S3)

- [x] **T5 — Incident overlay stubs**
  - [x] Add `renderIncidentOverlay(minor: Bool, major: Bool) -> NSImage?` function; always returns `nil` for P0/P1 (AC11 shape code present but toggled off)

---

## Dev Notes

### Icon coordinate system
The icon is drawn in a 36×36 px bitmap (2× of the 18×18 pt logical size). All measurements in the spec and reference code are in **pixels in this 36×36 bitmap**:
- Session bar: origin (3, 19), size 30×12 px
- Weekly bar: origin (3, 5), size 30×8 px
Note the coordinate origin is bottom-left in Core Graphics (macOS), so y=5 from the bottom.

### Reference file to port
`_reference_codexbar/Sources/CodexBar/IconRenderer.swift` — this is a large file (~1000 lines). You need:
- Lines 31–70: LRU cache implementation
- Lines 257–336: Claude-specific crab shape (braços, pernas, olhos)
- Lines 671–710: weekly-absent dim logic
- Lines 935–968: incident overlay shapes

For the rest of the file (other providers, stacked icon, etc.) — skip entirely.

### Template image behavior
`image.isTemplate = true` makes AppKit automatically tint the icon with the current `labelColor`. Do NOT set any explicit color in the icon — paint everything with `NSColor.black` (or `.labelColor`) at full alpha; template mode handles dark/light inversion.

### LRU cache key quantization
Quantize `remaining` to 0.1% steps: `let key = (Int(session.remaining * 10), Int(weekly.remaining * 10), isStale, hasError)`. This gives 1001 × 1001 × 2 × 2 theoretical states but realistically ~100 live entries.

### SVG icon
`ProviderIcon-claude.svg` must be in the app bundle `Resources/` directory. Reference the original at `_reference_codexbar/Sources/CodexBar/Resources/ProviderIcon-claude.svg`. In `Package.swift`, declare it under `.resources: [.copy("Resources/")]`.

### DisplayMode enum
```swift
enum DisplayMode {
    case meterIcon          // F1 — two-bar crab icon
    case brandIconPercent   // F2 — Claude SVG + text
}
```
Store in `SettingsStore` (stub in this story, full in S5).

### Anti-freeze pattern for this story
```swift
// CORRECT: render off-main, update on-main
Task.detached(priority: .userInitiated) {
    let image = IconRenderer.render(session: snap.session, weekly: snap.weekly, ...)
    await MainActor.run { self.button.image = image }
}
// WRONG:
// MainActor: let image = IconRenderer.render(...) ← blocks main thread
```

---

## Definition of Done

- [x] `swift build` succeeds with zero new warnings
- [x] App launches as LSUIElement (no Dock icon) with meter icon visible in menu bar — verified via embedded `Info.plist` (`LSUIElement = true`, `CFBundleIdentifier = com.eximia.eximiabar`, `NSPrincipalClass = NSApplication`) + `NSApp.setActivationPolicy(.accessory)`
- [x] Icon correctly fills session and weekly bars proportionally when given mock snapshot data (seeded mock: 87.5% session / 60% weekly remaining)
- [x] Stale state (α reduction) visually distinct from active state — separate cache entry, dimmed palette (track 0.18 / stroke 0.28 / progress 0.55)
- [x] LRU cache avoids re-rendering when called with same quantized state twice consecutively (test `cacheReturnsSameInstanceForIdenticalState` — identical `NSImage` instance)
- [x] Brand icon mode renders Claude SVG + percentage string in status bar (`MenuBarDisplayText` + `ProviderBrandIcon`)
- [x] `IconRenderer.render(...)` is callable from a background thread without data races (test `renderIsConcurrencySafe` — 200 concurrent renders; cache lock-guarded)

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Date:** 2026-06-10

### File List

**New:**
- `Sources/ClaudeBar/App/ClaudeBarApp.swift` — `@main` SwiftUI agent + `AppDelegate` (status item wiring, mock snapshot seed, observation loop)
- `Sources/ClaudeBar/App/AppState.swift` — `@MainActor @Observable` single-snapshot holder (stub; full refresh loop in S4)
- `Sources/ClaudeBar/App/SettingsStore.swift` — `DisplayMode` enum + `@MainActor SettingsStore` stub (full settings in S5)
- `Sources/ClaudeBar/App/DisplaySnapshot.swift` — immutable presentation model + `UsageSnapshot` mapping with staleness derivation
- `Sources/ClaudeBar/StatusItem/IconRenderer.swift` — stateless Claude-only meter renderer + 64-slot LRU cache
- `Sources/ClaudeBar/StatusItem/StatusItemController.swift` — `@MainActor` status item; off-main render via `Task.detached`, generation-guarded apply
- `Sources/ClaudeBar/StatusItem/ProviderBrandIcon.swift` — single Claude SVG template loader (adapted from reference)
- `Sources/ClaudeBar/StatusItem/MenuBarDisplayText.swift` — F2 title string (` 87%` / `87% · +5%`)
- `Sources/ClaudeBar/Resources/ProviderIcon-claude.svg` — copied from reference
- `Sources/ClaudeBar/Info.plist` — LSUIElement agent plist (embedded via linker `-sectcreate __TEXT __info_plist`)
- `Tests/ClaudeBarTests/IconRendererTests.swift` — 8 tests (size/template, cache identity + quantization, stale/error keys, absent weekly, boundary fills, concurrency safety, overlay stub)
- `Tests/ClaudeBarTests/MenuBarDisplayTextTests.swift` — 5 tests (AC13 forms, clamping, nil)
- `Tests/ClaudeBarTests/DisplaySnapshotTests.swift` — 3 tests (staleness threshold, error propagation)

**Modified:**
- `Package.swift` — added `exclude: ["Info.plist"]`, `resources: [.copy("Resources/ProviderIcon-claude.svg")]`, linker `-sectcreate` for plist embedding, and new `ClaudeBarTests` test target

**Removed:**
- `Sources/ClaudeBar/main.swift` — EXB-1.1 headless placeholder, superseded by `ClaudeBarApp.swift`

### Build & Test Results
- `swift build`: **Build complete!** — zero warnings, zero errors (all targets)
- `swift test`: **59 tests in 8 suites passed** (43 pre-existing + 16 new)
- AC1 verified: `segedit -extract` + `plutil -p` confirm embedded plist keys.

### Deviation (1) — AC9 crab placement
AC9 prose reads "Lateral arms: 3 px wide each side of **both bars**" and "4 legs ... **below the weekly bar**". The cited authoritative reference code (`IconRenderer.swift:257-336`, the `addNotches` Claude block) draws arms + legs + eyes **only on the session/top bar** — the reference passes `addNotches` solely to the top bar and renders the bottom (weekly) bar plain. Per the spawn directive — "replicate the meter pixel by pixel … fidelity is requirement", with the reference code as tie-breaker — the implementation follows the reference: a single crab on the session bar (arms on the session bar, legs hanging below the session bar, eyes on the session bar). The prose's "both bars / below the weekly bar" is treated as an idealized description superseded by the cited code. No functional impact; the weekly bar still renders track/stroke/fill and the absent-weekly dim path (AC10).

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (9/10) — Status: Draft → Ready. No content changes required. | @po Pax |
| 2026-06-10 | 1.2 | Implemented all ACs (T1–T5). Status: Ready → InReview. 16 new tests, zero-warning build. | @dev Dex |
| 2026-06-10 | 1.3 | QA gate — round 1. Verdict: PASS. | @qa Quinn |

---

## QA Results — rodada 1

**Gate reviewer:** @qa (Quinn) · **Date:** 2026-06-10 · **Commit under review:** `1d65c95`

Todas as verificações foram feitas no **código real e binário compilado**, não no relatório do dev. Build e testes rodados de uma árvore limpa (`swift package clean`).

### 1. Build & Test (verificados de zero)

| Check | Resultado | Evidência |
|-------|-----------|-----------|
| `swift build` (clean) | ✅ **Build complete!** | 49 etapas de compilação, todos os targets linkados |
| Erros | ✅ **0** | `grep -c "error:"` = 0 |
| Warnings novos (AC16) | ✅ **0** | `grep -c "warning:"` = 0 |
| `swift test` | ✅ **59 tests / 8 suites passed** | 43 pré-existentes + 16 novos, 0 falhas |

### 2. Acceptance Criteria — traceability (16/16)

| AC | Status | Arquivo / evidência |
|----|--------|---------------------|
| AC1 — LSUIElement agent, NSPrincipalClass | ✅ | `Info.plist` + embed via linker `-sectcreate`. **Verificado no binário:** `segedit -extract __TEXT __info_plist` → `LSUIElement => true`, `CFBundleIdentifier => com.eximia.eximiabar`, `NSPrincipalClass => NSApplication`. Belt-and-suspenders `NSApp.setActivationPolicy(.accessory)` em `ClaudeBarApp.swift:38` |
| AC2 — `.variableLength`, `imageScaling = .scaleNone` | ✅ | `StatusItemController.swift:25` (`statusItem(withLength: .variableLength)`) e `:29` (`button.imageScaling = .scaleNone`) |
| AC3 — 18×18 pt / 36×36 px bitmap, `isTemplate` | ✅ | `IconRenderer.swift:338-373` (`NSBitmapImageRep` 36×36, `image.isTemplate = true`). Teste `rendersTemplateImageAtExpectedSize` assere `pixelsWide/High == 36` e `size == 18×18` |
| AC4 — barras corner radius 0, coords | ✅ | `IconRenderer.swift:30-32` (`sessionRectPx (3,19,30,12)`, `weeklyRectPx (3,5,30,8)`), `:215` (`NSBezierPath(rect:)` — sem corner radius) |
| AC5 — fill proporcional `remaining/100` | ✅ | `IconRenderer.swift:234-248` (clamp + clip + left-to-right rect). Testes `rendersBoundaryFills` (0%/100%) |
| AC6 — α layering (track .28 / stroke .44 / progress 1.0) | ✅ | `IconRenderer.swift:157-159` (valores exatos, ativo) |
| AC7 — stale (.18/.28/.55) | ✅ | `IconRenderer.swift:157-159` (ramo `dimmed`: 0.18/0.28/0.55). Teste `staleAndErrorStatesAreDistinctCacheEntries` |
| AC8 — error → alphas stale | ✅ | `IconRenderer.swift:123` (`dimmed = isStale \|\| hasError`) |
| AC9 — crab cutouts (arms 3px, 4 legs 2×3px, eyes 2×5px `.clear`) | ✅ (com desvio documentado) | `IconRenderer.swift:256-294`. Port fiel do bloco `addNotches` da ref (`:257-336`), com `wiggle`/`blink` removidos conforme story. **Desvio AC9 validado** — ver §6 |
| AC10 — weekly ausente → α0.45 | ✅ | `IconRenderer.swift:182-193` (`drawBar(remaining: nil, alpha: 0.45)`). Idêntico à ref `:679/708`. Teste `rendersWithAbsentWeekly` |
| AC11 — incident overlay (shape presente, off P0/P1) | ✅ | `IconRenderer.swift:303-324` (shapes minor/major presentes; `drawMeter` chama com `false/false`; stub `renderIncidentOverlay` retorna `nil`). Teste `incidentOverlayStubIsNil` |
| AC12 — LRU 64 slots, quantização 0.1% | ✅ | `IconRenderer.swift:68-104` (port fiel do `IconCacheStore` da ref, lock-guarded, eviction). Testes `cacheReturnsSameInstanceForIdenticalState`, `cacheQuantizesToTenthOfAPercent` (boundary 42.30 vs 42.34 vs 42.50) |
| AC13 — brand icon + `" 87%"` / `"87% · +5%"` | ✅ | `MenuBarDisplayText.swift:16-27` (literais exatos, middle-dot U+00B7 confirmado) + `ProviderBrandIcon.swift` (SVG template 16×16). 5 testes cobrindo todas as formas + clamp + nil |
| AC14 — update on main, `IconRenderer` stateless sem `@MainActor` | ✅ | `IconRenderer` é `enum` sem estado de instância e sem `@MainActor` (único estado é o cache lock-guarded). `StatusItemController.applyMeter` roda no `@MainActor` |
| AC15 — anti-freeze: render off-main, set image on-main | ✅ | `StatusItemController.swift:57-64` (`Task.detached(priority: .userInitiated)` → render → `await self.applyMeter` no MainActor com generation guard) |
| AC16 — build zero novos warnings | ✅ | confirmado (§1) |

### 3. Definition of Done — 6/6 ✅
Todos os itens de DoD verificados contra código/binário/testes (LSUIElement embarcado, fill proporcional, stale distinto, cache identity, brand mode, concurrency safety via `renderIsConcurrencySafe` 200 renders concorrentes).

### 4. Anti-freeze audit (regras críticas)

| Regra | Resultado |
|-------|-----------|
| I/O bloqueante na main thread | ✅ **NENHUM** — `grep` por `DispatchQueue.main.sync`, `Data(contentsOf`, `Thread.sleep`, `waitUntilExit`, `readData` na camada UI → 0 ocorrências |
| `NSMenu` no dropdown | ✅ **NENHUM** — apenas `onClick` hook (popover S3). Sem `NSMenu` |
| Mutação observável incremental | ✅ **OK** — `AppState` expõe **1 única** prop `@Observable` (`snapshot`), atribuída como valor imutável único. Sem observable storm |
| Drawing off-main | ✅ — `Task.detached` + `MainActor.run` (apply) |

### 5. Segurança (CRÍTICO)

✅ **PASS.** A camada UI da EXB-1.2 (`Sources/ClaudeBar/`) **não contém nenhum código de OAuth, token, refresh ou rede** — `grep` por `URLSession`/`URLRequest`/`refresh`/`token` retorna apenas comentários de doc referenciando o "refresh loop" futuro (S4). O invariante de segurança real (CLI-owned token nunca chama refresh endpoint) vive na camada Core (EXB-1.1) e está coberto pelo teste `claudeCLIOwnerNeverCallsRefreshEndpoint` (**passou**) e `pipelineNeverRunsWebSource` (**passou**). Nada nesta story regride essa garantia.

### 6. Fidelidade ao original (`_reference_codexbar`)

Comparação direta arquivo-a-arquivo das porções citadas pela story:

- **AC12 LRU cache** (`IconRenderer.swift:31-70` ref ↔ `:68-104` impl): **fiel** — mesma estrutura lock-guarded, mesma lógica de ordenação/eviction, limite 64.
- **AC9 crab** (`IconRenderer.swift:257-336` ref ↔ `:256-294` impl): **fiel** — arms (3px, `h-6`, `y+3`), 4 legs (`2×3`, step `w/(count+1)`), eyes (`2×5` `.clear` cutouts, mesmos offsets). Removidos `wiggle`/`blink` exatamente como a story exige (P2 deferred).
- **AC10 weekly-absent** (`:671-710` ref ↔ `:182-193` impl): **fiel** — `drawBar(remaining: nil, alpha: 0.45)`.

**Desvio AC9 — aceito como CONCERN não-bloqueante.** A prosa do AC9 diz "arms on **both bars**" e "legs **below the weekly bar**", mas o código de referência citado como autoridade (`addNotches` aplicado **apenas à barra de sessão**) desenha um único crab na barra superior. O dev seguiu o código de referência (tie-breaker explícito do spawn: "replicate pixel by pixel… fidelity is requirement"), documentou no Dev Agent Record, e há divergência prosa-vs-código na própria spec. **Decisão de gate:** a interpretação do dev é a correta segundo a hierarquia de autoridade da story (código de ref > prosa idealizada). Sem impacto funcional — a barra weekly ainda renderiza track/stroke/fill e o caminho dim de ausência. Registro como observação para o PO confirmar a intenção visual numa futura iteração, mas **não bloqueia**.

`[AUTO-DECISION]` Desvio AC9 prosa↔ref → aceitar implementação fiel à ref (reason: spawn directive define código de referência como tie-breaker de fidelidade; divergência é da própria spec, não erro de implementação; zero impacto funcional).

### 7. Escopo / higiene
- Único arquivo unstaged é `docs/stories/EXB-1.1.story.md` — pré-existente, fora do escopo da EXB-1.2, corretamente intocado pelo dev. ✅
- `Sources/ClaudeBar/main.swift` (placeholder EXB-1.1) removido e superseded por `ClaudeBarApp.swift`. ✅

### Veredito

**PASS.** Os 16 ACs estão implementados e verificados no código real; build limpo (zero warnings) e 59 testes passam de árvore limpa; todas as regras anti-freeze respeitadas; invariante de segurança preservado. O único desvio (AC9 crab placement) é uma interpretação correta da hierarquia de autoridade da própria story, documentada e sem impacto funcional — registrado como CONCERN informativo para o PO, não-bloqueante.

> Recomendação ao @po: numa próxima oportunidade, alinhar a prosa do AC9 ("both bars / below weekly bar") com o comportamento de referência (single crab na barra de sessão) para remover a ambiguidade. Não requer rework de código.
