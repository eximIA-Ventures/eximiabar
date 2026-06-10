import Foundation

/// Removes the `.jsonl` session-log artifacts that a `claude` probe writes under
/// `~/.claude/projects/<sanitized-workdir>/` so the isolated probe never accumulates history
/// on disk (AC5).
///
/// The project-directory naming mirrors the Claude CLI's own scheme (a sanitized + optionally
/// hashed form of the absolute workdir path) — copied from
/// `_reference_codexbar/.../ClaudeProbeSessionArtifactCleaner.swift` so the directory we clean is
/// exactly the one Claude wrote to.
public struct ClaudeProbeSessionArtifactCleaner: Sendable {
    private static let maxProjectDirectoryNameLength = 200
    private let log = CoreLog.logger(CoreLog.Category.cli)

    public init() {}

    /// Deletes `.jsonl` files created by the probe in the Claude project directory derived from
    /// `workdir`, then removes the directory if it is left empty.
    public func clean(
        workdir: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default)
    {
        let projectName = Self.claudeProjectDirectoryName(for: workdir)
        var visited = Set<String>()

        for root in Self.claudeConfigRoots(environment: environment, fileManager: fm) {
            let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
            let directory = projectsRoot.appendingPathComponent(projectName, isDirectory: true)
            guard visited.insert(directory.path).inserted else { continue }

            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for entry in entries where entry.pathExtension == "jsonl" {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                try? fm.removeItem(at: entry)
            }

            if (try? fm.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? fm.removeItem(at: directory)
            }
        }
    }

    // MARK: - Project directory naming (verbatim from reference)

    static func claudeProjectDirectoryName(for directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        let sanitized = String(path.utf16.map { codeUnit -> Character in
            switch codeUnit {
            case 48...57, 65...90, 97...122:
                Character(UnicodeScalar(codeUnit)!)
            default:
                "-"
            }
        })
        guard sanitized.count > Self.maxProjectDirectoryNameLength else { return sanitized }
        return "\(sanitized.prefix(Self.maxProjectDirectoryNameLength))-\(Self.jsHashBase36(path))"
    }

    private static func jsHashBase36(_ string: String) -> String {
        var hash: Int32 = 0
        for codeUnit in string.utf16 {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: codeUnit)
        }
        let magnitude = hash < 0 ? -Int64(hash) : Int64(hash)
        return String(magnitude, radix: 36)
    }

    private static func claudeConfigRoots(
        environment: [String: String],
        fileManager fm: FileManager) -> [URL]
    {
        var roots: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            roots.append(standardized)
        }

        if let raw = environment["CLAUDE_CONFIG_DIR"] {
            for part in raw.split(separator: ",") {
                let path = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                append(URL(fileURLWithPath: path))
            }
        }

        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        append(URL(fileURLWithPath: home).appendingPathComponent(".claude", isDirectory: true))
        append(URL(fileURLWithPath: home).appendingPathComponent(".config/claude", isDirectory: true))

        if roots.isEmpty {
            append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true))
        }
        return roots
    }
}
