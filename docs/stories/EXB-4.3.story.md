# Story EXB-4.3: Previsão de Esgotamento

**ID:** EXB-4.3
**Status:** Draft
**Depends on:** EXB-3.8 (Keychain fix — OAuth estável para coleta de amostras confiável), EXB-1.4 (AppState + RefreshLoop — `AppState`, `DisplaySnapshot`, `SettingsStore`), EXB-1.7 (CostScanner — base de dados de uso)
**Epic:** EPIC-EXB
**Wave:** Onda 9 (v1.6.0)
**Executor:** @dev
**Quality gate:** @qa

---

## Story

**As a** Claude power user,
**I want** the app to tell me how long until my rate limit runs out at my current pace,
**so that** I can adjust my usage proactively instead of hitting the limit unexpectedly.

---

## Acceptance Criteria

### AC1 — Histórico de amostras persistente e leve

1. O Core mantém um histórico curto de amostras por janela de rate-limit: para cada `RateWindow` identificada (5h session, weekly, opus, sonnet — conforme disponível no `UsageSnapshot`), armazena um array circulante de no máximo **20 amostras** `(timestamp: Date, utilization: Double)`.
2. O histórico é persistido entre relaunches em um arquivo JSON leve em `~/.config/eximiabar/rate-samples.json` (ou `Application Support` equivalente). Se o arquivo não existir ou for inválido, o histórico começa vazio sem crash.
3. O actor/class responsável pelo histórico chama-se `ExhaustionPredictor` e reside em `Sources/ClaudeBarCore/Prediction/ExhaustionPredictor.swift` (novo arquivo). É um Swift `actor` para thread safety.
4. A cada refresh bem-sucedido (`UsageFetcher` retorna novo `UsageSnapshot`), `AppState` adiciona uma amostra para cada janela ativa via `ExhaustionPredictor.addSample(windowId:timestamp:utilization:)`.

### AC2 — Cálculo da taxa de consumo

5. A taxa de consumo (`Double`, utilization/segundo) é calculada como a inclinação de uma **regressão linear simples** sobre as últimas `min(N, 10)` amostras disponíveis, onde N é o total de amostras no histórico.
6. Se houver menos de **3 amostras** para uma janela, o predictor não emite previsão para essa janela — retorna `nil`. Nenhuma extrapolação com dados insuficientes.
7. O cálculo é off-main, realizado dentro do actor `ExhaustionPredictor` — nunca no `@MainActor`.

### AC3 — Previsão de esgotamento

8. A previsão é o tempo em segundos até `utilization == 1.0` com a taxa atual: `timeToExhaustion = (1.0 - currentUtilization) / rate`.
9. Se a taxa for <= 0 (uso estável ou declinando), a previsão é `nil` — "não esgota antes do reset".
10. Se `timeToExhaustion > timeUntilReset` (a janela vai resetar antes de esgotar), a previsão é `nil` — não relevante.
11. O resultado é um `ExhaustionForecast` struct (`Sendable`): `windowId: String`, `minutesRemaining: Double?`, `confidenceLabel: String` (ex: "Alta" / "Baixa" / "Calculando").

### AC4 — Exibição no popover

12. No `UsageCardView` (popover principal), sob a barra de progresso de cada janela com previsão disponível, exibe uma linha discreta: "No ritmo atual, esgota em ~Xh Ym" (ou "~Xmin" se < 1h). Fonte `.caption`, cor secundária.
13. Se `minutesRemaining == nil` (dados insuficientes, taxa <= 0, ou esgota após reset), a linha NÃO é exibida — sem espaço vazio.
14. O texto exibido é localizado em `en.lproj` e `pt-BR.lproj`.

### AC5 — Alerta preditivo (complementar, não duplicado)

15. Um alerta por notificação (`UNUserNotificationCenter`) é enviado quando a previsão indica esgotamento em **<= 30 minutos** no ritmo atual. A notificação só dispara uma vez por janela de rate-limit por ciclo (não repete a cada refresh).
16. O alerta preditivo é independente dos alertas por threshold fixo de `QuotaNotifier` — não substitui, não duplica (checar se `QuotaNotifier` já enviou alerta para a mesma janela no mesmo ciclo antes de enviar o preditivo).
17. Preferência "Habilitar alerta preditivo" adicionada em Settings → Notifications pane (default: ON). Quando OFF, nenhuma notificação preditiva é enviada.

### AC6 — Regressão e build

18. `swift build -c release` zero warnings (clean `.build`).
19. `swift test --no-parallel` sem regressões (223+ testes baseline); pelo menos **5 novos testes unitários**: `noForecastWithLessThan3Samples`, `noForecastIfRateNegative`, `forecastCalculationLinearSlope`, `forecastNilIfExhaustionAfterReset`, `samplesCircularBufferMax20`.

---

## Tasks

- [ ] **T1 — Criar `ExhaustionPredictor` actor** (AC1, AC2, AC3) — `Sources/ClaudeBarCore/Prediction/ExhaustionPredictor.swift`
  - [ ] `actor ExhaustionPredictor`; constantes: `maxSamples = 20`, `minSamples = 3`
  - [ ] `struct RateSample: Codable, Sendable { timestamp: Date; utilization: Double }`
  - [ ] `struct ExhaustionForecast: Sendable { windowId: String; minutesRemaining: Double?; confidenceLabel: String }`
  - [ ] `func addSample(windowId: String, timestamp: Date, utilization: Double)` — adiciona ao buffer circular; persiste JSON
  - [ ] `func forecast(windowId: String, currentUtilization: Double, secondsUntilReset: Double) -> ExhaustionForecast` — regressão linear, retorna previsão ou nil nos casos AC2/AC3
  - [ ] `func loadFromDisk()` / `func saveToDisk()` — JSON em Application Support ou `~/.config/eximiabar/`

- [ ] **T2 — Integrar no refresh loop** (AC1) — `Sources/ClaudeBar/App/AppState.swift` + `RefreshCoordinator`
  - [ ] Após cada fetch bem-sucedido: para cada `RateWindow` no `UsageSnapshot`, chamar `ExhaustionPredictor.addSample(windowId: window.id, timestamp: Date(), utilization: window.utilization)`
  - [ ] Incluir `ExhaustionForecast` array no `DisplaySnapshot` como `forecasts: [ExhaustionForecast]`

- [ ] **T3 — Exibir previsão no popover** (AC4) — `Sources/ClaudeBar/Popover/UsageCardView.swift`
  - [ ] Para cada `RateWindow` no card, verificar se `snapshot.forecasts` contém forecast para `windowId`
  - [ ] Se `minutesRemaining != nil`: exibir linha discreta sob a barra com texto formatado
  - [ ] Helper de formatação: `formatMinutes(_ m: Double) -> String` — "<1h → "{m}min"; >=1h → "{h}h {m}min"

- [ ] **T4 — Alerta preditivo** (AC5) — `Sources/ClaudeBar/Notifications/QuotaNotifier.swift`
  - [ ] Adicionar lógica de alerta preditivo (threshold 30min) separada do threshold fixo
  - [ ] Deduplicação: set de `windowId` já alertados no ciclo atual; limpar ao resetar a janela

- [ ] **T5 — Settings: preferência notificação preditiva** (AC5) — `Sources/ClaudeBar/Settings/`
  - [ ] Adicionar `predictiveAlertsEnabled: Bool` a `SettingsStore` (default: `true`)
  - [ ] Adicionar toggle no Notifications pane

- [ ] **T6 — Localização** (AC4) — `en.lproj` + `pt-BR.lproj`
  - [ ] Chave "exhaust.forecast" para "At current pace, runs out in ~%@" / "No ritmo atual, esgota em ~%@"

- [ ] **T7 — Testes** (AC6) — `Tests/ClaudeBarTests/ExhaustionPredictorTests.swift`
  - [ ] 5+ testes unitários (AC6); tudo off-main (`await predictor.forecast(...)`)

---

## Dev Notes

### Arquivos relevantes do baseline

| Arquivo | Papel |
|---------|-------|
| `Sources/ClaudeBarCore/Model/UsageSnapshot.swift` | `DisplaySnapshot`, `RateWindow` (tem `utilization: Double`, `windowId`, `secondsUntilReset`) |
| `Sources/ClaudeBar/App/AppState.swift` | `@MainActor @Observable class AppState`; publica `DisplaySnapshot` |
| `Sources/ClaudeBar/Notifications/QuotaNotifier.swift` | Alertas por threshold fixo — referência para deduplicação |
| `Sources/ClaudeBar/Popover/UsageCardView.swift` | Popover com barra de progresso por janela |
| `Sources/ClaudeBar/Settings/SettingsStore.swift` | Preferências persistidas (referência para adicionar `predictiveAlertsEnabled`) |

### Regressão linear simples (inclinação)

```swift
// Dados: array de (x: TimeInterval desde início, y: utilization)
// Slope (taxa em utilization/segundo):
func slope(samples: [(x: Double, y: Double)]) -> Double? {
    guard samples.count >= 2 else { return nil }
    let n = Double(samples.count)
    let sumX = samples.map(\.x).reduce(0, +)
    let sumY = samples.map(\.y).reduce(0, +)
    let sumXY = samples.map { $0.x * $0.y }.reduce(0, +)
    let sumX2 = samples.map { $0.x * $0.x }.reduce(0, +)
    let denom = n * sumX2 - sumX * sumX
    guard abs(denom) > 1e-10 else { return nil }
    return (n * sumXY - sumX * sumY) / denom
}
```

### Buffer circular — máximo 20 amostras

```swift
var samples: [RateSample] = []
// ao adicionar:
samples.append(newSample)
if samples.count > maxSamples { samples.removeFirst() }
```

### Persistência — Application Support

```swift
let support = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first!
    .appendingPathComponent("ExímIABar")
    .appendingPathComponent("rate-samples.json")
```

Criar diretório se não existir: `try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)`.

### Anti-freeze invariants

- Toda lógica do `ExhaustionPredictor` (incluindo persistência em disco) é executada dentro do actor — nunca direto no `@MainActor`
- `AppState` chama `await predictor.addSample(...)` dentro de `Task.detached` ou como `Task` sem `@MainActor`
- `DisplaySnapshot` é imutável e `Sendable` — adicionar `forecasts: [ExhaustionForecast]` com o tipo também `Sendable`

### Testing

- Framework: XCTest ou Swift Testing — padrão do repo
- Baseline: 223+ testes; zero regressões obrigatório
- Arquivo: `Tests/ClaudeBarTests/ExhaustionPredictorTests.swift` (novo)
- `swift test --no-parallel`

---

## Definition of Done

- [ ] `ExhaustionPredictor` actor criado, testado, off-main
- [ ] Amostras persistidas em disco entre relaunches
- [ ] `DisplaySnapshot.forecasts` alimentado a cada refresh
- [ ] Linha de previsão visível no popover (quando dados suficientes)
- [ ] Alerta preditivo <=30min (deduplicado, preferência respeitada)
- [ ] 5 novos testes verdes; zero regressões
- [ ] `swift build -c release` zero warnings

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-18 | 1.0 | Initial draft — Onda 9 (v1.6.0) | @sm River |
