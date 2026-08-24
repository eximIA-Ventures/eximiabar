import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the export button produces.
///
/// Three formats, and each one is a different promise. `csv` is the raw daily table the toolbar has
/// always written; `planilha` is the formatted workbook, charts included; `pacote` is the folder the
/// architecture note settled on — the interactive panel plus the workbook plus the tidy CSVs plus the
/// Power BI connection file plus the plain-text caveats.
enum ExportFormato: String, CaseIterable, Identifiable, Sendable {
    case csv
    case planilha
    case pacote

    var id: String { self.rawValue }

    /// The label on the segment.
    var rotulo: String {
        switch self {
        case .csv: L("dashboard.export.format.csv")
        case .planilha: L("dashboard.export.format.xlsx")
        case .pacote: L("dashboard.export.format.pack")
        }
    }

    /// One line under the segments saying what the chosen format actually contains.
    ///
    /// Present because the three are not interchangeable and the difference is invisible from the
    /// names alone: somebody expecting charts and picking `CSV` would get a text file and conclude the
    /// feature is broken.
    var explicacao: String {
        switch self {
        case .csv: L("dashboard.export.hint.csv")
        case .planilha: L("dashboard.export.hint.xlsx")
        case .pacote: L("dashboard.export.hint.pack")
        }
    }

    /// The file extension, or `nil` for the package — which is a folder and carries none.
    var extensao: String? {
        switch self {
        case .csv: "csv"
        case .planilha: "xlsx"
        case .pacote: nil
        }
    }

    /// What the save panel will accept.
    ///
    /// Empty for the package on purpose: a folder has no content type, and constraining the field
    /// would make the panel append an extension to a directory name.
    var tiposPermitidos: [UTType] {
        switch self {
        case .csv: [.commaSeparatedText]
        // Declared by identifier because the SDK's `UTType` catalogue has no static member for it.
        case .planilha: [UTType("org.openxmlformats.spreadsheetml.sheet")].compactMap { $0 }
        case .pacote: []
        }
    }
}

// MARK: - Suggested file name

/// The name the save panel proposes, and how it survives a change of format.
///
/// Pure functions in their own type so the behaviour is testable without opening a panel: the rule
/// "keep what the owner typed, replace what the app proposed" is easy to get subtly wrong and
/// impossible to see in a screenshot.
enum ExportNome {
    /// The app's proposal for `formato`.
    ///
    /// The package names itself after the folder convention the engine already writes
    /// (`exportacao-eximiabar-YYYY-MM-DD`); the two single files keep the historical
    /// `claude-usage-<recorte>-<dia>` shape, whose `<recorte>` names the slice on screen — a shortcut
    /// names itself, a dragged range names its dates.
    static func padrao(formato: ExportFormato, recorte: String, dia: String) -> String {
        switch formato {
        case .pacote: "exportacao-eximiabar-\(dia)"
        case .csv, .planilha: "claude-usage-\(recorte)-\(dia).\(formato.extensao ?? "")"
        }
    }

    /// The name to show after the owner switches format.
    ///
    /// If the field still holds the app's own proposal, it is replaced wholesale — the package's stem
    /// differs from the single files', so swapping only the extension would leave a `.csv` named after
    /// a folder. If the owner typed something, only the extension moves: their words are theirs.
    static func aoTrocar(
        de anterior: ExportFormato,
        para novo: ExportFormato,
        nomeAtual: String,
        recorte: String,
        dia: String) -> String
    {
        let proposto = padrao(formato: anterior, recorte: recorte, dia: dia)
        guard nomeAtual != proposto else {
            return padrao(formato: novo, recorte: recorte, dia: dia)
        }
        return trocandoExtensao(nomeAtual, para: novo)
    }

    /// `nome` with the extension of `formato`, or with none at all for the package.
    static func trocandoExtensao(_ nome: String, para formato: ExportFormato) -> String {
        var base = nome
        for conhecida in ["csv", "xlsx"] where base.lowercased().hasSuffix(".\(conhecida)") {
            base = String(base.dropLast(conhecida.count + 1))
        }
        guard let extensao = formato.extensao else { return base }
        return "\(base).\(extensao)"
    }
}

// MARK: - Selection

/// The chosen format, shared between the accessory view and the controller that reads it when the
/// panel closes.
///
/// A tiny observable rather than a `@State` inside the view because the value has to outlive the
/// view's own update cycle: `NSSavePanel` hands the result back to the controller, which needs to know
/// what was selected at that moment.
@MainActor
@Observable
final class ExportFormatoSelecao {
    /// The package is the default because it is the artifact the owner asked for — the one that
    /// "já vem com gráficos". The choice is never silent: the segment is lit and the line beneath it
    /// spells out what will be written.
    var formato: ExportFormato = .pacote

    init(formato: ExportFormato = .pacote) {
        self.formato = formato
    }
}

// MARK: - Accessory view

/// The format chooser, hosted inside the save panel's `accessoryView`.
///
/// **Why it lives here and not in the toolbar.** The request was to add formats without adding
/// controls to the dashboard, and the save panel is already on screen at exactly the moment the
/// question matters.
///
/// **Why it is a segmented picker.** The obvious control — a pop-up list — is banned by the
/// anti-freeze gate T-R18, which scans the whole app target for menu constructs because they drag back
/// the menu-tracking run loop the panel architecture exists to avoid. A segmented picker passes the
/// scan and matches the period control the dashboard already uses.
struct ExportFormatoAccessory: View {
    @Bindable var selecao: ExportFormatoSelecao
    /// Which slice is being exported, in words. The period is **not** repeated as a control: the
    /// toolbar already owns it, and two controls for one question is how "exportei 30 dias e veio 7"
    /// happens.
    let legendaDoPeriodo: String
    /// Called with the previous and the new format, so the panel can move its extension along.
    var aoTrocar: (ExportFormato, ExportFormato) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L("dashboard.export.format"))
                Picker("", selection: $selecao.formato) {
                    ForEach(ExportFormato.allCases) { formato in
                        Text(formato.rotulo).tag(formato)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(selecao.formato.explicacao)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(legendaDoPeriodo)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: selecao.formato) { anterior, novo in
            aoTrocar(anterior, novo)
        }
    }
}
