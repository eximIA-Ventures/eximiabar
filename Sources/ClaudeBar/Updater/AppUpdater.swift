import AppKit
import ClaudeBarCore
import Foundation

/// Downloads, extracts, validates, installs and relaunches a new build (EXB-2.4 AC5–AC9).
///
/// An `actor` so the multi-step pipeline is serialized and its (off-main-thread) work never races.
/// It performs **zero** UI work — the ``UpdateViewModel`` hops to `MainActor` to publish progress.
/// Every blocking subprocess (`ditto`, `chmod`, `codesign`) runs on a dedicated `Thread` bridged
/// back via a single-resume `CheckedContinuation`, exactly like ``ClaudeBarCore/ClaudePTYRunner`` —
/// NEVER on Swift's cooperative pool (freeze root cause #3 from the epic).
///
/// `URLSession.download(from:)` is already `async`; it runs on the cooperative pool, not the main
/// thread, so the download itself needs no extra bridging.
public actor AppUpdater {
    /// The app-bundle directory name produced by packaging (`Makefile` `APP_NAME`).
    static let appBundleName = "ExímIABar.app"
    /// The Mach-O executable inside the bundle (`Info.plist` `CFBundleExecutable`).
    static let executableName = "ClaudeBar"

    private let log = CoreLog.logger(CoreLog.Category.cli)

    /// Progress callback signature: called on a background context with a 0…1 fraction (or `nil`
    /// for indeterminate). The view model forwards these to `@MainActor`.
    public typealias ProgressHandler = @Sendable (Double?) -> Void

    public init() {}

    // MARK: - Public pipeline (AC5 → AC9)

    /// Run the full download→extract→validate→install→relaunch pipeline.
    ///
    /// - Parameters:
    ///   - release: the target release resolved by ``UpdateChecker``.
    ///   - onProgress: invoked with the download fraction (`nil` when length is unknown).
    /// - Throws: ``UpdateError`` for any failed step. On success this never returns normally — it
    ///   relaunches the app and calls `NSApp.terminate`.
    public func downloadAndInstall(
        release: ReleaseInfo,
        onProgress: @escaping ProgressHandler) async throws
    {
        // AC8 (pre-flight): fail fast if we cannot write where the app currently lives, before
        // spending bandwidth on a download we could never install.
        let installURL = try Self.runningAppURL()
        guard Self.parentIsWritable(of: installURL) else {
            throw UpdateError.notWritable
        }

        // Step 1 — download the zip to a temp dir (AC5).
        let zipURL = try await download(from: release.downloadURL, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        // Step 2 — extract via `ditto` on a dedicated thread (AC6).
        let extractDir = try Self.makeTempDirectory(prefix: "eximiabar-extract")
        try await Self.runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipURL.path, extractDir.path],
            failure: .extractionFailed)

        // Step 3 — locate + validate the extracted bundle (AC6/AC7).
        let extractedApp = try Self.locateExtractedApp(in: extractDir)
        try Self.validateBundle(at: extractedApp)

        // Step 4–5 — install: remove old, move new, chmod, re-codesign ad-hoc (AC8).
        try await install(extractedApp: extractedApp, to: installURL)
        try? FileManager.default.removeItem(at: extractDir)

        // Step 6 — relaunch the freshly installed app, then terminate (AC9).
        await relaunch(installedAt: installURL)
    }

    // MARK: - Step 1: download (AC5)

    private func download(
        from url: URL,
        onProgress: @escaping ProgressHandler) async throws -> URL
    {
        onProgress(nil) // indeterminate until/unless we observe Content-Length
        let tempURL: URL
        do {
            // `URLSession.download(from:)` is async + off-main; acceptable for typical < 20 MB
            // release zips (AC5 / Dev Notes "indeterminate is acceptable").
            let (downloaded, _) = try await URLSession.shared.download(from: url)
            tempURL = downloaded
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost, .timedOut:
                throw UpdateError.noNetwork
            default:
                throw UpdateError.noNetwork
            }
        }

        onProgress(1.0)
        // Move the session's temp file into a directory we own and name it `.zip` so `ditto`
        // recognises the archive format.
        let workDir = try Self.makeTempDirectory(prefix: "eximiabar-download")
        let zipURL = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tempURL, to: zipURL)
        return zipURL
    }

    // MARK: - Step 3: locate + validate (AC6 / AC7)

    /// Find `ExímIABar.app` somewhere under `extractDir` (it may be at the root or nested).
    private static func locateExtractedApp(in extractDir: URL) throws -> URL {
        let fm = FileManager.default
        let direct = extractDir.appendingPathComponent(appBundleName)
        if fm.fileExists(atPath: direct.path) { return direct }

        // Fall back to a shallow scan for any `*.app` (e.g. archives that nest under a folder).
        if let entries = try? fm.contentsOfDirectory(
            at: extractDir, includingPropertiesForKeys: nil)
        {
            for entry in entries where entry.pathExtension == "app" {
                return entry
            }
            for entry in entries {
                let nested = entry.appendingPathComponent(appBundleName)
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }
        throw UpdateError.invalidBundle
    }

    /// AC7: confirm `Contents/MacOS/ClaudeBar` exists and is executable.
    private static func validateBundle(at appURL: URL) throws {
        let executable = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: executable.path),
              fm.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidBundle
        }
    }

    // MARK: - Step 4–5: install (AC8)

    private func install(extractedApp: URL, to installURL: URL) async throws {
        let fm = FileManager.default

        // a. Remove the existing .app at the install path.
        if fm.fileExists(atPath: installURL.path) {
            do {
                try fm.removeItem(at: installURL)
            } catch {
                throw UpdateError.installFailed("remove existing app: \(error.localizedDescription)")
            }
        }

        // b. Move (fall back to copy) the new .app into place.
        do {
            try fm.moveItem(at: extractedApp, to: installURL)
        } catch {
            do {
                try fm.copyItem(at: extractedApp, to: installURL)
            } catch {
                throw UpdateError.installFailed("move new app: \(error.localizedDescription)")
            }
        }

        // c. chmod -R +x so the executable bit survives extraction edge cases.
        try await Self.runProcess(
            executable: "/bin/chmod",
            arguments: ["-R", "+x", installURL.path],
            failure: .installFailed("chmod failed"))

        // d. Re-codesign ad-hoc (AC8d) — replaces any invalidated signature after the move.
        try await Self.runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--deep", "--timestamp=none", installURL.path],
            failure: .installFailed("codesign failed"))
    }

    // MARK: - Step 6: relaunch (AC9)

    @MainActor
    private func relaunch(installedAt installURL: URL) {
        // Detached shell: sleep 1s (let this process die cleanly), then `open` the new bundle.
        let path = installURL.path
        let script = "sleep 1 && open -a \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        // Fire-and-forget; the child outlives us. If it cannot launch, there is nothing left to do
        // but terminate — the user can relaunch manually.
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Writable-location check (AC8 / AC10 / T5)

    /// The bundle URL of the currently running app.
    static func runningAppURL() throws -> URL {
        Bundle.main.bundleURL
    }

    /// AC8/AC10: is the directory that *contains* the app writable?
    static func parentIsWritable(of appURL: URL) -> Bool {
        let parent = appURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    // MARK: - Subprocess bridge (Thread + CheckedContinuation — PTYRunner pattern)

    /// Run a subprocess to completion on a **dedicated `Thread`**, bridging back via a single-resume
    /// `CheckedContinuation`. `Process.waitUntilExit()` blocks; running it here keeps it off both
    /// `MainActor` and the cooperative pool (epic anti-freeze rule).
    private static func runProcess(
        executable: String,
        arguments: [String],
        failure: UpdateError) async throws
    {
        let result: Result<Void, UpdateError> = await withCheckedContinuation { continuation in
            let thread = Thread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = nil
                process.standardError = nil
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        continuation.resume(returning: .failure(failure))
                    }
                } catch {
                    continuation.resume(returning: .failure(failure))
                }
            }
            thread.name = "com.eximia.eximiabar.updater-proc"
            thread.stackSize = 1 << 20
            thread.start()
        }
        if case let .failure(error) = result {
            throw error
        }
    }

    // MARK: - Temp helpers

    private static func makeTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
