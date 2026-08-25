import AppKit
import ClaudeBarCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The `@Observable` state the dashboard window binds to (EXB-2.3 / EXB-3.2).
///
/// The hosting view reads `state` and `period`; the controller flips `state` from `.loading` to a
/// terminal state on `@MainActor` once the off-main scan completes. Kept tiny and `@MainActor` so
/// there is no data race between the detached scan task and the SwiftUI render.
@MainActor
@Observable
final class DashboardModel {
    var state: DashboardState = .loading
    /// The shortcut lit in the toolbar, or `nil` when the range on screen was dragged (EXB-5.8 §8).
    var atalho: DashboardPeriod? = .thirtyDays
    /// `true` while a background fold is in flight *and* prior content is still on screen (EXB-3.6
    /// BUG 2 AC3). Drives a non-blocking overlay so changing the range never leaves stale charts
    /// looking frozen — the `.loading` full-screen state is reserved for the first open.
    var isRefreshing = false
    /// Invoked when the segmented control picks a shortcut (wired by the controller, AC1).
    var onPeriodChange: (@MainActor (DashboardPeriod) -> Void)?
    /// Invoked when a range is dragged over the timeline (EXB-5.8 §8).
    var onRangeChange: (@MainActor (ClosedRange<Date>) -> Void)?
    /// Invoked by the toolbar's export button (wired by the controller, AC9 / EXB-6.8).
    ///
    /// Named for the action, not for one of its outcomes: the button used to write a CSV and now opens
    /// a panel where the format is chosen.
    var onExport: (@MainActor () -> Void)?

    func selectPeriod(_ period: DashboardPeriod) {
        guard period != self.atalho else { return }
        self.onPeriodChange?(period)
    }
}

/// Owns the local analytics dashboard `NSWindow` (EXB-2.3 / EXB-3.2).
///
/// Mirrors `SettingsWindowController`'s LSUIElement activation-policy dance: exímIABar runs as an
/// `.accessory` agent (no Dock icon), so to bring a real window forward it temporarily becomes
/// `.regular` and reverts to `.accessory` on close. The window is a standard `NSWindow`, 760×560 pt
/// minimum, resizable, titled (AC11).
///
/// Incremental cache (AC12): a `DashboardData` is memoized per `DashboardPeriod`. Selecting a period
/// already in cache applies it instantly with no re-scan; the cache is invalidated when the JSONL
/// directories' modification fingerprint changes between opens.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let costSettingsProvider: @Sendable () -> LiveUsageProvider.CostSettings
    private let costScanner: CostScanner
    private let openSettings: @MainActor () -> Void

    private let model = DashboardModel()
    private var window: NSWindow?
    private var scanTask: Task<Void, Never>?
    /// The SwiftUI host. Held so the macOS 26 glass path can re-parent it under the
    /// `NSGlassEffectView` when the transparency level changes (EXB-3.5 AC3).
    private var hostingView: NSView?
    /// macOS 26 Liquid Glass backing (EXB-3.5 AC3). `nil` on macOS < 26 and while `.opaque` is
    /// selected. Typed as `NSView?` so the stored property needs no availability annotation.
    private var glassBacking: NSView?
    /// The live transparency level, read at `open()` to seed the glass backing on macOS 26.
    private let transparencyProvider: @MainActor () -> TransparencyLevel
    /// The active popover theme (v2.3.0), read when the window is built so the dashboard's accent
    /// (charts, highlight numbers, the model ramp's accent swatch) matches the popover skin.
    private let themeProvider: @MainActor () -> PopoverTheme

    /// Owns what is on screen (EXB-5.8 §8). The per-period `DashboardData` cache that used to live
    /// here existed only to dodge a re-scan; with the history loaded once and every range change a
    /// pure fold, there is nothing left to memoize that is cheaper than recomputing.
    private var rangeModel: DashboardRangeModel?
    private var observacao: Task<Void, Never>?

    /// AC11's floor, expressed in **content** points (the frame minimum is this plus the titlebar,
    /// which is how the authored 760×560 frame minimum was originally written).
    ///
    /// 760 wide is not decorative: the KPI grids of `VolumeSection` and `CostSection` lay their cards
    /// out with `GridItem(.adaptive(minimum: 168))` inside 20pt padding, so below this width the grid
    /// reflows and the row is clipped — the "cards cut in half" defect. It must be re-asserted after **every**
    /// `contentView` swap: installing a content view whose subtree uses auto layout makes AppKit
    /// re-derive the window's size limits from that subtree's constraints and silently discard
    /// whatever was set before. `NSGlassEffectView` pins its `contentView` with constraints, so the
    /// glass paths (`.frosted` — the default — and `.standard`) used to end up with a 241×32 floor.
    private static let minimumContentSize = NSSize(width: 760, height: 528)

    init(
        costSettingsProvider: @escaping @Sendable () -> LiveUsageProvider.CostSettings,
        costScanner: CostScanner = .shared,
        openSettings: @escaping @MainActor () -> Void,
        transparencyProvider: @escaping @MainActor () -> TransparencyLevel = { .frosted },
        themeProvider: @escaping @MainActor () -> PopoverTheme = { .classic })
    {
        self.costSettingsProvider = costSettingsProvider
        self.costScanner = costScanner
        self.openSettings = openSettings
        self.transparencyProvider = transparencyProvider
        self.themeProvider = themeProvider
    }

    // MARK: - Open (AC1/AC12)

    func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if window == nil {
            setupWindow()
        }
        // Note on scroll position: `open()` always routes through `.loading`, which unmounts the
        // loaded content and with it the `NSScrollView` backing SwiftUI's `ScrollView`. The dashboard
        // therefore always reopens at the top of the content on its own — measured, not assumed — so
        // no explicit scroll reset is needed here. Content that *looks* scrolled past is the window
        // being smaller than `minimumContentSize`, which is what that floor exists to prevent.
        model.state = .loading
        window?.makeKeyAndOrderFront(nil)

        // A fresh open re-reads the disk once, so re-opening reflects new usage. Every range change
        // after this is arithmetic.
        recarregar()
    }

    /// Re-assert `minimumContentSize` on the window. Must run after **every** `contentView`
    /// assignment — see the doc on `minimumContentSize` for why the value does not survive one.
    private func enforceMinimumContentSize() {
        guard let window else { return }
        window.contentMinSize = Self.minimumContentSize
    }

    private func setupWindow() {
        model.onPeriodChange = { [weak self] period in
            self?.aguardarDobra(self?.rangeModel?.aplicarAtalho(period))
        }
        // The drag goes through the debounced door (EXB-6.1). This callback is driven by
        // `chartXSelection(range:)`, which fires continuously while the pointer is down, and the fold
        // behind it re-folds every bucket — so per-emission folding is a freeze waiting to be
        // rediscovered. The shortcut above deliberately does not debounce: it emits once.
        model.onRangeChange = { [weak self] intervalo in
            self?.aguardarDobra(self?.rangeModel?.aplicarArrasto(intervalo))
        }
        model.onExport = { [weak self] in self?.exportar() }

        let hostingView = NSHostingView(
            rootView: DashboardRoot(model: model, openSettings: openSettings)
                .environment(\.popoverTheme, themeProvider()))
        // Size with the window, not with the SwiftUI ideal size. `NSWindow.setContentView(_:)` forces
        // this anyway, but spelling it out keeps the first setup identical to the re-parent paths in
        // `applyTransparency` instead of relying on an AppKit side effect.
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        // AC11: standard NSWindow, 760×560 minimum, resizable, titled.
        let contentSize = NSSize(width: 760, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = L("dashboard.window.title")
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        window.contentView = hostingView
        self.hostingView = hostingView
        self.window = window
        // AFTER the content view is installed: setting it re-derives the window's size limits.
        self.enforceMinimumContentSize()

        // EXB-3.5 AC3: on macOS 26 wrap the dashboard content in native Liquid Glass; on macOS < 26
        // the plain hosting-view content view (the EXB-2.3/3.2 behaviour) stays in place.
        self.applyTransparency(transparencyProvider())
    }

    // MARK: - Transparency (EXB-3.5 AC3)

    /// Adopt the macOS 26 Liquid Glass backing for `level`, or keep the plain hosting-view content view
    /// on macOS < 26 (the EXB-2.3/3.2 fallback). `.opaque` on macOS 26 also keeps the plain content
    /// view — there is no glass for the off switch (AC4). Re-parents the SwiftUI host as the glass
    /// `contentView` (the only SDK-guaranteed in-glass placement). Pure AppKit on the main thread
    /// (anti-freeze invariant: no I/O, no parse). No-op until the window exists.
    func applyTransparency(_ level: TransparencyLevel) {
        guard let window, let hostingView else { return }
        guard #available(macOS 26.0, *) else { return }
        // Every exit below either swaps the content view or leaves one already installed; re-assert
        // the floor on all of them rather than at each `return`.
        defer { self.enforceMinimumContentSize() }
        guard let style = level.glassStyle else {
            // `.opaque` (AC4): plain content view, no glass — the EXB-3.2 baseline.
            if window.contentView !== hostingView {
                self.glassBacking = nil
                hostingView.removeFromSuperview()
                hostingView.translatesAutoresizingMaskIntoConstraints = true
                hostingView.autoresizingMask = [.width, .height]
                hostingView.frame = window.contentLayoutRect
                window.contentView = hostingView
            }
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            return
        }
        if let existing = self.glassBacking as? NSGlassEffectView {
            existing.style = style
            if window.contentView !== existing { window.contentView = existing }
            return
        }
        hostingView.removeFromSuperview()
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        let glassView = GlassEffectBridge.makeGlassView(
            contentView: hostingView,
            cornerRadius: 0,
            style: style)
        glassView.frame = window.contentLayoutRect
        self.glassBacking = glassView
        window.contentView = glassView
        // AC5: the glass is the view, not the window — keep the window transparent so the desktop
        // shows through the Liquid Glass.
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    // MARK: - Off-main load + pure range folds (EXB-5.8 §8)

    /// Read the disk once and show the current range. When cost tracking is off, show the disabled
    /// state instead.
    private func recarregar() {
        guard costSettingsProvider().enabled else {
            model.state = .disabled
            return
        }
        let modelo = rangeModel ?? DashboardRangeModel(
            source: CostScannerSource(scanner: costScanner),
            atalhoInicial: model.atalho ?? .thirtyDays)
        rangeModel = modelo

        if case .loaded = model.state {
            model.isRefreshing = true
        } else {
            model.isRefreshing = false
            model.state = .loading
        }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await modelo.carregarUmaVez()
            guard !Task.isCancelled else { return }
            self?.sincronizar()
        }
    }

    /// Raise the refresh overlay now, then mirror the result when the fold actually lands.
    ///
    /// Awaiting the fold's own handle, not a timer. The first version of this polled every 30 ms and
    /// re-read the model hoping the work had finished — the same "guess about timing" that, in the
    /// test helper, let a stale range be read as the new one. A handle on the work is checkable.
    private func aguardarDobra(_ dobra: Task<Void, Never>??) {
        sincronizar()
        guard let dobra = dobra ?? nil else { return }
        observacao?.cancel()
        observacao = Task { [weak self] in
            await dobra.value
            guard !Task.isCancelled else { return }
            self?.sincronizar()
        }
    }

    /// Mirror the range model into the observable the view binds to.
    private func sincronizar() {
        guard let modelo = rangeModel else { return }
        model.atalho = modelo.atalho
        model.isRefreshing = modelo.isRefreshing
        if let dados = modelo.dados {
            model.state = dados.isEmpty ? .empty : .loaded(dados)
        }
    }

    // MARK: - Export (AC9 / EXB-6.8)

    /// Present an `NSSavePanel` with a format chooser and write the slice currently on screen.
    ///
    /// **What changed, and why here.** The button used to write one CSV and swallow any error inside a
    /// `try?` with the panel already gone. It now offers the three artifacts the export engine builds —
    /// raw CSV, the formatted workbook, and the whole package — and reports what happened. The chooser
    /// lives in the panel's `accessoryView` rather than in the toolbar, so the dashboard gains no new
    /// control; and it is a segmented picker rather than a pop-up list because the anti-freeze gate
    /// T-R18 bans menu constructs from this target.
    ///
    /// **The export follows the screen.** `data` is the `DashboardData` being rendered right now, so a
    /// dragged range exports that range. There is deliberately no period control in the panel: the
    /// toolbar already owns the period, and a second control for the same question is how "exportei 30
    /// dias e veio 7" happens. The accessory says in words which slice is going out.
    private func exportar() {
        guard case let .loaded(data) = model.state, let window else { return }
        let dia = Self.fileDateTag()
        let recorte = data.fileTag
        let selecao = ExportFormatoSelecao()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        Self.aplicar(selecao.formato, em: panel, recorte: recorte, dia: dia)

        let acessorio = NSHostingView(rootView: ExportFormatoAccessory(
            selecao: selecao,
            legendaDoPeriodo: L("dashboard.export.period", PainelExport.rotuloDaJanela(data)),
            aoTrocar: { [weak panel] anterior, novo in
                guard let panel else { return }
                Self.aplicar(
                    novo, em: panel, recorte: recorte, dia: dia,
                    substituindo: anterior, nomeAtual: panel.nameFieldStringValue)
            }))
        acessorio.frame = NSRect(x: 0, y: 0, width: 460, height: 96)
        panel.accessoryView = acessorio

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.escrever(data, formato: selecao.formato, em: url)
        }
    }

    /// Point the panel at `formato`: what it accepts, and what it proposes to call the file.
    ///
    /// `substituindo` is the format the field was named for. Passing it keeps a name the owner typed
    /// himself and replaces only the one the app proposed — the rule lives in `ExportNome`, tested
    /// there rather than guessed here.
    private static func aplicar(
        _ formato: ExportFormato,
        em panel: NSSavePanel,
        recorte: String,
        dia: String,
        substituindo anterior: ExportFormato? = nil,
        nomeAtual: String = "")
    {
        panel.allowedContentTypes = formato.tiposPermitidos
        if let anterior {
            panel.nameFieldStringValue = ExportNome.aoTrocar(
                de: anterior, para: formato, nomeAtual: nomeAtual, recorte: recorte, dia: dia)
        } else {
            panel.nameFieldStringValue = ExportNome.padrao(formato: formato, recorte: recorte, dia: dia)
        }
    }

    /// Write off-main, then say what happened.
    ///
    /// The old path wrote with `try?` and told nobody. For a 90-line CSV that was survivable; for a
    /// folder of five artifacts a silent failure becomes "cadê meu arquivo?" with no way to answer. So
    /// success reveals the artifact in the Finder and failure raises the error on the dashboard's own
    /// window.
    private func escrever(_ data: DashboardData, formato: ExportFormato, em url: URL) {
        let versao = Self.versaoDoApp()
        // The task stays on the main actor and only *awaits* the off-main work, so `self` never
        // crosses an isolation boundary. Sending a `@MainActor` controller into a detached task is
        // what strict concurrency rejects — and rightly: the alert and the Finder call below are UI.
        Task { [weak self] in
            switch await Self.gravar(data, formato: formato, em: url, versaoDoApp: versao) {
            case let .gravado(destino): self?.revelar(destino)
            case let .falhou(mensagem): self?.relatarFalha(mensagem)
            }
        }
    }

    /// The outcome of a write, reduced to values that can cross actors.
    ///
    /// The error is carried as its message rather than as an `Error`: what the alert needs is the
    /// sentence, and a `Sendable` payload keeps the hop honest instead of papered over.
    private enum ResultadoDaExportacao: Sendable {
        case gravado(URL)
        case falhou(String)
    }

    /// Bytes and one `FileManager` call, off the main thread (anti-freeze invariant I1).
    private nonisolated static func gravar(
        _ data: DashboardData,
        formato: ExportFormato,
        em url: URL,
        versaoDoApp: String) async -> ResultadoDaExportacao
    {
        await Task.detached(priority: .utility) {
            do {
                return ResultadoDaExportacao.gravado(try PainelExport.escrever(
                    data, formato: formato, em: url, geradoEm: Date(), versaoDoApp: versaoDoApp))
            } catch {
                return ResultadoDaExportacao.falhou(error.localizedDescription)
            }
        }.value
    }

    private func revelar(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func relatarFalha(_ mensagem: String) {
        guard let window else { return }
        let alerta = NSAlert()
        alerta.alertStyle = .warning
        alerta.messageText = L("dashboard.export.failed")
        alerta.informativeText = mensagem
        // No explicit button: `NSAlert` supplies its own default, already localized by AppKit in every
        // language the system ships. Adding one would mean shipping a translation of "OK" to lose to
        // the system's.
        alerta.beginSheetModal(for: window)
    }

    /// `CFBundleShortVersionString`, for the provenance line inside the package.
    private static func versaoDoApp() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static func fileDateTag() -> String {
        let formatter = DateFormatter()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        scanTask?.cancel()
        scanTask = nil
        observacao?.cancel()
        observacao = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Bridges the `@Observable` `DashboardModel` into a `DashboardView`.
private struct DashboardRoot: View {
    @Bindable var model: DashboardModel
    let openSettings: @MainActor () -> Void

    var body: some View {
        DashboardView(
            state: model.state,
            atalho: model.atalho,
            isRefreshing: model.isRefreshing,
            selectPeriod: { model.selectPeriod($0) },
            selectRange: { model.onRangeChange?($0) },
            exportar: { model.onExport?() },
            openSettings: openSettings)
    }
}
