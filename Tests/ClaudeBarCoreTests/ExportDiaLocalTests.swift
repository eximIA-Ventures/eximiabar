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
