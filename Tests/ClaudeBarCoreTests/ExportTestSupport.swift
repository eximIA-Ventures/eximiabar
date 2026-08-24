import CryptoKit
import Foundation
@testable import ClaudeBarCore

/// Shared helpers for the export tests.
///
/// **Why these tests shell out.** The XLSX writer fails in a binary, opaque way — a schema mistake
/// surfaces as "we found a problem with some content", never as a useful message. A test written only
/// against the writer's own output would agree with the writer's own mistakes. So the gate runs the
/// bytes through parsers nobody here wrote: Info-ZIP for the container, openpyxl for the spreadsheet
/// and chart schema, Quick Look for Apple's own reader.
///
/// The `Process` calls live here, in the test target, on purpose. `Sources/ClaudeBarCore/Export/`
/// launches no subprocess at all — that is invariant I2, and it is checked by a grep of its own.
enum ExportTestSupport {
    /// The result of running a command line.
    struct CommandResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs `executable` with `arguments` and captures both streams.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a Python snippet, returning its stdout. `nil` when Python is not on this machine — the
    /// caller then skips rather than failing, so the suite stays green on a bare box.
    static func python(_ source: String) throws -> CommandResult? {
        guard let interpreter = pythonInterpreter else { return nil }
        let script = temporaryDirectory().appendingPathComponent("snippet.py")
        try Data(source.utf8).write(to: script)
        return try run(interpreter, [script.path])
    }

    /// The Python to run the gate scripts with.
    ///
    /// Resolved by **capability, not by path**: several interpreters coexist on a developer Mac and
    /// `/usr/bin/python3` — the first one any hardcoded list would find — is the system build, which
    /// carries no third-party packages. Picking it would silently skip the openpyxl gate on a machine
    /// where openpyxl is installed, which is the worst of both worlds: no coverage and no warning.
    static let pythonInterpreter: String? = {
        var candidates: [String] = []
        if let resolved = try? run("/usr/bin/env", ["which", "python3"]) , resolved.status == 0 {
            candidates.append(resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let existing = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        let withOpenpyxl = existing.first { path in
            (try? run(path, ["-c", "import openpyxl"]))?.status == 0
        }
        return withOpenpyxl ?? existing.first
    }()

    /// Whether `openpyxl` can be imported by the interpreter the tests would use.
    static func hasOpenpyxl() -> Bool {
        guard let result = try? python("import openpyxl") else { return false }
        return result.status == 0
    }

    /// Extracts `archive` with Info-ZIP into a fresh directory and returns it, so payloads can be
    /// compared as bytes. Reading them off `unzip -p`'s stdout would force them through a string and
    /// mangle anything that is not valid UTF-8.
    static func extract(_ archive: URL) throws -> URL {
        let destination = temporaryDirectory()
        let result = try run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", destination.path])
        guard result.status == 0 else {
            throw NSError(domain: "ExportTestSupport", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "unzip failed: \(result.standardOutput)\(result.standardError)",
            ])
        }
        return destination
    }

    /// A fresh directory under the system temporary area, removed by the OS, never inside the repo.
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eximiabar-export-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The fixed location of the sample workbook a human opens in Excel (EXB-6.3 AC3).
    ///
    /// Deliberately outside the repository: the working tree of this project is shared with other
    /// frontends, and a generated artifact there would show up in their `git status`.
    static let sampleWorkbookURL = URL(fileURLWithPath: "/tmp/eximiabar-export/amostra.xlsx")

    /// Lowercase hex SHA-256, for the determinism assertions.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
