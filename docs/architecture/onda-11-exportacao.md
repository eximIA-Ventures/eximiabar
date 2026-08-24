# Onda 11 — Exportação: CSV, planilha formatada e alvo de BI

> **Documento de arquitetura** — insumo direto para o `@sm` criar os story files formais.
> **Autor:** Aria (@architect) · **Data:** 2026-08-24 · **Status:** Proposto, aguarda validação `@po`
> **Baseline verificada:** HEAD `c10df56` (v2.4.0), `Package.swift` com **zero dependências externas**, gate T-R18 verde (comando e saída em §1).
> **Escopo:** design + quebra em stories. **Nenhum arquivo Swift foi alterado por este documento.**

---

## 0. Sumário executivo

O dono pediu três alvos de exportação, textualmente: CSV cru (já existe), *"uma planilha já formatada, bonitinha e pronta para entender"*, e *"exportar para modelos de análise de dados (como Power BI ou coisa do tipo, de forma que ele já venha com gráficos)"*.

As quatro decisões desta onda:

1. **XLSX: escrever OOXML à mão, em Swift puro, sem nenhuma dependência.** Não é uma aposta — está medido (§2.4): o pacote inteiro são 10 partes XML, o `chart1.xml` de um gráfico de linha tem **1.467 bytes**, e o container ZIP sai do próprio sistema (`Compression`, sem `Process`, sem lib de terceiro). O arquivo que gerei assim é aceito por três parsers independentes e é **byte-determinístico**.
2. **A planilha tem 9 abas, 6 gráficos nativos e uma escala de cor no heatmap**, todas ancoradas nos tipos que o app já produz — a nona aba é um `Leia-me` que declara, dentro do arquivo, as ressalvas honestas do número (§3.9). Ela é **tokens-primeiro, custo-segundo**, e **declara a cobertura real da fonte** (§3.1, requisitos do dono de 2026-08-24).
3. **BI: `.pbit` recusado, e o export vira um PACOTE — decidido pelo dono em 2026-08-24, com a recusa na mesa.** Gerar `.pbit`/`.pbix` com visuais a partir do Swift quebra na mão do dono por dois motivos independentes, cada um suficiente (§4.1: Power BI Desktop é Windows-only; o miolo do formato não tem spec pública). Foi essa recusa que permitiu a decisão: se o Power BI não entrega "já vem com gráficos" no Mac, a casa entrega por conta própria. O export passa a ser a pasta `exportacao-eximiabar-YYYY-MM-DD/` com **`painel.html` como peça principal** (arquivo único, offline, gráficos em SVG já desenhados, §4.3), mais a planilha, os CSVs em grão fino, o `.pbids` e o `leia-me.txt`.
4. **O `painel.html` é gerado com casca em *raw string* Swift e UM ponto de injeção de dados em JSON**, com os gráficos emitidos como **SVG pelo Swift** e o JS embutido apenas somando interatividade — o que o torna testável sem navegador (SVG é XML) e byte-determinístico (§4.3).

### As seis descobertas que mudam o desenho

| # | Descoberta | Consequência |
|---|---|---|
| **D1** | **O desenho óbvio da UI é proibido por um teste que já está shipado.** O gate anti-freeze **T-R18** (`Tests/ClaudeBarTests/AccountSwitcherTests.swift:121`) roda um regex sobre `Sources/ClaudeBar/` e exige **zero** ocorrências de `NSPopUpButton|NSMenu\(|Menu\s*[{(]|\.menuStyle|MenuPickerStyle`. Transformar o botão "Exportar CSV" num `Menu { }` do SwiftUI — a solução que qualquer um escreveria primeiro — **quebra a suíte**. | A escolha de formato **não pode ser um menu**. Vai no `accessoryView` do `NSSavePanel` que o fluxo já abre, com `Picker` segmentado (§5). |
| **D2** | **XLSX com gráfico nativo em Swift puro é viável, e o custo está medido.** O `Compression` da Apple com `COMPRESSION_ZLIB` emite **DEFLATE cru (RFC 1951)** — exatamente o método 8 do ZIP (provado por round-trip contra `zlib.decompressobj(-15)`). Escrevi o container ZIP à mão (~120 linhas), montei um `.xlsx` de 10 partes com gráfico de linha, e o resultado passou em Info-ZIP (`unzip -t`), openpyxl e Quick Look da Apple, com **sha256 idêntico entre execuções**. | Nenhuma dependência externa entra no `Package.swift`, nenhum `Process` é lançado, e o arquivo gerado é testável por hash. Decisão (a) de §2, com evidência. |
| **D3** | **O custo que o app calcula NÃO inclui os tokens de cache.** Em `CostScanner+Analytics.swift`: `cost = input × inputPrice + output × outputPrice`. Os tokens de cache-read e cache-write são contabilizados como **volume**, nunca reprecificados (o comentário no código diz isso explicitamente, e é paridade deliberada com o scan do popover). | Quem levar a planilha para o Power BI e somar `custo_usd` vai **sub-contar** a fatura real da Anthropic. Isso tem de estar escrito **dentro do arquivo**, não num README que ninguém abre. Aba `Leia-me`, obrigatória (§3.9). |
| **D4** | **Power BI Desktop é Windows-only, e o dono está no macOS.** A Microsoft confirma que não há versão Mac nem plano de fazer uma; um `.pbit` só abre no Desktop (não no serviço web). E o miolo do `.pbit` (`Report/Layout`, `DataMashup`) **não tem especificação pública** — a própria comunidade recomenda mutar um arquivo-esqueleto existente, nunca construir do zero. | Dois motivos independentes para recusar. Ou seja: mesmo que o formato fosse documentado, o dono não conseguiria abrir o arquivo nesta máquina (§4.1). |
| **D6** | **A média diária divide pela janela pedida, não pelos dias com dado — e a fonte não cobre 90 dias.** `DashboardData.swift:311`: `averageDaily = periodCost / Double(span)`, com `span = period.days`. A cobertura real dos logs desta máquina começa em **2026-07-01** (2.084 arquivos JSONL; há um outlier isolado em 2026-03-18) e vai até hoje — **~55 dias**. Na janela de 90d, portanto, o divisor é 90 para ~55 dias de dado: a média sai **~40% subestimada**, e o `dailyDelta` ("hoje vs. média") herda a distorção **para cima**, fazendo todo dia parecer mais acima da média do que está. Some-se a isso que `dailyCosts` é **zero-preenchido na janela inteira**: os ~35 dias anteriores ao início dos dados entram como `0`, indistinguíveis de "dia sem uso". | A planilha **não pode** apresentar uma janela que a fonte não cobre. Três consequências concretas: bloco de **cobertura declarada** no `Resumo` (§3.1), **duas médias rotuladas** em vez de uma ambígua, e dia-sem-dado escrito como **célula vazia**, não `0` (§3.2). O defeito subjacente é do app, não da exportação — vira story própria (EXB-6.9). |
| **D5** | **O grão fino é descartado hoje, dentro do próprio `Task.detached`.** `DashboardWindowController.swift:212` produz `UsageAnalytics`, deriva `DashboardData` e **joga o `analytics` fora** — só o derivado é cacheado. E o derivado perde o custo no grão `(dia, modelo)`: `DailyModelEntry` carrega apenas `date, modelName, tokens`, sem custo e sem o split de cache. | **Não existe tabela-fato hoje.** Sem tocar nisso, o "alvo de BI" nasce sem o grão que o torna útil. Correção mínima e aditiva: uma propriedade armazenada a mais em `DashboardData` (§3.8). |

---

## 1. Invariantes que nada nesta onda pode violar

Herdados do `EPIC-EXB.md` e da Onda 10, todos testados hoje:

| # | Invariante | Onde é testado | Como esta onda o respeita |
|---|---|---|---|
| **I1** | Zero I/O na main thread. | `AppStateTests` | A geração do workbook é bytes puros e roda em `Task.detached(.utility)` — exatamente o padrão que o `exportCSV()` atual já usa (`DashboardWindowController.swift:272`). |
| **I2** | PTY/subprocess nunca no cooperative thread pool. | `CLITests` | **Nenhum subprocess é lançado.** É o argumento decisivo contra a variante "chamar `/usr/bin/zip`" (§2.2). |
| **I3** | `AppState` publica exatamente uma propriedade observável. | `AppStateTests`, `DisplaySnapshotTests` | A onda não toca em `AppState`. `DashboardData` ganha **uma** propriedade armazenada, e continua atribuída de uma vez só. |
| **I4** | Dropdown é `NSPanel`, nunca `NSMenu`. | `UsagePanelController.swift:7-13` | — |
| **T-R18** | **Zero controles de menu em `Sources/ClaudeBar/`.** | `AccountSwitcherTests.swift:110-121` | **É o invariante que decide a UI desta onda** (D1). Estado verificado agora: |

```
$ grep -rnE "NSPopUpButton|NSMenu\(|(^|[^A-Za-z])Menu\s*[{(]|\.menuStyle|MenuPickerStyle" \
    Sources/ClaudeBar/ --include="*.swift" | grep -v "App/ClaudeBarApp.swift"
(sem saída — gate verde)
```

**Invariante novo desta onda (I6):** *nenhuma célula do workbook contém fórmula.* Uma `<f>` sem `<v>` em cache aparece vazia até o app recalcular, e o conector de Excel do Power BI lê o valor em cache, não a fórmula. Todo valor derivado (totais, percentuais) é **calculado em Swift e escrito como número**. Isso mantém o arquivo verdadeiro em qualquer leitor, inclusive nos que não têm motor de cálculo.

---

## 2. Decisão 1 — como gerar o XLSX

### 2.1 As opções avaliadas

| Opção | Gráficos nativos? | Dependência | Licença | Última atividade | Veredito |
|---|:---:|---|---|---|---|
| **(a) OOXML à mão + ZIP em Swift puro** | **Sim** (escrevemos `xl/charts/chartN.xml`) | **Nenhuma** | — | — | **RECOMENDADA** |
| (b1) [`damuellen/xlsxwriter.swift`](https://github.com/damuellen/xlsxwriter.swift) (wrapper de libxlsxwriter) | Sim (a lib C suporta) | C library via branch `SPM` | `NOASSERTION` na API do GitHub (README diz FreeBSD) | `pushed_at` **2024-06-02** | Rejeitada |
| (b2) [`3973770/SwiftXLSX`](https://github.com/3973770/SwiftXLSX) | **Não** | SSZipArchive (transitiva) | **`null`** na API do GitHub | `pushed_at` **2024-04-10** | Rejeitada |
| (b3) [`CoreOffice/CoreXLSX`](https://github.com/CoreOffice/CoreXLSX) | — (**somente leitura**) | — | Apache-2.0 | `pushed_at` 2024-03-25 | Fora de escopo (não escreve) |
| (c) Híbrida (lib para células, OOXML à mão para gráficos) | Sim | herda a da lib | — | — | Rejeitada (pior dos dois) |

### 2.2 Por que (a), e o que custa

**Critério explícito, na ordem em que decide:**

1. **A dependência é o custo dominante, não o código.** O `Package.swift` de hoje tem **zero** dependências externas — é uma propriedade do projeto, não um acidente. As duas libs candidatas estão **paradas desde meados de 2024** e uma delas (`SwiftXLSX`) não declara licença nenhuma na API do GitHub, o que é um problema real para um app distribuído por Homebrew.
2. **O wrapper de C colide com o invariante I2 pelo caminho vizinho.** `xlsxwriter.swift` usa a branch `SPM` (não uma tag) para compilar a libxlsxwriter junto. Depender de *branch* significa que uma força-push a montante muda o que o app compila, sem bump de versão. O repo tem tags até `1.2.0`, mas a via sem C instalado no sistema é justamente a branch.
3. **O `/usr/bin/zip` funciona, e mesmo assim está descartado.** `zip 3.0` existe nesta máquina e o teste de §2.4 passou com ele. Mas lançar um subprocess só para empacotar bytes cruza o território do **I2** (subprocess exige `Thread` dedicada + `CheckedContinuation` neste projeto), obriga a materializar um diretório temporário de arquivos soltos, e torna o resultado não-determinístico (o header do ZIP carrega mtime). Escrever o ZIP em Swift resolve os três de uma vez.
4. **O custo de manutenção de (a) é limitado e conhecido, porque foi medido** (§2.4). Não é "escrever um Excel"; é escrever **10 documentos XML de estrutura fixa**, dos quais só dois variam com os dados (`sheetN.xml` e as referências de série em `chartN.xml`).

**O que (a) custa, com honestidade:** o motor XLSX é código nosso, e um erro de esquema OOXML aparece como *"o Excel encontrou conteúdo ilegível"* — uma falha binária e opaca. A mitigação é a que já provei funcionar: **três parsers independentes no gate** (§7), sendo um deles o do próprio sistema operacional.

### 2.3 A pergunta crítica: gráficos nativos são realmente viáveis?

Sim, e o argumento não é teórico. Um gráfico de Excel exige exatamente **três partes** além da planilha:

| Parte | Papel | Tamanho medido |
|---|---|---:|
| `xl/charts/chart1.xml` | o gráfico: tipo, título, séries, eixos, legenda | **1.467 B** |
| `xl/drawings/drawing1.xml` | a âncora (em que células o gráfico fica) | 985 B |
| `xl/drawings/_rels/drawing1.xml.rels` | liga o desenho ao gráfico | 293 B |

mais duas linhas de registro: um `<Override>` em `[Content_Types].xml` e um `<drawing r:id="…"/>` no fim de `sheet1.xml`. Um gráfico a mais é **um arquivo a mais** com o mesmo esqueleto e outras referências de série. É repetição parametrizável, não complexidade crescente.

### 2.4 A evidência (o que foi efetivamente executado)

Quatro experimentos, nesta ordem:

**(1) Referência independente.** Gerei com `openpyxl 3.1.5` um workbook com estilo, formato de moeda, Tabela com filtro e dois gráficos, para ler o OOXML que o Excel aceita:

```
$ unzip -l ref.xlsx     # 15 partes; xl/charts/chart1.xml = 1.369 B
```

**(2) O mesmo arquivo, escrito à mão.** Montei as 10 partes com `cat` e empacotei com `/usr/bin/zip`. Dois parsers independentes aceitaram:

```
openpyxl → celulas: dia | custo_usd | 1.5 "$"#,##0.0000
           bold=True fill=FF1F2937 largura A=14.0
qlmanage → produced one thumbnail        # o parser da própria Apple
chart1.xml validado contra o schema-descriptor do openpyxl:
           LineChart | "Custo por dia (USD)" | serie -> Diario!$B$2:$B$8
```

**(3) O ZIP em Swift puro.** Confirmei primeiro a premissa do container:

```
src=1080 deflated=38
descomprimido ok, bytes = 1080
CONFIRMADO: COMPRESSION_ZLIB da Apple emite DEFLATE cru (RFC 1951) = metodo 8 do ZIP
```

Depois escrevi o writer completo (CRC-32 IEEE + local header + central directory + EOCD) e reempacotei as mesmas 10 partes:

```
escrito swiftmade.xlsx: 4254 bytes, 10 partes
$ unzip -t swiftmade.xlsx   → No errors detected in compressed data.
openpyxl  → celulas + estilo + formato de moeda + largura de coluna, todos corretos
            grafico: LineChart | Custo por dia (USD) | serie -> Diario!$B$2:$B$8
qlmanage  → produced one thumbnail (miniatura anexa: cabeçalho escuro, negrito
            branco, $1,5000 formatado, coluna A larga — o estilo chegou)
sha256    → 596d96dc…e738  (idêntico em duas execuções: determinístico)
```

**(4) O elo que NÃO foi medido — declarado, não escondido.** O Quick Look da Apple renderiza a grade de células, **não** desenha o gráfico embutido; e o LibreOffice desta máquina é um symlink órfão (`/opt/homebrew/bin/soffice` aponta para um app que não existe mais), então não houve renderizador headless disponível. Portanto: **o gráfico está provado estruturalmente (schema válido, referências corretas, três parsers aceitam o pacote), mas o desenho visual dele no Excel não foi confirmado por mim.** Esse elo vira o AC visual explícito da story EXB-6.3 — o Microsoft Excel **está instalado** nesta máquina, então a checagem é de trinta segundos e tem de ser feita por quem implementa, não presumida por quem projeta.

### 2.5 Onde o código mora

O corte importa porque `DashboardData` vive no target do app, não no Core:

| Arquivo | Target | Conhece o dashboard? |
|---|---|:---:|
| `Sources/ClaudeBarCore/Export/ZIPWriter.swift` | Core | não |
| `Sources/ClaudeBarCore/Export/XLSXWorkbook.swift` | Core | não |
| `Sources/ClaudeBar/Dashboard/DashboardExport.swift` | App | sim |

O motor genérico fica no Core e é testado em `ClaudeBarCoreTests` **sem abrir janela nenhuma**; só o mapeamento `DashboardData → XLSXWorkbook` fica no target do app. Bônus operacional: o Core `Export/` não encosta em `Core/Cost/`, onde outra frente está mexendo agora (§8.3).

**Superfície do motor** (o mínimo que as 9 abas exigem, nada além):

```
XLSXWorkbook
  sheets: [Sheet]
Sheet
  name, columns: [ColumnWidth], freezeHeader: Bool
  rows: [[Cell]]
  table: Table?                  // xl/tables/tableN.xml — filtro + faixas + nome
  colorScale: ColorScaleRule?    // <conditionalFormatting> no próprio sheet.xml
  charts: [Chart]
Cell   = .text(String) | .number(Double, Style) | .date(Date) | .blank
Style  = .normal | .header | .currency2 | .currency4 | .integer | .percent | .hour
Chart  = .line(title, cats: Range, series: [Range]) | .columnStacked(…) | .bar(…) | .pie(…)
```

Detalhes de formato que o motor fixa de uma vez: datas como **serial do Excel** (dias desde 1899-12-30) com `numFmt yyyy-mm-dd` — nunca texto, senão o eixo do gráfico vira categoria e o BI perde o tipo; strings via `inlineStr` (dispensa a parte `sharedStrings.xml`); `<pane ySplit="1" state="frozen"/>` em toda aba tabular.

---

## 3. Decisão 2 — o que vai na planilha

**Regra de ancoragem:** cada coluna abaixo aponta para um campo que existe hoje. Onde o tipo não tem o dado, a coluna **não existe** — não há campo inventado, e há duas ausências declaradas (§3.3, §3.5).

**Regra de fidelidade:** os números da aba têm de bater com os da tela. Por isso `Modelos` sai de `byModel` (o que está no dashboard) e não de um agregado novo — a tabela-fato (§3.8) é o lugar do grão mais fino. *Exceção declarada em §3.3: a **ordenação** segue o eixo primário da planilha (tokens), não a da tela (custo).*

**Regra de primazia — tokens primeiro, custo depois** *(requisito do dono, 2026-08-24)*. O dono paga **assinatura**, não fatura por token: o USD é **estimativa de valor consumido**, não conta a pagar. Consequências, aplicadas em toda a §3:

- **Token é a grandeza principal:** vem primeiro na ordem das colunas, primeiro na ordem das linhas do `Resumo`, e é o eixo do **gráfico primário** de cada aba. O custo é o gráfico secundário.
- **Ordenação por volume de tokens**, não por custo, em `Modelos` e `Projetos`.
- O custo continua presente e correto em toda aba — muda a hierarquia visual, não o conteúdo.
- Isso **reforça** a ressalva de D3: se o custo não é a conta a pagar, o fato de ele não precificar cache deixa de ser um erro de fatura e passa a ser o que sempre foi — uma estimativa parcial de valor. O `Leia-me` diz as duas coisas.

**Regra de cobertura — nunca apresentar janela que a fonte não cobre** *(requisito do dono, 2026-08-24; ver D6)*. Toda planilha declara primeira data, última data e número de **dias com dado**; toda média divide por dias com dado; dia anterior ao início dos dados é **célula vazia**, nunca `0`.

### 3.1 `Resumo` — o cartão de leitura de 10 segundos

Duas colunas (`Indicador` | `Valor`), sem gráfico, em **três blocos**. Tokens antes de custo em todo o bloco 2 (regra de primazia).

**Bloco 1 — Cobertura dos dados** *(novo, exigido por D6; é a primeira coisa que se lê)*

| Linha | Origem | Formato |
|---|---|---|
| Janela pedida | `period.label` (7d/30d/90d) | texto |
| Primeira data com dado | `min(factRows.date)` | `yyyy-mm-dd` |
| Última data com dado | `max(factRows.date)` | `yyyy-mm-dd` |
| **Dias com dado** | contagem de dias distintos em `factRows` | `#,##0` |
| Dias da janela sem dado nenhum | `period.days − dias com dado` | `#,##0` |
| Aviso | Escrito quando `dias com dado < period.days`: *"A fonte cobre N dos M dias pedidos. Médias abaixo dividem por N."* | texto |

**Bloco 2 — Volume (grandeza principal)**

| Linha | Campo | Formato |
|---|---|---|
| Tokens totais do período | `totalTokens` | `#,##0` |
| Tokens hoje | `todayTokens` | `#,##0` |
| Tokens 7d / 30d | `sevenDayTokens`, `thirtyDayTokens` | `#,##0` |
| **Média por dia com uso** | `totalTokens ÷ dias com dado` — **calculada na exportação** | `#,##0` |
| Média por dia da janela (inclui dias sem dado) | `totalTokens ÷ period.days` | `#,##0` |
| Tokens projetados no mês | `projectedTokens` | `#,##0` |
| Modelo líder por volume | `topModelByTokens.name` / `.tokens` | texto / `#,##0` |
| Taxa de acerto de cache | `cacheHitRate` | `0.0%` |
| Hora de pico | `peakHour` | `00"h"` |
| Hoje vs. média por dia com uso | recalculado sobre a média correta | `+0.0%;-0.0%;0.0%` · **`nil` → "sem uso hoje"**, nunca `0` |

**Bloco 3 — Custo estimado (secundário)**, com o subtítulo literal *"Estimativa de valor consumido. O plano é por assinatura — isto não é fatura."*

| Linha | Campo | Formato |
|---|---|---|
| Custo total do período | `totalCost` | `"$"#,##0.00` |
| Custo hoje | `todayCost` | `"$"#,##0.00` |
| Custo 7d / 30d | `sevenDayCost`, `thirtyDayCost` | `"$"#,##0.00` |
| **Média por dia com uso** | `totalCost ÷ dias com dado` — **calculada na exportação** | `"$"#,##0.00` |
| Média por dia da janela | `averageDailyCost` (o campo do app, rotulado pelo que ele é) | `"$"#,##0.00` |
| Projeção do mês | `monthProjection` | `"$"#,##0.00` |
| Economia estimada por cache | `estimatedCacheSavings` | `"$"#,##0.00` |
| Dia da semana mais caro | `busiestDay.dayOfWeek` → nome + `.cost` | texto + `"$"#,##0.00` |

**As duas médias aparecem lado a lado, cada uma com o rótulo do seu divisor.** Não substituo silenciosamente o `averageDailyCost` do app por outro número: isso faria a planilha discordar da tela sem explicar por quê. Mostro as duas, nomeadas, e trato o divisor errado como o defeito de produto que ele é — story EXB-6.9.

O tratamento de `dailyDelta == nil` é o detalhe que separa uma planilha honesta de uma mentirosa: escrever `0,0%` onde não houve uso afirma "hoje está exatamente na média", que é falso. Mesmo princípio do bloco 1 inteiro.

### 3.2 `Diário` — Tabela `TblDiario` + 2 gráficos

De `dailyCosts: [DashboardDailyEntry]` (eixo já zero-preenchido, ascendente):

| Coluna | Campo | Formato |
|---|---|---|
| `dia` | `.date` | `yyyy-mm-dd` (serial) |
| `tokens_total` | soma dos 4, **calculada em Swift** (I6) | `#,##0` |
| `tokens_entrada` | `.inputTokens` | `#,##0` |
| `tokens_saida` | `.outputTokens` | `#,##0` |
| `cache_leitura` | `.cacheReadTokens` | `#,##0` |
| `cache_escrita` | `.cacheWriteTokens` | `#,##0` |
| `custo_usd` | `.costUSD` | `"$"#,##0.0000` |

Tokens à esquerda, custo à direita (regra de primazia).

> **Armadilha nomeada:** `DashboardDailyEntry.tokens` **não** é o total — é `input + output`, a semântica histórica do popover. `DashboardData.totalTokens` soma os quatro. Usar `.tokens` como "total" produziria uma planilha que discorda de si mesma entre `Resumo` e `Diário`. A coluna acima é a soma dos quatro; o campo `.tokens` não é exportado.

> **Dia sem dado ≠ dia com zero (D6).** `dailyCosts` chega zero-preenchido na janela inteira. Todo dia **anterior à primeira data com dado** é escrito como **célula vazia**, não `0` — e o gráfico já está configurado com `<c:dispBlanksAs val="gap"/>`, então a linha simplesmente **começa** onde os dados começam, em vez de exibir um platô de zeros que se lê como "não usei nada em julho". Dias sem uso **dentro** do intervalo coberto continuam `0`, porque aí o zero é verdade.

**Gráficos, nesta ordem:** `Tokens por dia` (coluna empilhada, as 4 séries — **primário**) e `Custo estimado por dia` (linha, `custo_usd` — secundário).

### 3.3 `Modelos` — Tabela `TblModelos` + 2 gráficos

De `byModel: [DashboardModelEntry]`: `modelo`, `tokens_total` (= entrada + saída, o que o tipo tem), `tokens_entrada`, `tokens_saida`, `custo_usd`.

> **Divergência de ordenação, declarada:** o tipo chega **ordenado por custo desc**. A regra de primazia manda ordenar por **tokens desc**, então a aba reordena. Os *números* continuam idênticos aos da tela (regra de fidelidade); só a ordem das linhas difere. Recomendação para o `@po`: se tokens é mesmo a grandeza principal, o **dashboard deveria seguir** numa onda futura — a divergência é sintoma de que a tela ainda está ordenada pelo eixo antigo.

> **Ausência declarada:** `DashboardModelEntry` **não carrega tokens de cache**. Não há split de cache por modelo nesta aba porque não há no tipo. Quem quiser esse cruzamento usa a aba `Fato` (§3.8), que tem.

**Gráficos, nesta ordem:** `Volume por modelo` (barra horizontal, `tokens_total` — **primário**) e `Participação no volume` (pizza sobre tokens — secundário). O custo por modelo fica na coluna da tabela, sem gráfico próprio.

### 3.4 `Modelos por dia` — matriz larga + 1 gráfico

De `byDayByModel: [DailyModelEntry]` (`date`, `modelName`, `tokens`), pivotado para **datas nas linhas, um modelo por coluna**.

> **Restrição real do OOXML, e o motivo desta aba existir separada:** cada `<c:ser>` de um gráfico exige um **intervalo contíguo** de células. A tabela longa `(dia, modelo, tokens)` não alimenta um gráfico empilhado diretamente — é preciso materializar o bloco largo. Por isso a matriz é escrita de verdade na aba, não derivada por fórmula (I6).

**Gráfico:** `Volume por modelo e dia` (coluna empilhada, uma série por modelo).

### 3.5 `Projetos` — Tabela `TblProjetos` + 1 gráfico

De `byProject: [ProjectUsageEntry]`: `projeto`, `tokens_total`, `custo_usd` — **ordenado por tokens desc** (o tipo chega ordenado por custo; mesma divergência declarada de §3.3).

> **Ausência declarada:** o tipo tem só esses três campos — não há split de token por projeto nem série temporal por projeto. O `projeto` é o **último componente do `cwd`**, e vira `"Unknown"` quando o log não traz `cwd` (`CostScanner.projectName(fromCWD:)`). Dois diretórios de nome igual em caminhos diferentes **colapsam na mesma linha**. Isso vai no `Leia-me`.

**Gráfico:** `Volume por projeto` (barra horizontal sobre `tokens_total`). O custo fica na coluna, sem gráfico próprio.

### 3.6 `Sessões` — Tabela `TblSessoes`, sem gráfico

De `topSessions: [SessionUsageEntry]`: `sessao_id`, `data`, `projeto`, `modelo_dominante`, `tokens_total`, `custo_usd`.

> **A única aba onde a regra de primazia NÃO pode ser cumprida, e por quê.** A seleção das 10 é feita **por custo**, lá em cima: `CostScanner+Analytics` ordena por `costUSD` desc e corta com `.prefix(10)` — as demais sessões já foram **descartadas** antes de chegar aqui. Reordenar por tokens na exportação produziria "as 10 mais caras, ordenadas por volume", que é uma lista sem significado próprio e fácil de ler como "as 10 de maior volume" (que ela não é). Decisão: **manter a ordem por custo e nomear a aba pelo que ela é** — subtítulo literal *"As 10 sessões de maior custo estimado"*. Trocar o critério de seleção para tokens exige mudar o scanner, e isso é escopo de outra onda, não da exportação.

> **Ressalva reforçada:** são **10**, não todas. Uma aba chamada "Sessões" que parece completa e não é seria exatamente o tipo de instrumento preciso que responde a pergunta errada.

### 3.7 `Heatmap` — matriz 7×24 com escala de cor

De `heatmap: [[HeatmapBucket]]`. Linhas = dias da semana (0=domingo, rotulado por nome), colunas = `0h`…`23h`, valores = `tokens`, mais uma coluna `total` calculada.

**Sem gráfico**, por decisão: o Excel não tem tipo de gráfico "heatmap". O equivalente nativo, e melhor, é `<conditionalFormatting>` com `cfRule type="colorScale"` sobre `B2:Y8` — três elementos de XML no próprio `sheet.xml`, renderizado nativamente e sem parte adicional.

### 3.8 `Fato` — Tabela `FatoUso`, o grão para BI

**Esta aba não existe sem a correção de D5.** Colunas: `dia`, `modelo`, `tokens_entrada`, `tokens_saida`, `cache_leitura`, `cache_escrita`, `custo_usd` — exatamente os campos de `ModelCostEntry`, que é o grão `(dia, modelo)` **com custo e com o split de cache completo**.

**Correção mínima proposta:** adicionar a `DashboardData` uma propriedade armazenada

```
/// Grão fino (dia × modelo) preservado para a exportação. Espelha `analytics.byDayModel`.
let factRows: [ModelCostEntry]
```

preenchida em `DashboardData.build(from:)` com `analytics.byDayModel`.

Por que assim, e não cacheando o `UsageAnalytics` ao lado no controller: `DashboardData` já é `Sendable`+`Equatable`, já é **o único valor cacheado** (`cache[period]`), e já atravessa a fronteira `Task.detached → @MainActor` de uma vez só. Uma propriedade a mais preserva I3 e não cria um segundo cache para sair de sincronia com o primeiro. O volume é irrisório: janela de 90 dias × ~5 modelos ≈ 450 linhas.

**É esta aba que o Power BI consome.** Uma Tabela nomeada é o que o conector de Excel lista de forma confiável no Navigator — por isso `xl/tables/` não é enfeite, é o contrato de ingestão.

### 3.9 `Leia-me` — as ressalvas, dentro do arquivo

Aba de texto, e é **obrigatória**, não opcional. Um número que viaja sem sua ressalva vira um fato errado no slide de outra pessoa.

| Item | Texto |
|---|---|
| **Cobertura (D6)** | Primeira data, última data, **nº de dias com dado**, e a frase: *"A janela pedida foi de M dias; a fonte cobre N. Toda média rotulada 'por dia com uso' divide por N."* Dias anteriores ao início dos dados aparecem **em branco**, não como zero. |
| **Plano é assinatura, não fatura** | O USD é **estimativa de valor consumido**, não conta a pagar. Tokens são a grandeza principal desta planilha; o custo é secundário e serve para comparação relativa entre modelos, projetos e dias. |
| Origem | Estimativa local a partir dos logs JSONL do Claude Code — **não** é a fatura da Anthropic. |
| **Cache não é precificado** | `custo = entrada × preço_entrada + saída × preço_saída`. Tokens de cache aparecem como **volume**, nunca precificados. Somar `custo_usd` **sub-conta** a fatura real. (D3) |
| Economia de cache | `estimatedCacheSavings` é estimativa, com cache-read a `0,1 ×` o preço de entrada, do **modelo dominante** da janela (`CachePricing`). |
| Sessões | Apenas as **10 mais caras**. |
| Projetos | Basename do `cwd`; `"Unknown"` quando ausente; nomes iguais em caminhos diferentes colapsam. |
| Dedup | Chunks de streaming deduplicados por `messageId:requestId`, vencendo o de maior offset. |
| Metadados | Gerado em (ISO-8601), versão do app, janela em dias, intervalo coberto, diretórios varridos. |

---

## 4. Decisão 3 — o alvo de BI, e o pacote de exportação

> **DECIDIDO pelo dono em 2026-08-24, com a recusa do `.pbit` (§4.1) na mesa.** A análise foi aceita integralmente e a recusa é o que permitiu a decisão: se o Power BI não entrega "já vem com gráficos" no Mac, a casa entrega por conta própria. **O export deixa de ser "escolher um formato" e passa a ser um PACOTE**, cuja peça principal é um painel HTML autocontido.

```
exportacao-eximiabar-YYYY-MM-DD/
├─ painel.html             ← peça PRINCIPAL: gráficos desenhados, offline, interativo
├─ planilha.xlsx           ← as 9 abas / 6 gráficos da §3
├─ dados/
│  ├─ diario.csv
│  ├─ modelos.csv
│  ├─ projetos.csv
│  └─ fato.csv
├─ conectar-powerbi.pbids  ← mantido: custo quase zero, formato documentado
└─ leia-me.txt             ← cobertura real dos dados + as ressalvas da §3.9
```

Isto **substitui** o "Pacote BI" que a versão anterior deste documento propunha como terceira opção de formato: o pacote passa a ser o produto, não uma alternativa. O CSV cru continua existindo como saída avulsa (§5), para quem quer só a tabela.

### 4.1 A recusa do `.pbit`, e por que ela é o serviço certo aqui

**Não recomendo gerar `.pbit` nem `.pbix` a partir do Swift.** Dois motivos independentes, cada um suficiente sozinho:

1. **O dono não conseguiria abrir o arquivo.** O `.pbit` só abre no **Power BI Desktop**, que a Microsoft confirma ser **Windows-only, sem versão Mac e sem plano de fazer uma** — e o serviço web não abre `.pbit`. Entregar um `.pbit` numa máquina macOS é entregar um arquivo que o dono precisa de Parallels ou de um PC emprestado para ver.
2. **O formato não tem especificação pública.** Não existe documentação Microsoft para o `DataModelSchema`, e o `Report/Layout` é JSON aninhado onde várias propriedades são elas mesmas strings com JSON dentro. O Desktop **valida** `Version`, `[Content_Types].xml`, `SecurityBindings` e `DataMashup` ao abrir, e a prática consolidada da comunidade é **mutar um `.pbit` funcional já existente**, nunca construir do zero. Um gerador nosso quebraria numa atualização do Desktop, em silêncio, na mão de quem usa.

Registro o que **é** documentado, para o veredito não parecer preguiça: o **PBIR** (formato aprimorado de relatório, dentro do PBIP) tem schema JSON público por arquivo. É a via correta se um dia isso virar requisito real — e continua exigindo Desktop no Windows, e ainda está em *preview*. Fica nomeado como caminho futuro, fora desta onda.

### 4.2 As peças do pacote, e o papel de cada uma

| Peça | O quê | Por que |
|---|---|---|
| **`painel.html`** | **arquivo único autocontido, gráficos já desenhados, offline** | É o que cumpre o pedido literal do dono. Não depende de nenhum app instalado, abre em qualquer navegador, e é a peça que o Power BI **não** entrega no Mac. Especificação completa em §4.3. |
| `planilha.xlsx` | as 9 abas / 6 gráficos da §3 | O artefato para mexer nos números, *e* a fonte de ingestão: o conector **Excel Workbook** é nativo do Power BI e as Tabelas nomeadas (`FatoUso`, `TblDiario`, …) aparecem direto no Navigator. Serve igual em Excel, Numbers, Google Sheets e Tableau. |
| `dados/*.csv` | `diario`, `modelos`, `projetos`, `fato` — tidy, UTF-8, ponto decimal, data ISO | Grão fino sem passar por leitor de xlsx; casa com o conector **Folder**. |
| `conectar-powerbi.pbids` | JSON de 9 linhas apontando para `dados/` | Mantido: custo quase zero e **formato oficialmente documentado**, com exemplo publicado para `protocol: "folder"`. Duplo clique leva ao Navigator sem digitar caminho. |
| `leia-me.txt` | cobertura real + ressalvas da §3.9 | Texto puro, legível sem app nenhum. |

```json
{
  "version": "0.1",
  "connections": [
    { "details": { "protocol": "folder",
                   "address": { "path": "<pasta dados/ extraída>" } },
      "mode": "Import" }
  ]
}
```

Mais um `LEIA-ME.md` com as mesmas ressalvas de §3.9 e a instrução de duas linhas para o Power BI.

**O que o pacote honestamente NÃO faz:** ele não abre com visuais prontos **dentro do Power BI**. Os gráficos prontos estão no `painel.html` e na planilha; no Power BI o autor monta os visuais dele sobre um modelo que chega limpo e tipado. É a diferença entre *"aqui está a análise pronta para ler"* (painel + xlsx) e *"aqui está o dado pronto para modelar"* (csv + pbids) — e o dono recebe as duas coisas, cada uma anunciada pelo que é.

---

### 4.3 `painel.html` — a peça principal

#### 4.3.1 Decisão: como o HTML é gerado do lado Swift

**Recomendo: casca estática em *raw string* Swift + UM único ponto de injeção de dados em JSON.** Nem template com dezenas de interpolações, nem string builder concatenando tags.

```
Sources/ClaudeBarCore/Export/PainelTemplate.swift   // a casca: HTML + CSS + JS, constante, sem dados
Sources/ClaudeBar/Dashboard/PainelExport.swift      // monta o JSON e o SVG a partir de DashboardData
```

A casca é uma constante `static let` em **raw string** (`#"""…"""#`), com **um** marcador de substituição. Justificativa, ponto a ponto:

1. **Raw string resolve o conflito de sintaxe.** CSS e JS são cheios de `{`, `}` e `\`. Em string literal normal do Swift, `\` precisa ser escapado e o arquivo vira ilegível. Com `#"""…"""#`, tudo passa intacto e a interpolação só acontece em `\#(…)` — que é **explícita e rara** por construção.
2. **Um ponto de injeção, não cinquenta.** Todo o dado entra por um só lugar:
   `<script id="dados" type="application/json">\#(jsonDosDados)</script>`
   Isso torna a superfície de escape **auditável**: há exatamente uma fronteira entre dado e marcação, e ela é testável (§4.3.5). Um template com interpolação espalhada teria N fronteiras, e a que faltasse escapar seria invisível.
3. **String builder foi rejeitado** porque produziria HTML que ninguém consegue ler nem revisar em diff — e a casca é justamente a parte que muda pouco e precisa ser inspecionada por olho humano.
4. **Arquivo de recurso (`.copy("Resources/painel.html")`) foi rejeitado** por um motivo específico deste repo, não por gosto: a `EXB-3.3` já custou uma release por causa de resource bundle (o app crashava no launch sem ele, e o `Scripts/package_app.sh` existe por causa disso). Um template em `.swift` é compilado dentro do binário e **não tem modo de falha de empacotamento**.

> **Consequência boa e não óbvia:** como a casca é uma constante compilada, um teste pode assertar o **sha256 da casca** e detectar qualquer alteração acidental do HTML — o mesmo truque de determinismo que já usei no XLSX.

#### 4.3.2 Gráficos: SVG gerado, com o JS só por cima

**Nada de biblioteca de gráficos, nem inline.** Chart.js minificado passa de 200 KB, arrasta canvas, exige preservar cabeçalho de licença e não tem caminho de atualização depois de vendorizado. A casa já declarou preferir SVG gerado — e aqui isso é melhor por uma razão técnica, não estética:

**O Swift emite o SVG de cada gráfico já desenhado dentro do HTML; o JS embutido só adiciona interatividade por cima** (tooltip no hover, destacar série, ligar/desligar série). É *progressive enhancement*, e paga três vezes:

- O arquivo **já vem com os gráficos** no sentido literal: os `<path>`/`<rect>` estão nos bytes. Com JS desligado, o painel ainda mostra tudo.
- **Dá para testar sem navegador**: `<svg>` é XML, então `XMLDocument` do Foundation valida a estrutura e conta elementos (§4.3.5). Um gráfico em canvas só existiria depois de executar JS — invisível a qualquer teste nosso.
- Determinismo trivial: o SVG é string gerada por função pura.

> **Nota da implementação (2026-08-24, EXB-6.6): os `<svg>` são emitidos SEM `xmlns`.** A URI canônica do namespace é `http://www.w3.org/2000/svg` e seria a única ocorrência de `http://` do arquivo — reprovando o gate de zero rede do ponto 1 de §4.3.5, que não sabe distinguir namespace de download. Omitir é seguro nos dois consumidores que importam: em HTML5 o próprio parser coloca o SVG inline no namespace certo, e um default namespace não declarado continua sendo XML bem formado (`XMLDocument` e `minidom` parseiam os 6 gráficos). A alternativa — afrouxar o grep para ignorar `w3.org` — foi rejeitada: o gate perderia justamente o `<script src>` que ele existe para pegar.

#### 4.3.3 Conteúdo

**Cabeçalho (topo, não rodapé) — a cobertura declarada, requisito duro:**
primeira data com dado · última data com dado · **nº de dias com dado** · e, quando `dias com dado < janela pedida`, a frase *"A fonte cobre N dos M dias pedidos."* Mesmos números do bloco 1 do `Resumo` (§3.1), pela mesma função.

**Cartões de KPI**, tokens primeiro (regra de primazia): tokens totais · média por dia **com uso** · tokens hoje · modelo líder por volume · taxa de acerto de cache · hora de pico. Custo estimado aparece em um cartão à parte, com o rótulo *"Estimativa de valor consumido — o plano é por assinatura, isto não é fatura."*

> **Decisão do dono (2026-08-24): não existe cartão de "economia estimada por cache" em dólar.** O número precifica um contrafactual — quanto teria custado um cenário que nunca rodou — e a ordem de grandeza dele desacredita os custos reais ao lado. Fica apenas a **taxa** de acerto de cache, que é fato verificável, e ela publica o próprio numerador e denominador (*"X dos Y tokens de entrada vieram do cache"*), para que a divisão possa ser conferida em vez de aceita. O valor saiu **também do bloco de dados JSON**, não só da tela: mantê-lo lá exportaria o mesmo contrafactual para a próxima ferramenta, e o painel contaria uma história diferente da do JSON dentro dele. Espelha a mesma remoção feita no app (frente das correções de medida). Gate de regressão: `semDolarDeEconomiaPorCache` em `PainelHTMLTests.swift`.

**Gráficos, nesta ordem:**

| # | Gráfico | Tipo SVG | Dado |
|---|---|---|---|
| 1 | **Tokens por dia** (primário) | área/coluna empilhada, 4 séries | `diario[]`: entrada, saída, cache leitura, cache escrita |
| 2 | Custo estimado por dia | linha | `diario[].custo_usd` |
| 3 | Volume por modelo | barra horizontal | `modelos[]`, ordenado por tokens desc |
| 4 | Volume por projeto | barra horizontal | `projetos[]`, ordenado por tokens desc |
| 5 | Modelos por dia | coluna empilhada | matriz larga (mesma da §3.4) |
| 6 | Heatmap 7×24 | grade de `<rect>` com escala de cor | `heatmap[7][24]` |

**Nenhum gráfico desenha nada antes da primeira data com dado** — o eixo X **começa** nessa data. Não é o `dispBlanksAs` do Excel: aqui simplesmente não existe ponto antes dela no JSON.

#### 4.3.4 Identidade visual — reusar o que existe, não inventar

Os valores já estão no código, e o painel os copia em vez de criar paleta nova:

| Papel | Fonte no código | Hex |
|---|---|---|
| Destaque | `DesignTokens.swift:40` (terracota da marca) | `#CC7C5E` |
| Séries categóricas (7) | `DashboardView.swift:221-227` | `#598CC7` `#73AD80` `#C7944C` `#9E73B8` `#CC7380` `#66A6B2` `#999966` |
| Acima da média | `DashboardView.swift:427` | `#D16B4C` |
| Abaixo da média | `DashboardView.swift:428` | `#4C9E66` |

Fundo escuro coerente com o app; escala do heatmap = rampa do fundo até `#CC7C5E`. Tipografia: pilha de fontes de sistema (`-apple-system, …`), **nunca** `@font-face` remoto.

#### 4.3.5 Como se testa sem abrir navegador

Cinco gates, todos executáveis em `swift test` ou shell:

1. **Zero rede.** `grep -cE 'https?://|<script src|<link |@import|fetch\(|XMLHttpRequest|integrity=' painel.html` → **0**. É o requisito duro do dono, virado em comando.
2. **Determinismo.** Duas gerações com a mesma entrada → **mesmo sha256** (a data varia só no nome da pasta, nunca no conteúdo; o carimbo de geração entra no `leia-me.txt`, não no painel).
3. **SVG é XML — então valida como XML.** Extrair cada bloco `<svg>…</svg>` e passar por `XMLDocument(data:)`; falha de parse reprova. Assertar **6** elementos `<svg>` e que o gráfico 1 tem 4 séries.
4. **O JSON embutido parseia**, e `min(diario[].dia)` == primeira data com dado (nenhum ponto antes da cobertura real).
5. **Escape do ponto de injeção — o gate que protege contra um defeito invisível.** Os nomes de projeto vêm do **nome de pasta do usuário** (`CostScanner.projectName(fromCWD:)`), ou seja, string arbitrária. Um diretório chamado `</script><img src=x onerror=alert(1)>` fecharia o bloco `<script>` e executaria no navegador do dono. Mitigação obrigatória, no serializador do JSON, antes de injetar:

   | Caractere | Vira (escape unicode JSON) | Por quê |
   |---|---|---|
   | `<` (U+003C) | `\u003c` | quebra `</script>` e `<!--`, as duas formas de sair do bloco |
   | `>` (U+003E) | `\u003e` | defesa em profundidade |
   | `&` (U+0026) | `\u0026` | evita entidade HTML dentro do JSON |
   | U+2028, U+2029 | `\u2028`, `\u2029` | separadores de linha válidos em JSON que **quebram** o parser de JS |

   Escape unicode continua JSON válido, então o `JSON.parse` do navegador lê normalmente. Teste: fixture com projeto chamado `</script><img src=x onerror=alert(1)>` → assertar que a sequência literal `</script>` **não** aparece dentro do bloco de dados **e** que o JSON ainda parseia.

   > **CORREÇÃO (2026-08-24, na implementação da EXB-6.6) — o teste prescrito acima é insuficiente, e insuficiente do jeito pior: ele aprova metade da defesa removida.**
   >
   > Ao implementar, mutei o serializador para provar que o gate tinha dentes: **removi a regra do `<`** e mantive o resto. A asserção que este documento especifica — *"a sequência literal `</script>` não aparece dentro do bloco de dados"* — **continuou passando**, com `<img src=x onerror=alert(1)>` cru dentro do arquivo. Motivo: a regra vizinha do `>` sobrevive à mutação, o payload vira `</script>`, e o literal que a asserção procura deixa de existir por mudança de forma, não por defesa. Ou seja, a asserção estava medindo o efeito colateral da regra do lado.
   >
   > Evidência (mutante compilado a partir de uma cópia da árvore, fora do repo):
   >
   > ```
   > === MUTANTE: PainelEscape.json perde a regra do '<' ===
   >   OK    '</script>' literal ausente do bloco de dados     ← a asserção do doc, aprovando o mutante
   >   FALHA '<img' cru ausente da página inteira              ← quem realmente matou o mutante
   >   OK    o JSON ainda parseia e devolve o nome original
   > ```
   >
   > **O gate passa a exigir as três asserções, não uma:** (a) o literal `</script>` ausente do bloco de dados; (b) **nenhuma marcação crua (`<img`) em lugar nenhum da página**; (c) round-trip — o `JSON.parse` devolve exatamente a string original, provando que o escape não corrompeu o dado. Implementado em `Tests/ClaudeBarCoreTests/PainelHTMLTests.swift`, `nomeHostilNaoEscapaDoBlocoDeDados`.
   >
   > Lição transferível: quando várias regras de escape se sobrepõem, mutar UMA por vez é o único jeito de saber qual asserção mede o quê. Um gate de segurança que aprova a defesa pela metade é pior que nenhum, porque produz confiança.

   > **Segunda fronteira, não prevista aqui.** Esta seção descreve **um** ponto de injeção. Na implementação apareceu um segundo, inevitável: os rótulos de eixo dos gráficos 3 e 4 carregam nome de modelo e de **projeto**, e precisam estar nos bytes do SVG para o painel funcionar com JavaScript desligado (§4.3.2). Renderizá-los por JS a partir do JSON eliminaria essa fronteira e quebraria aquela garantia. A fronteira foi mantida, nomeada (`PainelEscape.marcacao`, escape de `&`, `<`, `>`, `"`, `'`) e testada com a mesma fixture hostil. Um teste conta os marcadores de interpolação em `PainelTemplate.swift` e reprova em três, para que a contagem não cresça em silêncio.

O ponto 5 é o único risco de segurança de toda a onda, e existe justamente porque o dado vem do sistema de arquivos do usuário. Um painel local com XSS não é hipotético — é um arquivo que o dono vai abrir clicando duas vezes.

### 4.3 Deliberadamente fora desta onda

- **PivotTables / PivotCharts no XLSX.** Seria o "modelo de análise" nativo mais forte, e o Excel para Mac suporta. Custa três tipos de parte novos (`pivotCacheDefinition`, `pivotCacheRecords`, `pivotTable`) e tem um modo de falha feio: cache dessincronizado abre a tabela **vazia** até o usuário mandar atualizar. Fica como onda futura, sobre a aba `Fato` que esta onda cria.
- **Power Query embutido no XLSX.** O `DataMashup` é um pacote aninhado sem especificação pública — mesma objeção de §4.1.

---

## 5. Decisão 4 — a UI do export

### 5.1 O que muda, e o que não muda

Hoje: um botão `Exportar CSV` na toolbar (`DashboardView.swift:126`) que abre um `NSSavePanel` (`DashboardWindowController.swift:261`).

Proposto: **o mesmo botão, agora `Exportar…`** (reticências, convenção macOS para "abre diálogo"). A escolha de formato vai para o `accessoryView` do `NSSavePanel` que já é aberto — **zero controle novo na toolbar**, que era a restrição do pedido ("sem poluir o painel").

```
┌─ Salvar ────────────────────────────────────────────┐
│  [ navegador de arquivos padrão do macOS ]          │
│                                                     │
│  Formato:  ( CSV | Planilha | Pacote )      ← Picker segmentado
│  Planilha do Excel com 9 abas e 6 gráficos.   ← legenda que muda
└─────────────────────────────────────────────────────┘
```

### 5.2 Por que accessoryView e não um menu, nem uma sheet própria

- **Menu está proibido** (D1 / T-R18). Um `Picker` com `.pickerStyle(.segmented)` passa no regex do gate; `MenuPickerStyle` não passaria. É o mesmo estilo do seletor de período que já existe.
- **Sheet própria seria um passo a mais** para escolher entre três coisas, e ainda assim terminaria no save panel. `accessoryView` com `NSHostingView` é o padrão AppKit para isto, e o projeto já hospeda SwiftUI em AppKit em quatro lugares (`SettingsWindowController.swift:57`, `UsagePanelController.swift:78`, `DashboardWindowController.swift:108`).

Ao trocar o formato, o controller atualiza `panel.allowedContentTypes` e a extensão de `nameFieldStringValue`:

| Formato | `allowedContentTypes` | Nome sugerido |
|---|---|---|
| CSV | `.commaSeparatedText` | `claude-usage-30d-2026-08-24.csv` |
| Planilha | `UTType("org.openxmlformats.spreadsheetml.sheet")` | `claude-usage-30d-2026-08-24.xlsx` |
| Pacote | pasta (via `NSSavePanel` em modo diretório) | `exportacao-eximiabar-2026-08-24/` |

### 5.3 Escopo: o período NÃO ganha um segundo controle

A toolbar já é dona do período (7d/30d/90d) e o dashboard inteiro obedece a ele. Colocar um seletor de período dentro do save panel criaria **dois controles para a mesma coisa** — a fonte clássica de "exportei 30 dias e veio 7". A exportação segue o que está na tela, e a legenda do accessory diz qual é: *"Período: últimos 30 dias (01/08 – 24/08)"*.

### 5.4 Localização

Chaves novas nas **duas** tabelas (`LocalizationTests` verifica paridade):

| Chave | en | pt-BR |
|---|---|---|
| `dashboard.export` | `Export…` | `Exportar…` |
| `dashboard.export.format` | `Format:` | `Formato:` |
| `dashboard.export.csv` | `CSV` | `CSV` *(chave já existe, valor encurtado)* |
| `dashboard.export.xlsx` | `Spreadsheet` | `Planilha` |
| `dashboard.export.pack` | `Package` | `Pacote` |
| `dashboard.export.hint.csv` | `Raw daily data, one row per day.` | `Dados diários crus, uma linha por dia.` |
| `dashboard.export.hint.xlsx` | `Excel workbook: 9 sheets, 6 charts.` | `Planilha do Excel: 9 abas, 6 gráficos.` |
| `dashboard.export.hint.pack` | `Interactive panel + workbook + tidy CSVs + Power BI connection file.` | `Painel interativo + planilha + CSVs em grão fino + arquivo de conexão do Power BI.` |

### 5.5 Comportamento de falha

O `exportCSV()` atual engole o erro (`try?` num `Task.detached`, com o painel já fechado). Para um CSV de 90 linhas isso passa; para um pacote de vários arquivos, um erro silencioso vira "cadê meu arquivo?". A escrita passa a reportar: sucesso → revelar no Finder (`NSWorkspace.activateFileViewerSelecting`); falha → `NSAlert` na janela do dashboard, com a mensagem do erro.

---

## 6. Stories propostas (EXB-6.x)

Complexidade na escala do épico (S/M/L). A numeração mudou com a decisão do pacote (§4): entrou a **EXB-6.6** (painel HTML), a antiga "Pacote BI" virou **EXB-6.7** (montagem do pacote), a UI foi para **EXB-6.8** e a release para **EXB-6.10**.

### EXB-6.1 — ZIP determinístico em Swift puro
**Executor:** @dev · **Complexidade:** M · **Depende de:** — · **Toca:** `Core/Export/` (novo)
Motor de §10.1, adaptado ao estilo do projeto.

**AC verificáveis:**
1. `swift test --filter ZIPWriterTests` verde.
2. `/usr/bin/unzip -t` sobre o arquivo gerado → `No errors detected` (exit 0).
3. Duas chamadas com a mesma entrada → **mesmo sha256**.
4. Round-trip: payload descomprimido byte-idêntico ao original.
5. Entrada vazia e de 1 byte não quebram (fallback STORED, §10.1 nota 1).
6. `grep -n "Process(\|NSTask" Sources/ClaudeBarCore/Export/ZIPWriter.swift` → vazio.

### EXB-6.2 — Motor XLSX (células, estilos, tabelas, congelamento)
**Executor:** @dev · **Complexidade:** L · **Depende de:** EXB-6.1 · **Toca:** `Core/Export/` (novo)

**AC verificáveis:**
1. `unzip -l` lista `[Content_Types].xml`, `_rels/.rels`, `xl/workbook.xml`, `xl/styles.xml`, `xl/worksheets/sheet1.xml`, `xl/tables/table1.xml`.
2. Datas escritas como serial: a célula lida de volta é data, não string.
3. `"$"#,##0.0000`, `#,##0` e `0.0%` presentes em `xl/styles.xml`.
4. **I6:** `unzip -p arquivo.xlsx xl/worksheets/sheet1.xml | grep -c "<f>"` → `0`.
5. `grep 'state="frozen"'` no sheet XML.
6. As 3 primeiras abas abrem no Excel sem diálogo de reparo.

### EXB-6.3 — Gráficos nativos no XLSX
**Executor:** @dev · **Complexidade:** M · **Depende de:** EXB-6.2 · **Toca:** `Core/Export/` (novo)
Esqueleto de §10.2/§10.3 parametrizado para linha, coluna empilhada, barra e pizza.

**AC verificáveis:**
1. `unzip -l saida.xlsx | grep -c "xl/charts/chart"` → **6**.
2. `unzip -l saida.xlsx | grep "xl/drawings/"` lista drawing + rels de cada aba com gráfico.
3. **AC visual bloqueante (o elo que §2.4 não mediu):** abrir no **Microsoft Excel** (instalado) e confirmar os 6 gráficos desenhados, com título e séries corretos. Captura colada na story. **Sem isto a story não fecha** — nenhum teste desta onda desenha um pixel.
4. Nenhum diálogo *"conteúdo ilegível"*.

### EXB-6.4 — Grão fino: `factRows` + aba `Fato` + `Leia-me`
**Executor:** @dev · **Complexidade:** S · **Depende de:** EXB-6.2 · **Toca:** `Dashboard/DashboardData.swift` ⚠️
Corrige D5. **Única story que encosta em `DashboardData.build` — ver a Ordem de execução ao fim da §6.**

**AC verificáveis:**
1. `DashboardData.factRows.count == analytics.byDayModel.count`.
2. `factRows.map(\.cost).reduce(0,+)` bate com `totalCost` dentro de `1e-9`.
3. Aba `Fato` com uma linha por `factRow` + cabeçalho.
4. `unzip -p` + `grep` acha a frase literal sobre cache não precificado.
5. `DashboardDataTests` continua verde (a propriedade é aditiva).

### EXB-6.5 — As 9 abas completas
**Executor:** @dev · **Complexidade:** L · **Depende de:** EXB-6.3, EXB-6.4 · **Toca:** `Dashboard/` (arquivo novo)

**AC verificáveis:**
1. `unzip -p saida.xlsx xl/workbook.xml | grep -o 'name="[^"]*"'` lista exatamente as 9 abas.
2. Aba `Diário` com `period.days` linhas; as anteriores à primeira data com dado têm valor **vazio**, não `0` (D6) — fixture de cobertura parcial.
3. **Cobertura:** bloco 1 do `Resumo` traz primeira data, última data e dias com dado; com 90d sobre a fonte real (~55 dias) o aviso aparece.
4. **Primazia:** em `Diário` a ordem é `dia, tokens_total, …, custo_usd`; `Modelos` e `Projetos` ordenados por tokens desc.
5. **Duas médias** rotuladas distintamente, e **diferindo** na fixture de cobertura parcial.
6. `dailyDelta == nil` → "sem uso hoje", nunca `0`.
7. Heatmap: `grep -c 'type="colorScale"'` → 1; matriz 7×24.
8. Soma de `custo_usd` do `Diário` == `Resumo!custo total`.

### EXB-6.6 — `painel.html` (NOVA — a peça principal)
**Executor:** @dev · **Complexidade:** L · **Depende de:** EXB-6.4 (precisa de `factRows`) · **Toca:** `Core/Export/` + `Dashboard/` (arquivos novos)
Especificação em §4.3: casca em raw string, um ponto de injeção JSON, SVG gerado em Swift, JS só para interatividade.

**AC verificáveis (os 5 gates de §4.3.5):**
1. **Zero rede:** `grep -cE 'https?://|<script src|<link |@import|fetch\(|XMLHttpRequest|integrity=' painel.html` → **0**.
2. **Determinismo:** duas gerações com a mesma entrada → **mesmo sha256**.
3. **SVG valida como XML:** cada bloco `<svg>` passa por `XMLDocument(data:)`; assertar **6** elementos `<svg>` e 4 séries no gráfico 1.
4. **Cobertura:** o JSON embutido parseia e `min(diario[].dia)` == primeira data com dado; a cobertura aparece no **topo** do HTML.
5. **Escape (segurança):** fixture com projeto chamado `</script><img src=x onerror=alert(1)>` → a sequência literal `</script>` **não** aparece no bloco de dados **e** o JSON ainda parseia.
6. Abrir no Safari e no Chrome **com a rede desligada**: os 6 gráficos aparecem e o tooltip responde. Captura na story.

### EXB-6.7 — Montagem do pacote
**Executor:** @dev · **Complexidade:** M · **Depende de:** EXB-6.5, EXB-6.6 · **Toca:** `Dashboard/` (arquivo novo)
A pasta `exportacao-eximiabar-YYYY-MM-DD/` de §4 com as 5 peças.

**AC verificáveis:**
1. A pasta gerada contém exatamente: `painel.html`, `planilha.xlsx`, `dados/{diario,modelos,projetos,fato}.csv`, `conectar-powerbi.pbids`, `leia-me.txt`.
2. `python3 -m json.tool` sobre o `.pbids` sai sem erro e o arquivo contém `"protocol": "folder"`.
3. `fato.csv` tem `factRows.count + 1` linhas; vírgula, decimal ponto, data ISO, UTF-8.
4. `leia-me.txt` repete a cobertura e a ressalva de cache.
5. Os números do `painel.html` e da `planilha.xlsx` **conferem entre si** (teste comparando o JSON embutido com as células da aba `Diário`) — é o gate que impede as duas peças de divergirem.
6. **Não verificável nesta máquina, declarado:** abrir o `.pbids` no Power BI Desktop (Windows-only, D4). Pendência de terceiro, **não** AC fechado.

### EXB-6.8 — UI do export
**Executor:** @dev · **Complexidade:** M · **Depende de:** EXB-6.7 · **Toca:** `Dashboard/DashboardWindowController.swift` ⚠️ + `DashboardView.swift` ⚠️
Botão `Exportar…`, `accessoryView` com picker segmentado (CSV | Planilha | Pacote), erro de §5.5.

**AC verificáveis:**
1. **Gate T-R18**, comando literal com saída colada: `grep -rnE "NSPopUpButton|NSMenu\(|(^|[^A-Za-z])Menu\s*[{(]|\.menuStyle|MenuPickerStyle" Sources/ClaudeBar/ --include="*.swift" | grep -v "App/ClaudeBarApp.swift"` → **vazio**.
2. `swift test --filter LocalizationTests` verde com as chaves novas nas duas tabelas.
3. Trocar o formato muda a extensão sugerida (3 capturas).
4. Falha de escrita mostra `NSAlert` (testável com caminho não-gravável).
5. Sucesso revela o artefato no Finder.

### EXB-6.9 — A média diária divide pela janela, não pelos dias com dado
**Executor:** @dev · **Complexidade:** S · **Depende de:** — · **Toca:** `Dashboard/DashboardData.swift` ⚠️
**Não é story de exportação — é correção de defeito do produto,** exposta por D6. `DashboardData.swift:311`: `averageDaily = periodCost / Double(span)`. Na janela de 90d sobre ~55 dias de dado, a média sai ~40% subestimada e o `dailyDelta` herda a distorção para cima.

**Primeiro movimento obrigatório** (`sdc-mandatory.md`, bug fix): escrever o **teste vermelho** — fixture com janela de 90d e 10 dias de dado — **antes** de tocar no cálculo.

**AC verificáveis:**
1. Teste vermelho commitado e falhando antes da correção; verde depois.
2. `averageDailyCost` passa a dividir pelos dias com uso, **ou** é renomeado/duplicado para deixar o divisor explícito — decisão do `@po`, não do implementador.
3. `DashboardInsightsTests` e `DashboardDataTests` verdes (ou expectativas atualizadas com justificativa).
4. `dailyDelta` recalculado sobre a média corrigida.
5. Tela e planilha concordam no número rotulado "média por dia com uso".

### EXB-6.10 — Release v2.5.0
**Executor:** @devops · **Complexidade:** S · **Depende de:** todas
Padrão da EXB-5.6 (bump em `Sources/ClaudeBar/Info.plist`, `make build`, `ditto`, tag, cask). Gates herdados: T-R18 verde, `swift test` verde, e as capturas visuais das EXB-6.3, 6.6 e 6.8.

---

### Ordem de execução, considerando a frente de performance

A frente de performance tem **`Package.swift`, `CostScanner.swift`, `CostScanner+Analytics.swift`, `DashboardWindowController.swift`** abertos, mais `AnalyticsBench/` e `AnalyticsCache.swift` novos. Duas constatações que definem a ordem:

**1. Esta onda NÃO precisa tocar `Package.swift`.** Verificado: o target `ClaudeBarCore` declara `path: "Sources/ClaudeBarCore"` e já tem 10 subpastas (`Accounts`, `CLI`, `Cost`, `Model`, …) sem nenhuma declaração por subpasta. Um `Export/` novo é compilado automaticamente. **A colisão no arquivo mais disputado do repo simplesmente não existe.**

**2. Cinco das dez stories não encostam em nenhum arquivo aberto pela outra frente.**

| Onda | Stories | Arquivos | Pode começar |
|---|---|---|---|
| **A — livre** | 6.1, 6.2, 6.3 | só `Core/Export/` (novo) | **agora**, em paralelo total |
| **B — livre** | 6.6 (painel), 6.7 (pacote) | `Core/Export/` + arquivos novos em `Dashboard/` | assim que 6.4 fechar |
| **C — espera** | 6.4, 6.9 | `Dashboard/DashboardData.swift` | depois que a frente de performance estabilizar `DashboardData.build(from:)` |
| **D — espera** | 6.8 | `DashboardWindowController.swift`, `DashboardView.swift` | **por último** entre as de código: é o arquivo que a outra frente está editando agora |
| **E — fim** | 6.10 | release | depois de todas |

**Ordem recomendada:** `6.1 → 6.2 → 6.3` (livres, começam já) · em paralelo, **6.9 primeiro que 6.4**, porque as duas mexem em `DashboardData.swift` e a 6.9 é um bug fix pequeno com teste vermelho — abrir o arquivo uma vez para corrigir e outra para estender é melhor que o inverso · depois `6.4 → 6.5 → 6.6 → 6.7` · então `6.8` · e `6.10` fecha.

**Sinal de coordenação:** antes de abrir a 6.4 ou a 6.9, confirmar com a frente de performance que `DashboardData.build(from:)` não vai mudar de assinatura — é a única dependência real entre as duas frentes.

## 7. Gates de qualidade da onda

O motor XLSX falha de modo **binário e opaco** ("conteúdo ilegível"), então o gate não pode ser só o `swift test`. Três verificadores independentes, nenhum deles escrito por quem escreve o gerador:

| Verificador | O que prova | Como roda |
|---|---|---|
| `/usr/bin/unzip -t` | o container é um ZIP válido, CRC por entrada confere | shell, no teste |
| `python3` + `openpyxl` | células, estilos, formatos e **o esquema do gráfico** conferem | script de gate, fora do target Swift |
| `qlmanage -t` | o **parser da própria Apple** aceita o arquivo | shell |
| **Microsoft Excel, a olho** | os gráficos **desenham** | humano, EXB-6.3 AC3 |
| `XMLDocument` (Foundation) | cada `<svg>` do painel é XML estruturalmente válido | `swift test`, EXB-6.6 AC3 |
| `grep` de rede + fixture hostil | o painel não faz **nenhuma** requisição externa, e o escape do bloco de dados aguenta nome de projeto malicioso | `swift test` + shell, EXB-6.6 AC1/AC5 |
| **Safari e Chrome offline, a olho** | os gráficos do painel **desenham** e o tooltip responde | humano, EXB-6.6 AC6 |

A quarta linha é a que importa mais e é a única que uma pessoa precisa executar. As três primeiras podem estar verdes com o gráfico invisível — foi exatamente a situação em que a §2.4 terminou, e ela está declarada lá em vez de arredondada para "funciona".

---

## 8. Riscos

| # | Risco | Mitigação |
|---|---|---|
| **R1** | Esquema OOXML errado → Excel recusa o arquivo inteiro | Os 4 verificadores de §7; e o pacote de referência do openpyxl (`/tmp/xlsx-spike/ref.xlsx`) como gabarito de comparação parte a parte |
| **R2** | Gráfico com referência de série errada → aparece vazio, **sem erro** | AC visual obrigatório (EXB-6.3 AC3). É o modo de falha que passa em todo teste automatizado desta onda |
| **R3** | Alguém somar `custo_usd` no BI e achar que é a fatura | Aba `Leia-me` **dentro** do arquivo, mais o `LEIA-ME.md` no pacote (D3) |
| **R4** | Nome de aba inválido no Excel (`[ ] : * ? / \`, >31 chars) | Sanitização no motor + teste com nome hostil |
| **R5** | Janela de 90 dias com muitos modelos → matriz larga com colunas demais | Os modelos são normalizados (`Pricing.normalize`), tipicamente 3-6. Cortar em 12 colunas com uma coluna `outros` se passar |

### 8.3 Sequenciamento com a frente de performance

Há **outra frente ativa neste mesmo repo agora**, trabalhando em `CostScanner+Analytics` (cache incremental, "um scan serve todas as janelas", paralelismo por `TaskGroup`). Esta onda depende da **forma** de `UsageAnalytics` e `ModelCostEntry`, não da implementação do scan — e o código novo mora em `Core/Export/` e `Dashboard/`, sem tocar em `Core/Cost/`. Ainda assim: **EXB-6.4 é a única story que encosta em `DashboardData.build`**, então ela deve entrar depois que a frente de performance estabilizar a assinatura de `build(from:)`. As demais são independentes e podem começar já.

---

## 9. Fontes

- [`damuellen/xlsxwriter.swift`](https://github.com/damuellen/xlsxwriter.swift) — wrapper Swift de libxlsxwriter; licença `NOASSERTION`, `pushed_at` 2024-06-02 (API do GitHub)
- [`3973770/SwiftXLSX`](https://github.com/3973770/SwiftXLSX) — escritor puro Swift, **sem gráficos**; licença `null`, `pushed_at` 2024-04-10 (API do GitHub)
- [`CoreOffice/CoreXLSX`](https://github.com/CoreOffice/CoreXLSX) — parser **somente leitura**, Apache-2.0
- [Create and use report templates in Power BI Desktop](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-templates) — `.pbit` requer Power BI Desktop; contém definições, não dados
- [Data sources in Power BI Desktop](https://learn.microsoft.com/en-us/power-bi/connect-data/desktop-data-sources) — **especificação e exemplos JSON do `.pbids`**, incluindo `protocol: "folder"` e `protocol: "file"`; e o conector **Excel Workbook** na categoria File
- [Power BI Desktop no Mac — Microsoft Q&A](https://learn.microsoft.com/en-ca/answers/questions/5552084/power-bi-desktop-possible-for-mac-book-pro) e [Parallels](https://www.parallels.com/apps/power-bi/) — confirmação de que é Windows-only
- [Power BI enhanced report format (PBIR)](https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-report) — formato com schema JSON público, em *preview*; caminho futuro registrado em §4.1
- [documentation for DataModelSchema from pbit — Fabric Community](https://community.fabric.microsoft.com/t5/Desktop/documentation-for-DataModelSchema-from-pbit/td-p/1887862) — ausência de documentação oficial do miolo do `.pbit`
- [XlsxWriter — Working with Charts](https://xlsxwriter.readthedocs.io/working_with_charts.html) — referência do modelo de gráficos OOXML
- Evidência gerada nesta análise: `/tmp/xlsx-spike/` (`ref.xlsx` openpyxl, `hand.xlsx` artesanal, `swiftmade.xlsx` ZIP em Swift, `zipw.swift`, `defl.swift`)

---

## 10. Anexo — código já provado nos experimentos

> **Para o @dev: nada aqui precisa ser redescoberto.** Tudo nesta seção foi executado e validado em 2026-08-24 (evidência em §2.4). Os trechos são o que rodou, não pseudocódigo. Reproduzir o experimento: os arquivos vivos estão em `/tmp/xlsx-spike/` — mas o anexo é a fonte, porque `/tmp` é volátil.

### 10.1 O motor de ZIP em Swift puro

CRC-32 (IEEE), DEFLATE via `Compression`, local file header, central directory e EOCD. Rodou, produziu `swiftmade.xlsx` (4.254 B), passou em `unzip -t` e deu **sha256 idêntico em duas execuções**. Vai para `Sources/ClaudeBarCore/Export/ZIPWriter.swift`, adaptado ao estilo do projeto (nomes em inglês, doc-comments, `struct` em vez de globais).

```swift
import Foundation
import Compression

// ---- CRC-32 (IEEE), tabela gerada em runtime ----
let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
    return c
}
func crc32(_ d: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}
func deflate(_ src: Data) -> Data? {
    guard !src.isEmpty else { return nil }
    var dst = [UInt8](repeating: 0, count: src.count + 512)
    let n = src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
        compression_encode_buffer(&dst, dst.count,
            s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
    }
    guard n > 0, n < src.count else { return nil }   // 0 = falhou; maior = usa STORED
    return Data(dst[0..<n])
}
extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from:0,to:32,by:8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}

struct Entry { let path: String; let payload: Data }

func makeZip(_ entries: [Entry]) -> Data {
    var out = Data(); var central = Data(); var count: UInt16 = 0
    for e in entries {
        let name = Data(e.path.utf8)
        let crc = crc32(e.payload)
        let comp = deflate(e.payload)
        let method: UInt16 = comp == nil ? 0 : 8
        let body = comp ?? e.payload
        let offset = UInt32(out.count)
        // local file header
        out.le32(0x0403_4B50); out.le16(20); out.le16(0); out.le16(method)
        out.le16(0); out.le16(0)                                  // mtime/mdate fixos = bytes determinísticos
        out.le32(crc); out.le32(UInt32(body.count)); out.le32(UInt32(e.payload.count))
        out.le16(UInt16(name.count)); out.le16(0)
        out.append(name); out.append(body)
        // central directory header
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0); central.le16(method)
        central.le16(0); central.le16(0)
        central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(e.payload.count))
        central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
        central.append(name)
        count += 1
    }
    let cdOffset = UInt32(out.count)
    out.append(central)
    out.le32(0x0605_4B50); out.le16(0); out.le16(0); out.le16(count); out.le16(count)
    out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
    return out
}
```

**Três detalhes que custam tempo se descobertos por tentativa:**

1. `compression_encode_buffer` devolve **0** quando não consegue comprimir no buffer dado — daí o fallback para STORED (`method 0`). Sem esse fallback, entradas pequenas ou incompressíveis produzem um ZIP corrompido em silêncio.
2. Os campos de **data/hora ficam zerados de propósito**. É o que torna a saída byte-determinística e o sha256 utilizável como teste. Um mtime real quebraria isso.
3. O CRC-32 é calculado sobre o payload **descomprimido**, nunca sobre o comprimido.

### 10.2 O `chart1.xml` mínimo, validado

Este é o gráfico de linha que passou no schema-descriptor do openpyxl (`LineChart | "Custo por dia (USD)" | serie -> Diario!$B$2:$B$8`). É o esqueleto a parametrizar: mudam o título, as referências `<c:f>` e o elemento do tipo (`<c:lineChart>` → `<c:barChart>` / `<c:pieChart>`).

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>Custo por dia (USD)</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title><c:autoTitleDeleted val="0"/><c:plotArea><c:layout/><c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/><c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:strRef><c:f>Diario!$B$1</c:f></c:strRef></c:tx><c:marker><c:symbol val="none"/></c:marker><c:cat><c:strRef><c:f>Diario!$A$2:$A$8</c:f></c:strRef></c:cat><c:val><c:numRef><c:f>Diario!$B$2:$B$8</c:f></c:numRef></c:val><c:smooth val="0"/></c:ser><c:marker val="1"/><c:axId val="111111111"/><c:axId val="222222222"/></c:lineChart><c:catAx><c:axId val="111111111"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:crossAx val="222222222"/></c:catAx><c:valAx><c:axId val="222222222"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="&quot;$&quot;#,##0.00" sourceLinked="0"/><c:crossAx val="111111111"/></c:valAx></c:plotArea><c:legend><c:legendPos val="r"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart></c:chartSpace>
```

**Notas do que foi tentado e importa:** os dois `<c:axId>` precisam ser o **mesmo par** dentro de `<c:lineChart>`, `<c:catAx>` e `<c:valAx>` (com `crossAx` cruzado), senão o gráfico não renderiza; `<c:delete val="0"/>` é obrigatório em cada eixo, senão o Excel some com ele; e `<c:dispBlanksAs val="gap"/>` é exatamente o que faz o dia sem dado virar interrupção da linha em vez de queda a zero (§3.2, D6).

### 10.3 A âncora do gráfico na planilha

O gráfico não é referenciado pela planilha diretamente: `sheet1.xml` aponta para um **drawing**, e o drawing aponta para o chart. Duas partes de tamanho fixo:

`xl/drawings/drawing1.xml` — a âncora de duas células (`<xdr:from>`/`<xdr:to>` definem onde o gráfico fica):

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><xdr:twoCellAnchor><xdr:from><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>11</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>16</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame><xdr:nvGraphicFramePr><xdr:cNvPr id="2" name="Chart 1"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="rId1"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>
```

`xl/worksheets/_rels/sheet1.xml.rels`:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>
```

Mais o fecho de `sheet1.xml` com `<drawing r:id="rId1"/>` **depois** de `</sheetData>` (a ordem dos elementos no schema é obrigatória), e os dois `<Override>` em `[Content_Types].xml`:

```xml
<Override PartName="/xl/drawings/drawing1.xml"
          ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
<Override PartName="/xl/charts/chart1.xml"
          ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>
```

### 10.4 A premissa do container, confirmada

`COMPRESSION_ZLIB` da Apple emite **DEFLATE cru (RFC 1951)** — o método 8 do ZIP — e **não** o formato zlib com cabeçalho. Confirmado por round-trip: 1.080 B comprimidos para 38 B, descomprimidos de volta a 1.080 B por `zlib.decompressobj(-15)` do Python (o `-15` significa *raw*, sem cabeçalho). É esta a premissa que dispensa `Process`, `/usr/bin/zip` e qualquer dependência de ZIP.

Comando de verificação, para repetir a prova a qualquer momento:

```bash
python3 -c "import zlib; raw=open('raw.bin','rb').read(); \
  print(len(zlib.decompressobj(-15).decompress(raw)))"
```

### 10.5 As 10 partes mínimas de um `.xlsx` com um gráfico

A lista exata que foi empacotada e aceita. Um segundo gráfico acrescenta `chart2.xml` e uma linha no `.rels` do drawing daquela aba:

```
[Content_Types].xml
_rels/.rels
xl/workbook.xml
xl/_rels/workbook.xml.rels
xl/styles.xml
xl/worksheets/sheet1.xml
xl/worksheets/_rels/sheet1.xml.rels
xl/drawings/drawing1.xml
xl/drawings/_rels/drawing1.xml.rels
xl/charts/chart1.xml
```

Não são necessários: `sharedStrings.xml` (usamos `t="inlineStr"`), `docProps/*` (opcional), `theme1.xml` (opcional). Cortar essas três foi deliberado — são 10 KB de XML que não fazem falta e que o openpyxl só inclui por completude.

---

## 11. Achados de implementação — Grupo A (EXB-6.1, 6.2, 6.3) e EXB-6.7

> **Autor:** Dex (@dev) · **Data:** 2026-08-24 · **Status:** medido e aprovado pelo lead
> Seção anexada pela implementação. Não altera nada acima; onde corrige o projeto, diz explicitamente o quê.

### 11.1 Correção à §10.1 nota 1 — o modo de falha do fallback STORED não reproduz

A nota 1 afirma que sem o fallback STORED "entradas pequenas ou incompressíveis produzem um ZIP corrompido em silêncio". **Medido, não reproduz com o buffer que a própria §10.1 prescreve.**

`compression_encode_buffer` devolve `0` **apenas quando o destino não cabe**. Com a folga `src.count + 512`:

| entrada | retorno |
|---|---|
| 1 byte, folga 512 | **3** |
| 1 byte, folga 0 | 0 |
| 64 bytes aleatórios, folga 512 | **69** |
| 64 bytes aleatórios, folga 0 | 0 |

Com o mutante (guard removido), o ZIP saiu **válido e maior**, aprovado por `unzip -t` e por round-trip byte a byte do Info-ZIP. Quem matou o mutante foi o teste unitário direto do guard, não o verificador de container.

Consequência: o guard tem duas metades com papéis distintos, e vale documentá-las separadas.

- `written > 0` — **corretude**. É o contrato da API; 0 é indistinguível de "comprimiu para nada".
- `written < source.count` — **tamanho**. É a metade que realmente dispara na prática.

Ambas permanecem no código. O que muda é a história contada sobre elas.

### 11.2 O AC3 da EXB-6.2 é inexequível como escrito

O AC3 pede `"$"#,##0.0000`, `#,##0` e `0.0%` "presentes em `xl/styles.xml`". Um grep desse literal **reprova todo escritor conforme, o openpyxl inclusive**: valor de atributo XML precisa escapar a aspa, e o disco carrega `formatCode="&quot;$&quot;#,##0.0000"`. Cumprir o grep exigiria emitir XML fora do padrão.

**Régua adotada:** asserção sobre o valor **depois de decodificar** (`XMLDocument` + XPath sobre `//numFmt/@formatCode`). A saída não foi contorcida para satisfazer o grep.

Generalização para os próximos ACs desta casa: **AC que grepa literal dentro de XML/HTML precisa ser verificado contra a serialização antes de virar critério.** O grep mede a serialização, não o dado.

### 11.3 Segundo risco de segurança — injeção de fórmula em CSV

A §4.3.5 chama o escape do bloco de dados do painel de *"o único risco de segurança de toda a onda"*. **Há um segundo, na mesma fonte de dado, na peça vizinha do mesmo pacote.**

Excel avalia como fórmula qualquer célula cujo texto comece por `=`, `+`, `-` ou `@`. O nome de projeto vem de `CostScanner.projectName(fromCWD:)`, ou seja, de um nome de diretório em disco. Uma pasta chamada `=cmd|'/c calc'!A1` transforma "abrir o export" em "executar o nome da pasta".

**Mitigação:** apóstrofo à frente, aplicado **exclusivamente a campo de texto**. `-` está no conjunto perigoso e também é sinal de negativo; aplicar a campo numérico corromperia silenciosamente todo valor negativo do arquivo — uma defesa que estraga o dado é pior que a ausência dela. Números são formatados pelo próprio escritor e nunca carregam payload, então a distinção por tipo resolve.

**Lição transversal:** quando um pacote tem várias peças alimentadas pela MESMA fonte não-confiável, **cada leitor executa uma linguagem diferente**. Navegador executa `<script>`, Excel executa `=`, e ainda há Markdown→HTML, SVG→JS, YAML→tag de deserialização. Proteger uma peça não protege as outras: a auditoria é **por leitor**, não por fonte.

### 11.4 Largura de coluna — defeito invisível a verificação estrutural

Cabeçalho clipado (`cache_l` no lugar de `cache_leitura`) passa em **todo** teste estrutural: o XML é válido, a célula guarda a string inteira, openpyxl lê o valor certo, `unzip -t` aprova. Só o olho humano abrindo o arquivo vê. Foi encontrado exatamente assim, na inspeção visual, depois de 52 testes verdes.

**Regra adotada no motor:** a largura não é apenas derivada do conteúdo, é **piso** no que o cabeçalho exige. Largura explícita pode alargar acima do piso, **nunca estreitar abaixo** — não existe caso em que clipar um título seja intenção do chamador. Clipar um valor é recuperável (clica na célula); clipar um título não é, porque se deixa de saber o que a coluna é. O defeito ficou impossível por construção, em vez de coberto por asserção que o próximo autor de fixture reintroduz.

**Detalhe que só apareceu ao medir:** a tabela nomeada desenha o botão de autofiltro **por cima** da célula de cabeçalho, comendo ~3 caracteres. O piso leva folga extra onde há tabela; sem isso, o botão é que faz o clipe, com a largura nominalmente "correta".

### 11.5 Divergência autorizada da AC1 da EXB-6.7 — `fato.csv` ausente, não vazio

A AC1 lista `dados/fato.csv` entre os arquivos que a pasta deve conter. Enquanto o grão fino não existir (EXB-6.4), **o arquivo não é escrito** e o `leia-me.txt` declara a ausência em palavras.

**Razão:** um CSV só com cabeçalho é ingerido por ferramenta de BI **sem nenhuma reclamação** e reporta um período sem uso algum. A ferramenta fica verde afirmando uma falsidade. Ausência declarada é honesta; presença vazia é instrumento mentiroso.

Aprovado pelo lead em 2026-08-24. O encaixe está declarado no tipo (`ExportPackage.Input.fact: CSVTable?`), com teste para os dois lados. Mesmo tratamento para `painel.html` (`Input.panelHTML: String?`).

### 11.6 Dialeto dos CSV — a terceira opção é uma armadilha

| dialeto | ferramenta de BI | duplo clique no Excel pt-BR |
|---|---|---|
| **vírgula + ponto decimal** (adotado) | lê sem configurar nada | tudo numa coluna só |
| ponto-e-vírgula + vírgula decimal | precisa configurar delimitador e locale | perfeito |
| ponto-e-vírgula + ponto decimal | — | **colunas certas, números errados**: `1.9412` lido como `19412`, sem erro na tela |

A terceira foi recusada de saída. Adotada a primeira porque estes arquivos existem para **ingestão de máquina** — a peça para olho humano é a `planilha.xlsx`, e o `.pbids` ao lado confirma a intenção.

**Correção de premissa:** o BOM UTF-8 resolve a **acentuação**, não o **separador**. Com vírgula, o duplo clique num Excel pt-BR continua jogando a linha inteira numa coluna. O BOM foi mantido (custa 3 bytes) e a limitação está escrita no `leia-me.txt`.

### 11.7 Hierarquia de isolamento numa árvore compartilhada

Medida em 2026-08-24, com três frentes ativas no mesmo target. Do mais isolante ao menos:

| # | Gate | Isola de | Prova |
|---|---|---|---|
| 1 | `swiftc -typecheck -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos14 <meus arquivos>` | **tudo** | compilação |
| 2 | `swiftc -O <meus arquivos> sonda.swift -o sonda && ./sonda` | **tudo** | **comportamento** |
| 3 | `swift build --target MeusTestes` | target de app, **não** do próprio target | compilação |
| 4 | `swift test --filter` | **nada** | execução |

O degrau **4 não isola**: `--filter` seleciona o que EXECUTA; o SwiftPM constrói o target inteiro antes. Demonstrado ao vivo — entre 10:32 e 10:46 a árvore esteve vermelha por `DashboardData.swift`, `PainelHTMLTests.swift`, `PainelSampleData.swift`, `DashboardPolishTests.swift` e `CostScanner.swift`, com zero erros da frente de exportação em todas as rodadas.

O degrau **2 é o que faltava entre "compila" e "funciona"**: um executável isolado com um `main` de sonda provou estrutura do pacote, `.pbids`, BOM, CRLF e determinismo durante 12 minutos de vermelho alheio.

**Pré-condição dos degraus 1 e 2:** os arquivos da frente não podem depender de tipos do próprio target. `Core/Export/` importa apenas `Foundation` e `Compression`, e é isso que torna o gate possível. **Fronteira estreita deixou de ser detalhe de implementação e virou argumento de arquitetura.**

Corolário operacional: 1 e 2 são gates **contínuos**; 3 e 4 só valem na **janela verde**. Para pegar a janela, polling com backoff atribuindo cada erro a um arquivo, em vez de espera cega.

### 11.8 Régua permanente — audite o instrumento antes de confiar no que ele diz

Dois defeitos de instrumento em duas rodadas, ambos produzindo um número tranquilizador e falso:

1. `cmd > log.txt` captura só stdout; erro de compilador vai por **stderr**. O loop reportou "erros de build: 0" três vezes com a build vermelha. **Assinatura:** `exit=1` com contagem de erros `0`.
2. O mesmo loop contava `error:` (formato de compilador) mas não `✘` (formato de falha de teste), e reportou "erros meus: 0" havendo duas falhas minhas.

Ambos são a mesma família: **instrumento que responde com precisão a uma pergunta que não é a pergunta**. Sempre que um contador der zero numa rodada que falhou, suspeitar do instrumento antes de acreditar no zero.

Correlato de fixture: as datas esperadas de um teste devem ser **literais**, não derivadas do fixture — derivar faz a asserção concordar com qualquer erro de aritmética do autor. Custou dois testes vermelhos que estavam certos em reprovar.

### 11.9 Fonte única de rótulos — e por que a correção pontual não resolvia

`Core/Export/ExportLabels.swift` passa a ser o único lugar onde um título de coluna ou nome de série é escrito. Painel, planilha e CSV leem de lá.

**A divergência era maior do que o relatado.** O primeiro achado foi o travessão (`Cache — leitura` contra `Cache de leitura`). Ao unificar, apareceu que **dois dos quatro rótulos divergiam inteiramente**: a legenda do painel dizia `Entrada` e `Saída` onde a planilha dizia `Tokens de entrada` e `Tokens de saída`. O travessão era o sintoma visível de um desalinhamento de 4 em 4.

**Mecanismo, e é o que torna o caso instrutivo:** cada frente testou a própria peça contra a própria expectativa, e as duas passaram. Nenhum teste podia ver a divergência porque **a comparação entre peças não pertencia a ninguém**. Enquanto o rótulo for literal duplicado, ele volta a divergir na próxima edição — a correção pontual adia, não resolve.

**Escolha de redação, com o custo declarado.** O canônico é a forma longa. Uma legenda sob um título que já diz "Tokens por dia" leria melhor como só `Entrada`, mas a mesma palavra precisa servir de cabeçalho de planilha, onde nada fornece esse contexto — e no workbook **a legenda do gráfico é derivada da célula de cabeçalho**, então ali as duas não podem divergir nem em princípio. Legenda curta exigiria desacoplar a legenda do cabeçalho no XLSX, mudança maior do que esta compra.

### 11.10 Gate de convergência de pacote

Três testes em `ExportPackageTests`, sobre o pacote **montado**, não sobre o código:

| Gate | O que compara |
|---|---|
| `panelAndWorkbookAgreeOnEveryLabel` | cada rótulo canônico aparece, verbatim, nas três peças |
| `panelAndCSVAgreeOnTheDailyTotals` | os totais diários e o custo, campo a campo |
| `noArtifactSpellsASharedLabelItself` | nenhum arquivo de `Export/` reescreve um rótulo canônico como literal |

**Controle positivo, exigido antes de o gate valer:** reintroduzido `("Saída", …)` no painel, `panelAndWorkbookAgreeOnEveryLabel` reprovou com `painel.html is missing the label "Tokens de saída"`. Revertido, verde. Um gate de convergência que nunca foi visto pegar uma divergência não prova convergência nenhuma.

**Defeito encontrado no próprio gate, na primeira execução:** `noArtifactSpellsASharedLabelItself` acusou `PainelHTMLWriter.swift` por causa do **comentário** que explica a divergência — o detector reprovando a própria documentação. Corrigido ignorando linhas de comentário. Um comentário que cita o rótulo é o oposto de um literal duplicado: é o registro de por que o literal saiu.

#### Régua da casa — um gate que busca string precisa distinguir **uso** de **menção**

Aconteceu **duas vezes no mesmo dia, em frentes diferentes**:

| Gate | O que ele queria proibir | Quem ele acusou |
|---|---|---|
| `noArtifactSpellsASharedLabelItself` | rótulo reescrito como literal | o comentário que explica por que o literal saiu |
| grep por `"economia por cache"` (frente do painel) | o cartão em dólar que foi removido | a nota de rodapé que explica a remoção |

O padrão é o mesmo: o texto que **documenta** a ausência de algo contém, necessariamente, o nome desse algo. Um detector que só vê a presença do token reprova exatamente a prosa que prova que o trabalho foi feito — e o caminho de menor resistência para passar no gate é **apagar a explicação**, ou seja, o gate pressiona contra a documentação honesta.

Antes de fechar um gate baseado em busca de string, verificar as três formas:

1. **Uso** — o literal está no código que produz o artefato. É o que se quer proibir.
2. **Menção** — o literal está em comentário, doc-comment ou string de teste que descreve o defeito. Deve passar.
3. **Negação** — o artefato diz *"não há X"*. Um detector de token é cego à negação e conta como se fosse X.

Mínimo praticável: filtrar linhas de comentário antes de buscar, e preferir asserção sobre o **artefato montado** (onde só existe uso) em vez de sobre o **fonte** (onde convivem uso e menção). Os dois gates de convergência acima seguem essa ordem de preferência; o terceiro, que precisa mesmo olhar o fonte, paga o preço de filtrar comentários.

### 11.11 O sha256 do painel mudou, e tinha de mudar

O painel corrigido (sem o cartão de economia em dólar) era `b7325859…840e`. Depois da unificação de rótulos passou a ser `fdba7a9d…6a16`, porque quatro strings de legenda mudaram.

**O hash não é a propriedade; era um substituto dela.** A propriedade que importava — ausência do contrafactual em dólar — foi verificada diretamente e continua valendo: zero cartões `rotulo: "Economia…"` no fonte, zero cifrões em cartão de economia no HTML, e a página segue declarando explicitamente que o número não existe.

Lição para os próximos handoffs: **fixar um hash como critério de aceite congela o artefato inteiro, inclusive as partes que outra frente tem ordem de mudar.** Quando o critério real é semântico ("o cartão saiu"), o gate deve medir a semântica; o hash serve para determinismo entre duas gerações da MESMA entrada, não como contrato entre frentes.

### 11.12 O gate de bolso depende de quem é dono da pasta

`swiftc -typecheck … Sources/ClaudeBarCore/Export/*.swift` prova a saúde de quem for **dono da pasta inteira**. Enquanto duas frentes escreviam ali, o glob compilava arquivos alheios e deixava de ser prova sobre uma só frente. Com a propriedade consolidada, volta a ser.

Registro porque ninguém relê o comando: **se a pasta voltar a ter mais de um dono, o gate precisa listar arquivos em vez de usar o glob.**

### 11.13 Retratação — o corpo do commit `c06254a` afirma algo que a medição derrubou

O commit **`c06254a`** (*"fix(export): apaga a terceira cópia do cálculo de dia, em vez de corrigi-la"*) encerra, no último parágrafo, esta frase:

> *"os valores são constantes, então duas rodadas na mesma máquina dão os mesmos bytes, mas as datas são meia-noite local e os bytes não são idênticos entre fusos."*

**A segunda metade é falsa.** Os bytes **são** idênticos entre fusos. Medido rodando os mesmos artefatos sob três `TZ`:

| Artefato | sha256 | `America/Sao_Paulo` | `Asia/Tokyo` | `UTC` |
|:---|:---|:---:|:---:|:---:|
| `planilha.xlsx` | `9a5681a9…5247` | ✓ | ✓ | ✓ |
| `diario.csv` | `85a86713…6787` | ✓ | ✓ | ✓ |
| `painel.html` | `fa7f3db8…06dc` | ✓ | ✓ | ✓ |

A razão é o próprio remédio da onda: a fixture **nomeia** a data (*"1 de agosto de 2026"*) em vez de derivá-la de um instante, e os dois escritores a convertem de volta ao mesmo dia local em qualquer lugar. Nunca houve perda de reprodutibilidade entre fusos. O que houve foi uma **fixture instável** (`PainelSampleData`, que derivava o início da janela de um instante UTC) descoberta e corrigida nesta mesma onda, e a suíte passou a ser verificada nos três fusos.

**Por que a retratação vive aqui e não no histórico.** A frase foi para uma `main` pública. Reescrever histórico publicado para consertar prosa de commit é um dano maior que o defeito, e o registro fica onde alguém procuraria. As notas das releases `v2.5.1` e `v2.5.2` já foram corrigidas no lugar delas, e a da `v2.5.2` carrega a tabela acima, para o leitor não precisar acreditar em ninguém.

#### Régua da casa — a descrição chega antes da medição, e a medição a corrige

Aconteceu **cinco vezes nesta onda**, sempre na mesma direção, e em nenhuma delas a descrição foi desonesta: foi **confiante**.

| # | O que se descreveu | O que a medição mostrou |
|:---:|:---|:---|
| 1 | a suíte tinha 609 testes em 67 suítes | **608/66** — a diferença era um arquivo de andaime criado e apagado no meio da medição |
| 2 | havia um *"escape de segurança"* a commitar | o escape já existia; o que era novo é o **teste de regressão** que o prova |
| 3 | a terceira cópia deslocava o eixo dos gráficos | **armadilha latente**, não defeito embarcado: o ramo que a alcançaria não é exercido |
| 4 | os bytes deixaram de ser reprodutíveis entre fusos | **idênticos nos três** (esta seção) |
| 5 | `strings \| grep` provaria a correção no binário | probe cego: procura literal onde há **chamada de método**; `nm` provou, e ainda revelou a terceira cópia |

Duas dessas chegaram a ficar **publicadas** por alguns minutos, nas notas de release. Nenhuma sobreviveu como afirmação permanente, e isso não foi sorte: foi medir o que se mandou descrever.

O parentesco com o **instrumento mentiroso** (§11.10) é direto, e é o que torna a régua útil. Ali, o gate responde com precisão a uma pergunta que não é a pergunta. Aqui, a prosa faz o mesmo, uma camada acima: descreve com precisão um sistema que não é o sistema. Um comentário sobre determinismo que nunca foi executado é um palpite com a autoridade de documentação — e é por isso que o cabeçalho de `ExportSampleWorkbook` passou a carregar a saída do comando em vez de um argumento.
