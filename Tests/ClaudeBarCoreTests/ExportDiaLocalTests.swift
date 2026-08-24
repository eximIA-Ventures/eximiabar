import Foundation
import Testing
@testable import ClaudeBarCore

/// The exported day is the day on the owner's clock — in every time zone, not only in the author's.
///
/// **The defect these tests exist for.** Every date in this export is a local start-of-day: the
/// dashboard buckets days with `Calendar.current.startOfDay`, so "24/08" on screen is the instant
/// `2026-08-24T00:00` *local*. Both writers used to convert that instant in **UTC**. West of
/// Greenwich that happens to give the right answer — local midnight is still the same date a few
/// hours later in UTC — so the defect was invisible to every test ever run here. East of Greenwich it
/// is not: local midnight in Tokyo is 15:00 of the **previous day** in UTC, and every row of
/// `diario.csv` came out shifted one day back, silently, in a file whose only purpose is to be read
/// by another tool.
///
/// **Why the zone is a parameter.** A test that only exercises the machine it runs on cannot see a
/// zone defect — the same blindness that let a fixed-window mutant survive a ten-field convergence
/// test that used a single slice. Passing the zone in is what makes both directions measurable from
/// one machine.
struct ExportDiaLocalTests {
    static let toquio = TimeZone(identifier: "Asia/Tokyo")!       // UTC+9, east
    static let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")! // UTC−3, west
    static let utc = TimeZone(identifier: "UTC")!

    /// Local midnight of `2026-08-24` in `zona`.
    static func meiaNoite(_ zona: TimeZone) -> Date {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = zona
        var partes = DateComponents()
        partes.year = 2026; partes.month = 8; partes.day = 24
        return calendario.date(from: partes)!
    }

    // MARK: - The CSV date

    /// The same calendar date comes out of the CSV writer on both sides of Greenwich.
    @Test
    func oDiaDoCSVEODiaDoRelogioDoDono() {
        #expect(CSVWriter.isoDay(Self.meiaNoite(Self.toquio), timeZone: Self.toquio) == "2026-08-24")
        #expect(CSVWriter.isoDay(Self.meiaNoite(Self.saoPaulo), timeZone: Self.saoPaulo) == "2026-08-24")
    }

    /// **The positive control.** The same instant, read in UTC, is the day before — east of Greenwich.
    ///
    /// This is the defect itself, expressed as an assertion rather than as a memory of a mutation run.
    /// It also proves the fixture has teeth: if reading the Tokyo midnight in UTC produced
    /// `2026-08-24` too, the test above would pass under a broken implementation and mean nothing.
    @Test
    func lerEmUTCEscorregaUmDiaALesteDeGreenwich() {
        #expect(CSVWriter.isoDay(Self.meiaNoite(Self.toquio), timeZone: Self.utc) == "2026-08-23")

        // And west of Greenwich it does **not** slip — which is exactly why the defect survived here.
        // A machine in São Paulo cannot tell the two implementations apart on this input.
        #expect(CSVWriter.isoDay(Self.meiaNoite(Self.saoPaulo), timeZone: Self.utc) == "2026-08-24")
    }

    // MARK: - The Excel serial

    /// A local midnight is a whole serial: Excel stores wall-clock days and has no notion of zone, so
    /// any fraction left over is an offset that leaked into the file.
    @Test
    func oSerialDeUmaMeiaNoiteLocalEInteiro() {
        for zona in [Self.toquio, Self.saoPaulo, Self.utc] {
            let serial = XLSXDateSerial.serial(for: Self.meiaNoite(zona), timeZone: zona)
            #expect(serial.truncatingRemainder(dividingBy: 1) == 0, "sobrou fuso no serial de \(zona.identifier)")
            #expect(serial == 46_258, "2026-08-24 é o serial 46258 em qualquer fuso")
        }
    }

    /// The serial slips by a whole day east of Greenwich when the zone is ignored — the same defect as
    /// the CSV, in the neighbouring artifact, because both read the same instants.
    @Test
    func oSerialLidoEmUTCEscorregaALeste() {
        let toquio = XLSXDateSerial.serial(for: Self.meiaNoite(Self.toquio), timeZone: Self.utc)
        #expect(toquio == 46_257.625) // 2026-08-23, mais 15h — nem o dia certo, nem meia-noite
        #expect(Int(toquio.rounded(.down)) == 46_257)
    }

    // MARK: - The workbook does not disagree with itself

    /// The date label cached inside a chart is the same day the cell beside it holds.
    ///
    /// **The defect this exists for, and why it was worse than the original.** A third copy of the
    /// day arithmetic lived, private and under another name, inside the chart writer — so the search
    /// that found the first two missed it. With the other two corrected, east of Greenwich the sheet
    /// would carry the right local day in its cells while the chart, reading the very same range,
    /// cached the day before. Uniformly wrong is recognisable as a defect; **internally inconsistent
    /// reads as "the data is strange"**, which is how a wrong number survives.
    ///
    /// Measured on the bytes the writer actually emits: the point is precisely that two code paths
    /// were producing day labels, and only an assertion over the finished artifact sees them disagree.
    ///
    /// **What the measurement showed, and it corrects the alarm.** A category range holding dates goes
    /// out as a `<c:numRef>` of **serials** — `categoryReference` decides from the actual cells, and a
    /// date makes the range numeric. So the six charts of this release cache serials from
    /// ``XLSXDateSerial/serial(for:timeZone:)``, the corrected function, and the `<c:strCache>` beside
    /// them holds **series names**, never dates. The duplicate was real and was in UTC, but it was
    /// unreachable from these workbooks: it fires only if a `.date` cell reaches `stringReference`,
    /// which today happens only for a header cell. A latent trap, removed — not an active defect that
    /// shipped.
    @Test
    func oGraficoEACelulaNomeiamOMesmoDia() throws {
        let partes = XLSXWriter.entries(for: ExportSampleWorkbook.make())
        let grafico = try #require(partes.first { $0.path == "xl/charts/chart1.xml" })
        let xml = String(decoding: grafico.payload, as: UTF8.self)

        // The day axis is cached as serials, and each one is the serial of the cell it came from.
        for deslocamento in 0..<8 {
            let serial = XLSXDateSerial.serial(for: ExportSampleWorkbook.day(deslocamento))
            #expect(serial.truncatingRemainder(dividingBy: 1) == 0, "sobrou fuso no serial do eixo")
            #expect(
                xml.contains("<c:v>\(Int(serial))</c:v>"),
                "o eixo do gráfico não traz o serial \(Int(serial)) que a célula carrega")
        }

        // And the day before the first is absent — a one-day slip is exactly what would put it there.
        let vespera = Int(XLSXDateSerial.serial(for: ExportSampleWorkbook.day(-1)))
        #expect(!xml.contains("<c:v>\(vespera)</c:v>"), "serial de um dia antes do início do eixo")
    }

    /// The fixtures **name a date**; they do not derive one from an instant.
    ///
    /// **This is what keeps the exported bytes independent of where the test runs.** A fixture written
    /// as `startOfDay(for: Date(timeIntervalSince1970: …))` is the day *containing* a fixed UTC instant,
    /// and that is a different calendar day depending on the machine: 31 July in São Paulo, 1 August in
    /// Tokyo. Measured on `painel.html` before this was fixed — `fdba7a9d…` here against `fa7f3db8…`
    /// under `TZ=Asia/Tokyo`. A determinism gate written on top of that is green locally and red on a
    /// CI configured in UTC, which is the worst kind of gate: one that passes because of where it ran.
    ///
    /// Honest limit of this assertion: in a zone where the two definitions coincide it cannot tell them
    /// apart. It fails wherever they diverge, which is exactly where the defect would matter.
    @Test
    func asFixturesNomeiamUmaDataEmVezDeDerivarDeUmInstante() {
        let calendario = Calendar.current
        for (rotulo, data) in [
            ("ExportSampleWorkbook", ExportSampleWorkbook.day(0)),
            ("PainelSampleData", PainelSampleData.dia(0)),
        ] {
            let partes = calendario.dateComponents([.year, .month, .day], from: data)
            #expect(partes.year == 2026, "\(rotulo): ano \(partes.year ?? -1)")
            #expect(partes.month == 8, "\(rotulo): mês \(partes.month ?? -1)")
            #expect(partes.day == 1, "\(rotulo): dia \(partes.day ?? -1) — a fixture derivou de um instante")
        }
    }

    /// **The gate that would have caught the third site**, and the one that stops a fourth.
    ///
    /// The day arithmetic survived one correction because it existed **twice**: the two public writers
    /// were fixed and a private twin, under another name, stayed in UTC. Searching by name found two of
    /// three; searching by *pattern* finds them all. So the invariant is not "the code is right" — it
    /// is "there is only one implementation to be right about".
    ///
    /// `719_468` is the epoch shift of the civil-from-days algorithm: it appears once per copy, and
    /// nowhere else. Comment lines are excluded, because prose that explains the algorithm is a
    /// *mention*, not a second implementation — a detector blind to that difference pressures the next
    /// author into deleting the explanation to pass the gate.
    @Test
    func existeUmaSoImplementacaoDoCalculoDeDia() throws {
        let pasta = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ClaudeBarCore/Export")

        var sitios: [String] = []
        for nome in try FileManager.default.contentsOfDirectory(atPath: pasta.path)
        where nome.hasSuffix(".swift") {
            let fonte = try String(contentsOf: pasta.appendingPathComponent(nome), encoding: .utf8)
            for (indice, linha) in fonte.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let semEspaco = linha.trimmingCharacters(in: .whitespaces)
                guard !semEspaco.hasPrefix("//"), !semEspaco.hasPrefix("///") else { continue }
                if linha.contains("719_468") { sitios.append("\(nome):\(indice + 1)") }
            }
        }
        #expect(sitios.count == 1, "o cálculo de dia foi duplicado: \(sitios)")
    }

    // MARK: - The two artifacts agree

    /// The workbook and the CSV name the same day for the same instant.
    ///
    /// They are written by different code paths from the same dates, and this is the only place that
    /// compares them: a shift in one of the two would otherwise be a divergence nobody owns.
    @Test
    func aPlanilhaEOCSVNomeiamOMesmoDia() {
        for zona in [Self.toquio, Self.saoPaulo, Self.utc] {
            let instante = Self.meiaNoite(zona)
            let serial = XLSXDateSerial.serial(for: instante, timeZone: zona)
            // Excel's epoch is 1899-12-30; serial 46258 is 2026-08-24.
            #expect(serial == 46_258)
            #expect(CSVWriter.isoDay(instante, timeZone: zona) == "2026-08-24")
        }
    }
}
