# Onda 11 — Correções de medida no dashboard

> **Especificação executável** — insumo direto para o `@dev`. Cada correção traz função, linha, comportamento errado, comportamento correto e **o teste vermelho literal**.
> **Autor:** Aria (@architect) · **Data:** 2026-08-24 · **Status:** Proposto, aguarda validação `@po`
> **Objeto:** `Sources/ClaudeBar/Dashboard/DashboardData.swift` e o que dele decorre em `DashboardView.swift` e `DashboardWindowController.swift`.
> **Irmão:** `onda-11-exportacao.md` (o pacote de export). Este documento **não** o altera.
> **Escopo:** especificação. **Nenhum arquivo Swift foi alterado.**

---

## 0. Sumário

Oito correções, todas no mesmo arquivo ou decorrentes dele, para serem aplicadas **numa única abertura** quando a frente de performance liberar `DashboardData.swift`.

O fio que liga as oito: **o dashboard hoje mede com réguas cujo denominador não corresponde ao que está sendo medido.** Divide por 90 dias quando a fonte cobre 55; compara um dia pela metade contra dias inteiros; precifica token de entrada pela tabela de saída. Cada uma sozinha é um número torto; juntas, formam um painel que responde com precisão a perguntas que não são as perguntas.

### Os três achados que mudam o trabalho pedido

| # | Achado | Consequência |
|---|---|---|
| **A1** | **A correção #4 não é uma correção — é uma deleção.** `CachePricing` tem **exatamente um consumidor** em toda a árvore: `estimatedCacheSavings` (verificado por grep em `Sources/` e `Tests/`). Como a decisão do dono tira o valor em dólar da tela (#3), o tipo `CachePricing`, o método `cachePricing(for:scanner:)` do controller e o `await scanner.modelPrice(...)` ficam **sem nenhum consumidor**. | Não se especifica acumulação por modelo de um número que deixa de existir. #4 vira subtração. **Efeito colateral bom:** remove um `await` na actor `Pricing` de dentro do caminho de scan — um presente pequeno para a frente de performance. |
| **A2** | **Existe um teste VERDE que consagra o bug do cache.** `DashboardInsightsTests.swift:92`: `#expect(abs(data.estimatedCacheSavings - 0.0147) < 1e-9)`. O valor `0.0147` é exatamente `1000 × (0.000015 − 0.0000003)`, ou seja, **o número inflado**. O teste não falha porque foi escrito a partir do comportamento, não do significado. | O gate desta onda **não** é "manter os testes verdes". É **deletar** esse teste junto com o campo. Um teste que fixa o defeito é pior que nenhum teste, porque impede a correção e parece diligência. |
| **A3** | **`chartXSelection(range:)` existe no macOS 14 — verificado, não presumido.** Probe compilado com `xcrun swiftc -target arm64-apple-macos14.0 -typecheck`, exit **0**, para `range:` e `value:`. | A faixa arrastável (#8) tem API nativa; o `DragGesture` sobre `chartOverlay` (já usado em 4 pontos do repo) vira **fallback**, não o plano principal. |

### A inflação do cache é exata, não aproximada

A tabela de fallback (`Pricing.swift:30-32`) tem `output = 5 × input` para **todas** as famílias (`opus-4`: 0.000015/0.000075; `sonnet-4` e `3-5-sonnet`: 0.000003/0.000015). Logo a razão entre a conta errada e a certa é uma identidade algébrica, idêntica para qualquer modelo:

```
errado = cacheRead × (output − 0,1·input) = cacheRead × (5·input − 0,1·input) = 4,90 · input · cacheRead
certo  = cacheRead × (input  − 0,1·input) =                                     0,90 · input · cacheRead
razão  = 4,90 / 0,90 = 5,444…
```

**5,44× exatos**, não "cerca de 5,4×".

---

## 1. Denominador honesto

| | |
|---|---|
| **Função** | `DashboardData.build(from:period:now:cachePricing:)` |
| **Linha** | `DashboardData.swift:311` — `let averageDaily = periodCost / Double(span)`, com `span = max(1, period.days)` |
| **Errado** | Divide pela **largura da janela pedida**. Na janela de 90 d sobre uma fonte que cobre ~55 dias, o divisor é 90 para 55 dias de dado: a média sai ~40% subestimada. E como `dailyDelta` consome esse valor (linha 330), a distorção se propaga para o badge da tela. |
| **Correto** | Dividir pelos **dias com dado**. |

### 1.1 A definição, que é o miolo da correção

**Dia com dado = dia dentro do intervalo coberto pela fonte, interseccionado com a janela.** Não é "dia com tokens > 0".

Um dia real de não uso é **dado legítimo** e entra no denominador: se o Senhor não usou o Claude na terça, a média diária dele *deve* cair. Um dia anterior ao início do histórico **não** entra: ali não houve não-uso, houve ausência de observação. Confundir os dois erra a média **nas duas direções opostas**, e é por isso que o teste da §1.3 discrimina os três divisores candidatos.

```
coberturaInicio  = menor `date` presente em analytics.byDayModel   (start-of-day)
janelaInicio     = todayStart − (span − 1) dias
inicioEfetivo    = max(coberturaInicio, janelaInicio)
diasComDado      = número de dias de inicioEfetivo até todayStart, inclusive   (≥ 1)
averageDaily     = periodCost / Double(diasComDado)
```

**Limitação declarada, e a direção do erro residual.** `coberturaInicio` é o primeiro dia com *atividade*, que é o único sinal observável — a fonte não diz "meu histórico começa aqui". Se o histórico começou em 01/07 mas o primeiro uso foi em 03/07, os dois dias de não-uso iniciais ficam de fora do denominador. O erro residual é portanto **limitado à sequência inicial de dias sem uso** e empurra a média para **cima** (denominador menor). É conservador na direção certa: nunca faz o consumo parecer menor do que foi.

### 1.2 Campo novo, para a tela e para a planilha

`DashboardData` ganha `let diasComDado: Int`, porque o número precisa ser **exibível** — a §3.1 do doc de exportação já o consome, e a tela precisa rotular a média com o divisor (`"média por dia com uso"`).

### 1.3 Teste vermelho

Fixture desenhada para que **nenhum dos três divisores plausíveis produza o mesmo resultado**: janela de 90, cobertura de 10 dias, atividade em apenas 2 deles.

```swift
// Tests/ClaudeBarTests/DashboardDenominatorTests.swift
import ClaudeBarCore
import Foundation
import Testing
@testable import ClaudeBar

struct DashboardDenominatorTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000) // instante fixo

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
    }

    private func entry(_ date: Date, cost: Double) -> ModelCostEntry {
        ModelCostEntry(model: "claude-sonnet-4", date: date,
                       inputTokens: 5_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheWriteTokens: 0, cost: cost)
    }

    /// A média diária divide pelos dias COBERTOS (10), não pela janela (90)
    /// nem pelos dias com uso (2).
    ///
    /// Cobertura: de 9 dias atrás até hoje = 10 dias.
    /// Atividade: só em 2 desses dias, 15.0 cada → periodCost = 30.0.
    ///
    ///   divisor 90 (o bug de hoje) → 0,3333…
    ///   divisor  2 (o erro oposto) → 15,0
    ///   divisor 10 (o correto)     →  3,0
    @Test
    func mediaDiariaDividePelosDiasCobertos() {
        let analytics = UsageAnalytics(
            byDayModel: [entry(day(9), cost: 15.0), entry(day(0), cost: 15.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .ninetyDays, now: now)

        #expect(data.diasComDado == 10)
        #expect(abs(data.averageDailyCost - 3.0) < 1e-9)     // hoje falha: vale 0,3333…
        #expect(abs(data.averageDailyCost - 15.0) > 1e-9)    // e não é o erro oposto
    }

    /// Um dia de NÃO USO dentro da cobertura conta no denominador.
    /// Sem isto, a correção erra para o outro lado.
    @Test
    func diaSemUsoDentroDaCoberturaEntraNoDenominador() {
        // Atividade em 4 e 0 dias atrás → cobertura de 5 dias, 3 deles sem uso.
        let analytics = UsageAnalytics(
            byDayModel: [entry(day(4), cost: 10.0), entry(day(0), cost: 10.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)

        #expect(data.diasComDado == 5)
        #expect(abs(data.averageDailyCost - 4.0) < 1e-9)     // 20 ÷ 5, não 20 ÷ 2 = 10
    }

    /// Janela menor que a cobertura: o divisor é a janela, não a história inteira.
    @Test
    func janelaMenorQueACoberturaLimitaODenominador() {
        let entries = (0...20).map { entry(day($0), cost: 1.0) }   // 21 dias cobertos
        let analytics = UsageAnalytics(
            byDayModel: entries, byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .sevenDays, now: now)

        #expect(data.diasComDado == 7)                        // limitado pela janela
        #expect(abs(data.averageDailyCost - 1.0) < 1e-9)
    }
}
```

---

## 2. Delta prorrateado

| | |
|---|---|
| **Função** | `DashboardData.dailyDelta(todayCost:todayTokens:averageDailyCost:)` |
| **Linha** | `DashboardData.swift:379-383`, consumida em `:330` e exibida em `DashboardView.swift:355` |
| **Errado** | Compara o dia de hoje **ainda em curso** contra uma média de dias **inteiros**. Às 9h da manhã, 37,5% do dia decorreu, então o badge é aritmeticamente obrigado a dizer "abaixo da média" mesmo num dia de uso recordista. O erro é máximo logo após a meia-noite e vai a zero às 23h59 — ou seja, **a tela é mais errada quanto mais cedo o Senhor a abre**. |
| **Correto** | Normalizar hoje pela fração do dia decorrida antes de comparar. **E comparar tokens, não custo** (correção #6 — as duas mudam a mesma função e têm de ser feitas juntas). |

### 2.1 A normalização, com piso e zona morta

```
fracao = segundos decorridos desde todayStart ÷ 86.400

se fracao < 1/24        (primeira hora)  → nil   — "cedo demais para comparar"
senão fracaoEfetiva = max(fracao, 0,125)         — piso de 3 h
projetado = Double(todayTokens) / fracaoEfetiva
delta     = (projetado − mediaDiariaTokens) / mediaDiariaTokens
```

**Por que os dois limites, e não um só.** Sem zona morta, às 00:05 dividimos por 0,0035 e amplificamos qualquer ruído em 288×: uma única mensagem viraria "+28.000% acima da média". Sem piso, a faixa entre 1h e 3h ainda amplifica de 24× a 8×. O piso de 3h faz a projeção **subestimar** nessa faixa — direção deliberada: um painel que erra dizendo "ainda abaixo" às 2h da manhã é honesto; um que grita "recorde histórico" com 40 minutos de uso não é.

**Estado `nil` agora tem dois significados**, e a tela precisa distingui-los: *"sem uso hoje"* (o caso atual, `todayTokens == 0`) e *"cedo demais"* (novo, primeira hora do dia). Recomendo um enum de dois casos em vez de `Double?`, para que `DashboardView.swift:355` não tenha de adivinhar qual dos dois está exibindo.

### 2.2 Teste vermelho

Fixture escolhida para **inverter o sinal**: hoje está no dobro do ritmo médio, e a implementação atual diz "25% abaixo".

```swift
// Tests/ClaudeBarTests/DashboardDeltaTests.swift
struct DashboardDeltaTests {
    /// 09:00 local num dia qualquer — 37,5% do dia decorrido.
    private func hoje(as horas: Int, _ minutos: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_787_000_000))
        return cal.date(byAdding: .init(hour: horas, minute: minutos), to: base)!
    }

    /// Às 9h, com 3.000 tokens e média de 4.000/dia, o ritmo real é 8.000/dia —
    /// o DOBRO da média. A implementação de hoje diz −25%.
    @Test
    func deltaNormalizaPelaFracaoDoDiaDecorrida() {
        let delta = DashboardData.dailyDelta(
            todayTokens: 3_000,
            averageDailyTokens: 4_000,
            now: hoje(as: 9))

        #expect(delta != nil)
        #expect(abs(delta! - 1.0) < 1e-9)      // +100%; hoje falha valendo −0,25
        #expect(delta! > 0)                     // o sinal, que é o que o Senhor lê
    }

    /// Primeira hora do dia: não há base para comparar.
    @Test
    func primeiraHoraNaoProduzDelta() {
        #expect(DashboardData.dailyDelta(
            todayTokens: 500, averageDailyTokens: 4_000, now: hoje(as: 0, 30)) == nil)
    }

    /// Piso de 3 h: às 2h, 500 tokens são projetados como 4.000/dia (delta 0),
    /// não como 6.000/dia (delta +0,5) que a fração crua daria.
    @Test
    func pisoDeTresHorasAmorteceOInicioDoDia() {
        let delta = DashboardData.dailyDelta(
            todayTokens: 500, averageDailyTokens: 4_000, now: hoje(as: 2))

        #expect(abs(delta! - 0.0) < 1e-9)
        #expect(abs(delta! - 0.5) > 1e-9)      // não é a fração crua
    }

    /// Fim do dia: a normalização converge para a comparação direta.
    @Test
    func fimDoDiaConvergeParaComparacaoDireta() {
        let delta = DashboardData.dailyDelta(
            todayTokens: 4_000, averageDailyTokens: 4_000, now: hoje(as: 23, 59))

        #expect(abs(delta!) < 0.001)
    }
}
```

---

## 3. A conta do cache

| | |
|---|---|
| **Funções** | cálculo em `DashboardData.swift:326-327`; taxa em `:370-374`; exibição em `DashboardView.swift:362` |
| **Errado (valor)** | `cacheRead × (outputPerToken − cacheReadPerToken)`. Tokens de cache são tokens de **entrada**; precificá-los pela tabela de **saída** infla **5,44× exatos** (§0). |
| **Errado (taxa)** | `cacheRead ÷ (input + cacheRead)` — **exclui `cacheWrite`**, que também é token de entrada consumido. A taxa sai maior que a verdade. |
| **Errado (formato)** | Arredondamento exibe a taxa `0,9996` como `"100.0%"`, afirmando um absoluto que não ocorreu. |
| **Correto** | O valor em dólar **sai da tela** (decisão do dono). A taxa sobrevive como fato, no rodapé do gráfico de tokens, no formato **"X dos Y tokens vieram do cache"**. |

### 3.1 O que some, e o que fica

**Some:** `DashboardData.estimatedCacheSavings`, o tipo `CachePricing`, o parâmetro `cachePricing:` de `build`, o método `DashboardWindowController.cachePricing(for:scanner:)` e a chamada `await scanner.modelPrice(...)`. **E o teste `DashboardInsightsTests.swift:83-92`, que consagra o número inflado** (achado A2) — ele é deletado, não ajustado.

**Fica:** a taxa, com denominador completo e formatação que não mente.

```
taxa = cacheRead / (input + cacheRead + cacheWrite)        // denominador completo
```

Rodapé, com os números absolutos ao lado da porcentagem, porque é o absoluto que dá sentido à taxa:

> `2.499.000 dos 2.500.000 tokens de entrada vieram do cache (99.9%)`

**Formatação:** truncar, nunca arredondar, quando a taxa for `< 1,0`:
`exibida = floor(taxa × 1000) / 10`. Assim a taxa `0,9996` sai como `"99.9%"`, e `"100.0%"` só aparece quando ela é exatamente 1.

> **Separador decimal: ponto, não vírgula.** Esta especificação foi escrita com vírgula (`"99,9%"`) e a
> implementação usa **ponto**. Divergência levantada pelo `@dev` ao encostar no código e **aprovada pelo
> `@po`** — o ponto é o único separador decimal do painel inteiro (`tokenCount` → `"500.0K"`,
> `compactCurrency` → `"$3.20"`, e o `percent1` substituído → `"63.4%"`), então a vírgula seria a única
> da tela; e a suíte roda contra a base em inglês (`Localization.swift` força `"en"` em processo de
> teste), o que prenderia o teste a uma convenção que a tela não usa. **O requisito substantivo é o
> truncamento, não o separador** — ele está preservado e provado por mutação (arredondar de volta faz
> `0,9996` imprimir `"100.0%"`, e o teste fica vermelho).

### 3.2 Teste vermelho

```swift
// Tests/ClaudeBarTests/DashboardCacheRateTests.swift
struct DashboardCacheRateTests {
    /// cacheWrite entra no denominador. Sem ele a taxa é 0,75; com ele, 0,60.
    @Test
    func taxaIncluiCacheWriteNoDenominador() {
        let taxa = DashboardData.cacheHitRate(input: 1_000, cacheRead: 3_000, cacheWrite: 1_000)

        #expect(abs(taxa - 0.60) < 1e-9)     // hoje falha valendo 0,75
        #expect(abs(taxa - 0.75) > 1e-9)
    }

    /// A taxa 0,9996 sai como "99.9%", nunca "100.0%" — o absoluto que não ocorreu.
    @Test
    func taxaTruncaEmVezDeArredondar() {
        let taxa = DashboardData.cacheHitRate(input: 1, cacheRead: 2_499, cacheWrite: 0)
        #expect(abs(taxa - 0.9996) < 1e-9)

        #expect(DashboardFormat.taxaCache(taxa) == "99.9%")   // hoje falha: "100.0%"
        #expect(DashboardFormat.taxaCache(1.0) == "100.0%")   // o absoluto real ainda aparece
    }

    /// Denominador zero não vira NaN.
    @Test
    func semAtividadeNaoProduzNaN() {
        #expect(DashboardData.cacheHitRate(input: 0, cacheRead: 0, cacheWrite: 0) == 0)
    }
}
```

### 3.3 Gate mecânico da remoção

```bash
grep -rn "estimatedCacheSavings\|CachePricing\|cacheReadInputRatio" Sources/ Tests/ --include="*.swift"
# esperado: nenhuma ocorrência
```

---

## 4. Preço por modelo — **esta correção é uma deleção**

| | |
|---|---|
| **Função** | `DashboardWindowController.cachePricing(for:scanner:)` |
| **Linha** | `DashboardWindowController.swift:260-273` (as linhas deslocaram; a outra frente editou o arquivo) |
| **Errado** | Resolve o preço do modelo **dominante** (maior custo na janela) e aplica esse preço ao cache de **todos** os modelos. Numa janela mista Opus + Sonnet, o cache do Sonnet é precificado a preço de Opus — 5× a mais. |
| **Correto** | **Deletar.** |

O pedido original era especificar a acumulação por modelo dentro do fold que já percorre `byDayModel`. Verifiquei antes de escrever e a premissa caiu: `CachePricing` tem **exatamente um consumidor** em toda a árvore, o `estimatedCacheSavings` (achado A1). Como a decisão do dono tira o dólar da tela (#3), **não existe mais número a acumular**. Especificar uma acumulação correta para alimentar um campo que é removido três seções acima seria trabalho que nasce morto.

**Se o `@po` decidir que o valor em dólar volta** — e é decisão dele, não minha —, a acumulação correta é esta, e ela cabe no fold que já existe:

```
para cada entry em analytics.byDayModel:
    economiaPorModelo[entry.model] += Double(entry.cacheReadTokens) × 0,9 × precoEntrada(entry.model)
economiaTotal = soma de economiaPorModelo
```
com `precoEntrada` resolvido **uma vez por modelo distinto** (não por linha), antes do fold, num `[String: Double]`. O ganho colateral de deletar: some um `await` na actor `Pricing` de dentro do `Task.detached` do scan.

⚠️ **Colisão ativa:** `DashboardWindowController.swift` está sendo editado pela frente de performance **neste momento**. Esta correção não pode ser aplicada sem coordenação (§9).

---

## 5. Sem uso ≠ sem dado

| | |
|---|---|
| **Função** | o eixo diário em `DashboardData.build`, `DashboardData.swift:249-263` (`byDay[day] ?? DayAcc()`), consumido pelos gráficos em `DashboardView.swift:317-318` |
| **Errado** | O eixo é zero-preenchido na **janela inteira**. Dias anteriores ao início do histórico viram barras de altura zero, visualmente idênticas a um dia real de abstinência. Na janela de 90 d sobre a fonte atual, isso são ~35 barras que afirmam "não usei nada" sobre um período que o app simplesmente não observou. |
| **Correto** | O tipo carrega a distinção, e o gráfico a representa como **lacuna**, não como zero. |

### 5.1 O tipo

`DashboardDailyEntry` ganha `let coberto: Bool` — `true` quando `date >= coberturaInicio` (a mesma âncora da §1.1; uma definição, dois consumidores).

**Por que um flag e não `Double?`:** tornar `costUSD` opcional obrigaria todo call site somador a desembrulhar, e são muitos. O flag é aditivo, e o padrão do repo já é esse (valores concretos + presença explícita).

### 5.2 O que cada superfície faz

| Superfície | Comportamento |
|---|---|
| `CostPerDayChart` (`LineMark`) | Não emite marca para `!coberto`. A linha **começa** no primeiro dia coberto — o Swift Charts produz a lacuna naturalmente ao pular o ponto. |
| `StackedTokensChart` (`BarMark`) | Não emite barra para `!coberto`. Ausência de barra ≠ barra de altura zero. |
| Eixo X | Continua abrangendo a janela pedida, para não mentir sobre o período **solicitado**. O que muda é que a área não coberta fica visivelmente vazia. |
| KPIs de **total** | Inalterados (somar zeros não muda soma). |
| KPIs de **média** | Usam `diasComDado` (§1) — é a mesma correção vista de outro ângulo. |
| Planilha e painel | Já especificados no doc irmão (§3.2 e §4.3.3): célula vazia e ponto ausente. |

### 5.3 Teste vermelho

```swift
// Tests/ClaudeBarTests/DashboardCoverageTests.swift
struct DashboardCoverageTests {
    /// Janela de 30 dias, histórico começando 9 dias atrás:
    /// 10 dias cobertos, 20 descobertos — e os 20 NÃO são zeros legítimos.
    @Test
    func diasAnterioresAoHistoricoNaoSaoZeros() {
        let analytics = UsageAnalytics(
            byDayModel: [entry(day(9), cost: 1.0), entry(day(0), cost: 1.0)],
            byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [], monthToDateCost: 0)

        let data = DashboardData.build(from: analytics, period: .thirtyDays, now: now)

        #expect(data.dailyCosts.count == 30)                              // o eixo continua 30
        #expect(data.dailyCosts.filter { $0.coberto }.count == 10)        // hoje falha: 30
        #expect(data.dailyCosts.filter { !$0.coberto }.count == 20)

        // O dia SEM USO dentro da cobertura é coberto, e vale zero legitimamente.
        let semUso = data.dailyCosts.first { $0.date == day(5) }
        #expect(semUso?.coberto == true)
        #expect(semUso?.costUSD == 0)

        // O dia FORA da cobertura também vale zero — mas não é a mesma coisa.
        let semDado = data.dailyCosts.first { $0.date == day(20) }
        #expect(semDado?.coberto == false)
    }
}
```

O par de asserções finais é o coração do teste: **os dois dias têm `costUSD == 0` e significados opostos.** Uma implementação que só olhasse o valor não conseguiria distingui-los, e é exatamente isso que o gráfico faz hoje.

---

## 6. Tokens em primeiro plano, custo em segundo

Decisão do dono: ele paga **assinatura**, não fatura por token. O dólar é estimativa de valor consumido, não conta a pagar.

### 6.1 Pontos afetados em `DashboardView.swift`

| Linha | Hoje | Correto |
|---|---|---|
| `:355` | `SummaryCard(… badge: DeltaBadgeModel(delta: data.dailyDelta))` — delta em **custo** | delta em **tokens** (a mesma função da §2) |
| `:358` | `SummaryCard(title: avg_daily, tokens: averageDailyTokens, cost: data.averageDailyCost)` | tokens como número principal; custo em linha secundária; rótulo passa a nomear o divisor: **"média por dia com uso"** |
| `:359` | `SummaryCard(title: projection, tokens: data.projectedTokens, cost: data.monthProjection)` | **projeção em tokens** como número principal (§6.2) |
| `:362` | `CacheHitCard(hitRate:savings:)` | `savings` removido (§3) |
| `:317-318` | `CostPerDayChart` antes de `StackedTokensChart` | **ordem invertida**: tokens/dia é o gráfico primário |
| `:221-227` + `sortedModelNames` (`:207`) | ordem dos modelos por **custo** desc | ordem por **volume de tokens** desc |
| `byModel` (`DashboardData.swift:274`) | `.sorted { $0.costUSD > $1.costUSD }` | ordenar por `inputTokens + outputTokens` desc |
| `byProject` | vem de `UsageAnalytics`, ordenado por custo | reordenar por `totalTokens` desc na `build` |

> **Efeito colateral a não esquecer:** `sortedModelNames` é o que garante *"modelo N sempre recebe a cor N"* (comentário em `DashboardData.swift:203-206`). Mudar o critério de ordenação **muda as cores** da rosca, da tabela e do gráfico por modelo. É correto e desejado, mas qualquer teste que fixe cor por posição precisa ser revisto junto — não é regressão.

### 6.2 A projeção mensal, e o bloqueio que ela revela

`monthProjection` (`DashboardData.swift:309`) projeta **custo**, a partir de `analytics.monthToDateCost`. `projectedTokens` (`:315`) é derivado por regra de três sobre a razão tokens÷custo da janela — um número de segunda mão que erra sempre que o mix de modelos do mês difere do mix da janela.

**`UsageAnalytics` não tem `monthToDateTokens`.** Para projetar tokens honestamente é preciso adicioná-lo, e ele é calculado no mesmo fold que já produz `monthToDateCost`, em **`CostScanner+Analytics.swift`** — arquivo aberto pela frente de performance. Duas linhas, mas em território alheio (§9).

```
// no fold existente de makeAnalytics:
if row.timestamp >= monthStart, row.timestamp <= now {
    monthToDate += row.cost
    monthToDateTokens += row.inputTokens + row.outputTokens
                       + row.cacheReadTokens + row.cacheWriteTokens   // ← novo
}
```

Com o campo real, `projectedTokens` deixa de ser derivado e passa a ser projeção direta pela mesma regra de run-rate já usada para custo. `projectedTokens(periodTokens:periodCost:projectedCost:)` (`:313`) é **deletado** junto com a razão que ele implementa.

---

## 7. A régua mensal: comparação com o mês anterior

Decisão do dono: nada de teto declarado; comparação automática com o mês anterior, **em tokens**.

### 7.1 A armadilha, e por que a comparação óbvia mente

O reflexo é comparar **mês corrente até agora** contra **mês anterior inteiro**. Isso está errado e o erro tem sinal fixo: em 24 de agosto, comparar 24 dias contra 31 produz **−22,6%** mesmo que o ritmo diário seja rigorosamente idêntico. O painel diria "consumo caindo" todo dia 1º de cada mês, sem exceção, para sempre.

**Correto: comparar faixas equivalentes.** Dias 1..N do mês corrente contra dias 1..N do mês anterior, com `N = dia de hoje`.

```
N              = componente .day de now
tokensAtual    = soma de tokens nos dias 1..N do mês corrente
tokensAnterior = soma de tokens nos dias 1..N do mês anterior
variacao       = (tokensAtual − tokensAnterior) / tokensAnterior
```

**Meses de comprimentos diferentes:** se `N` excede o comprimento do mês anterior (31 de março vs. fevereiro), truncar `N` ao comprimento do mês anterior e **rotular o recorte** — "1–28 de fev vs 1–28 de mar" —, nunca comparar 31 contra 28 em silêncio.

### 7.2 De onde sai o número, e quando ele não existe

Exige que o scan cubra o mês anterior inteiro. Com a janela de 30 d em 24/08, julho está **fora** — logo **esta correção depende da #8** (um scan da história inteira). Enquanto #8 não existir, a comparação só é possível na janela de 90 d, e a de 7 d nunca a teria.

**Quando não há mês anterior completo** (primeira instalação, histórico começando no meio do mês anterior — que é exatamente o caso desta máquina, cujo histórico começa em 01/07): **não exibir a comparação.** Não estimar, não extrapolar, não comparar contra um mês parcial fingindo que é inteiro. O cartão some, ou mostra *"sem mês anterior completo para comparar"*. A cobertura do mês anterior é verificável pela mesma âncora `coberturaInicio` da §1.1: só há base se `coberturaInicio <= primeiro dia do mês anterior`.

### 7.3 Teste vermelho

Fixture com **ritmo diário rigorosamente idêntico** nos dois meses: a resposta certa é 0%, e a armadilha dá −22,6%.

```swift
// Tests/ClaudeBarTests/DashboardMonthlyComparisonTests.swift
struct DashboardMonthlyComparisonTests {
    /// Julho e agosto com 100 tokens/dia idênticos. Em 24 de agosto:
    ///   correto  (1–24 jul vs 1–24 ago): 2.400 vs 2.400 → 0%
    ///   armadilha (jul inteiro vs ago até agora): 3.100 vs 2.400 → −22,6%
    @Test
    func comparaFaixasEquivalentesNaoMesInteiro() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-07-01", ate: "2026-08-24", tokensDia: 100),
            now: data("2026-08-24"))

        #expect(comp != nil)
        #expect(abs(comp!.variacao - 0.0) < 1e-9)        // ritmo igual → variação zero
        #expect(abs(comp!.variacao + 0.226) > 0.01)      // e NÃO a armadilha
        #expect(comp!.diasComparados == 24)
    }

    /// Sem mês anterior completo, não há comparação — e não se inventa uma.
    @Test
    func semMesAnteriorCompletoNaoComparaNada() {
        // histórico começa em 15/07: julho está incompleto
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-07-15", ate: "2026-08-24", tokensDia: 100),
            now: data("2026-08-24"))

        #expect(comp == nil)
    }

    /// 31 de março vs fevereiro: trunca ao mês menor e rotula o recorte.
    @Test
    func mesesDeComprimentosDiferentesTruncamAoMenor() {
        let comp = DashboardData.comparacaoMensal(
            tokensPorDia: ritmoConstante(de: "2026-02-01", ate: "2026-03-31", tokensDia: 100),
            now: data("2026-03-31"))

        #expect(comp!.diasComparados == 28)              // não 31
        #expect(abs(comp!.variacao - 0.0) < 1e-9)
    }
}
```

---

## 8. O seletor de período vira faixa arrastável

Decisão do dono: um scan carrega a história inteira e o Senhor **arrasta uma faixa** sobre a linha do tempo. Os botões 7d/30d/tudo permanecem como **atalhos**, não como modos.

### 8.1 A mudança de arquitetura, em uma frase

Hoje o período é **entrada do scan** (`scanAnalytics(windowDays:)`) e trocar de período **re-escaneia**. Passa a ser **recorte de apresentação** sobre um conjunto já carregado: o scan roda uma vez com a história inteira, e a faixa é uma função pura sobre as linhas em memória.

```
scan (I/O, uma vez)  →  [ModelCostEntry] da história inteira  →  slice(faixa) → DashboardData
```

Isto **elimina** o cache por período (`cache[DashboardPeriod]` em `DashboardWindowController.swift:196`), que existia só para evitar o re-scan. E é o que torna a #7 possível (a comparação mensal precisa do mês anterior, que a janela de 30 d não alcança).

### 8.2 A interação — API verificada, não presumida

**`chartXSelection(range:)` está disponível no macOS 14.** Verificado por compilação, não por documentação:

```
$ xcrun swiftc -target arm64-apple-macos14.0 -typecheck probe-sel.swift
$ echo $?
0
```

O probe usou `.chartXSelection(range: $faixa)` com `@State var faixa: ClosedRange<Date>?` e `.chartXSelection(value: $ponto)`, ambos aceitos. Portanto:

- **Principal:** `.chartXSelection(range:)` no gráfico de tokens por dia — arrasto nativo, com o realce e a acessibilidade que a Apple já entrega.
- **Fallback:** `DragGesture` sobre `chartOverlay`, o padrão **já provado neste repo em 4 pontos** (`DashboardView.swift:680, 871, 1169, 1351`). Só é necessário se o realce nativo não permitir a estética desejada — não por indisponibilidade.
- **Atalhos:** os botões 7d/30d/tudo passam a **escrever na faixa** (`faixa = últimos 7 dias`), em vez de trocar de modo. Um atalho é um valor pré-definido do mesmo controle, e é isso que os mantém coerentes com o arrasto.

### 8.3 O gate: trocar a faixa não pode fazer I/O

É o invariante desta correção, e precisa de prova mecânica — um espião no lugar do scanner, que **falha o teste se for chamado**.

```swift
// Tests/ClaudeBarTests/DashboardRangeTests.swift
/// Espião: qualquer scan durante uma troca de faixa reprova o teste.
private final class ScannerEspiao: @unchecked Sendable {
    private(set) var chamadas = 0
    func scanAnalytics(windowDays: Int) async -> UsageAnalytics {
        chamadas += 1
        return UsageAnalytics(byDayModel: [], byProject: [],
                              heatmap: UsageAnalytics.emptyHeatmap(),
                              topSessions: [], monthToDateCost: 0)
    }
}

struct DashboardRangeTests {
    /// Trocar a faixa 20 vezes não dispara nenhum scan.
    @Test
    func trocarAFaixaNaoFazIO() async {
        let espiao = ScannerEspiao()
        let historia = (0...120).map { entry(day($0), cost: 1.0) }
        var modelo = DashboardRangeModel(historia: historia, scanner: espiao)

        await modelo.carregarUmaVez()
        #expect(espiao.chamadas == 1)              // o único scan permitido

        for dias in 1...20 {
            modelo.faixa = day(dias)...day(0)
            #expect(modelo.dados.dailyCosts.count == dias + 1)
        }

        #expect(espiao.chamadas == 1)              // continua 1 — nenhum I/O na troca
    }

    /// O atalho "7d" é apenas um valor da mesma faixa, não outro modo.
    @Test
    func atalhoEscreveNaFaixa() async {
        let espiao = ScannerEspiao()
        var modelo = DashboardRangeModel(historia: (0...120).map { entry(day($0), cost: 1.0) },
                                         scanner: espiao)
        await modelo.carregarUmaVez()

        modelo.aplicarAtalho(.seteDias)
        #expect(modelo.dados.dailyCosts.count == 7)
        #expect(espiao.chamadas == 1)
    }
}
```

### 8.4 O que fica mais caro, dito abertamente

Carregar a história inteira num scan só troca **muitos scans pequenos por um grande**. Na máquina do Senhor são 2.084 arquivos JSONL — o scan de 90 d já é a operação mais cara do app, e "tudo" será maior. Duas mitigações, e ambas dependem da frente de performance: o **cache incremental persistido** que ela está construindo (task #3 dela) e o pré-filtro por mtime que já existe. **Esta correção deve entrar depois que aquele cache existir**, senão troca-se um problema de medida por um de latência.

---

## 9. Ordem de aplicação, e o que colide

### 9.1 A ordem numa única abertura do arquivo

Pensada para que cada passo compile e os testes do passo anterior continuem verdes.

| Ordem | Correção | Por que aqui |
|:--:|---|---|
| **1** | §1 Denominador (`diasComDado`, `coberturaInicio`) | É a **âncora**: a §5 usa `coberturaInicio` e a §2 usa a média corrigida. Nada mais funciona antes dela. |
| **2** | §5 Coberto vs. sem uso (`DashboardDailyEntry.coberto`) | Consome a âncora do passo 1; é aditivo e não quebra nada. |
| **3** | §3 Cache: remover o dólar, corrigir taxa e formato | **Deletar antes de reorganizar** — remove código que os passos seguintes teriam de carregar à toa. Deleta o teste A2 aqui. |
| **4** | §4 Deleção de `CachePricing` e do método do controller | Consequência mecânica do passo 3; o compilador aponta cada ponto morto. ⚠️ toca `DashboardWindowController.swift`. |
| **5** | §2 Delta prorrateado, já em tokens | Depende da média do passo 1 e da decisão tokens-primeiro do passo 6 — por isso vem colada a ele. |
| **6** | §6 Tokens em primeiro plano (cartões, eixos, ordenações, projeção) | A maior mudança de superfície; melhor com os números já corrigidos embaixo. Inclui `monthToDateTokens`. ⚠️ toca `CostScanner+Analytics.swift`. |
| **7** | §8 Faixa arrastável | Muda a arquitetura de carga; entra depois que a medida está certa, senão depura-se duas coisas ao mesmo tempo. ⚠️ depende do cache incremental da outra frente. |
| **8** | §7 Comparação mensal | **Por último de propósito:** precisa do mês anterior em memória, que só existe depois do passo 7. |

### 9.2 O que colide com as frentes ativas

| Arquivo | Correções | Estado | Ação |
|---|---|---|---|
| `DashboardData.swift` | §1, §2, §3, §5, §6, §7 | aberto pela frente de performance | **Esperar liberação.** É o motivo de o `@po` querer abrir uma vez só. |
| `DashboardWindowController.swift` | §4, §8 | **sendo editado agora** | Coordenar. §8 reescreve o `loadData`/cache que a outra frente está justamente otimizando — **conversar antes**, não depois. |
| `CostScanner+Analytics.swift` | §6 (`monthToDateTokens`) | aberto pela frente de performance | Duas linhas em território alheio. Pedir que **ela mesma** inclua no fold que já está mexendo — é mais barato que um merge. |
| `DashboardView.swift` | §2, §3, §5, §6, §8 | livre hoje | Sem bloqueio, mas depende de `DashboardData` para compilar. |
| `Package.swift` | nenhuma | aberto | **Não é tocado por nenhuma correção.** |

### 9.3 Dependências entre as próprias correções

```
§1 (âncora) ──┬─→ §5 (coberto)
              ├─→ §2 (delta usa a média certa)
              └─→ §7 (cobertura do mês anterior)

§3 (remove o dólar) ──→ §4 (deleção vira possível)

§8 (história inteira) ──→ §7 (mês anterior em memória)

§6 (tokens-primeiro) ──→ §2 (delta passa a ser em tokens)
```

Duas travas duras: **§7 não pode entrar antes de §8**, e **§2 e §6 têm de entrar juntas** (as duas reescrevem `dailyDelta`; separadas, a segunda desfaz a primeira).

---

## 10. Resumo dos gates

| Correção | Prova mecânica |
|---|---|
| §1 | 3 testes; o principal discrimina os divisores 90 / 2 / 10 |
| §2 | 4 testes; o principal **inverte o sinal** do badge (−25% → +100%) |
| §3 | 3 testes + `grep` de remoção retornando vazio |
| §4 | compilação (pontos mortos) + o mesmo `grep` da §3 |
| §5 | 1 teste com dois dias de `costUSD == 0` e significados opostos |
| §6 | testes de ordenação por tokens + revisão dos testes de cor |
| §7 | 3 testes; o principal exige **0%** onde a armadilha dá −22,6% |
| §8 | espião de scanner: 20 trocas de faixa, **1** chamada de I/O |

**O que nenhum destes gates prova:** que a tela **parece** certa. Todos medem números e estrutura. As correções §5, §6 e §8 mudam o que se vê, e precisam de conferência visual — a lacuna no gráfico realmente parece lacuna, os cartões realmente lideram com tokens, o arrasto realmente responde. Isso vai como AC de olho humano na story, pelo mesmo motivo que o gráfico do XLSX precisa ser aberto no Excel.
