import Foundation

/// "What ate the week" (EXB-6.3): how the usage since the weekly window's last reset splits across
/// projects and across the main session vs. each sub-agent.
///
/// **It is a proportion, not a measurement.** Anthropic reports one weekly percentage; nothing in the
/// API says which project or agent consumed it. The split here weighs every assistant message by its
/// estimated API cost (the embedded price table — the best local proxy for how much quota a message
/// burns, because Opus burns more than Haiku for the same tokens) and hands each slice the matching
/// share of the percentage points actually consumed. The UI labels it "estimated proportion".
public struct WeeklyAttribution: Sendable, Equatable {
    /// One slice of the week.
    public struct Slice: Sendable, Equatable, Identifiable {
        public var id: String { self.name }
        public let name: String
        /// Estimated API cost of the slice, USD — the weight.
        public let weight: Double
        /// Tokens (input + output + cache) attributed to the slice.
        public let tokens: Int
        /// Fraction of the week's weight, 0–1.
        public let share: Double

        public init(name: String, weight: Double, tokens: Int, share: Double) {
            self.name = name
            self.weight = weight
            self.tokens = tokens
            self.share = share
        }

        /// The slice's part of `consumedPoints` (percentage points of the weekly window).
        public func points(of consumedPoints: Double) -> Double { self.share * consumedPoints }
    }

    /// The label the main session carries in the per-agent split.
    public static let mainAgentName = "principal"
    /// The label of a sub-agent whose name could not be recovered.
    public static let unnamedSubagentName = "subagente"

    /// First instant counted (reset − 7 days).
    public let since: Date
    public let byProject: [Slice]
    public let byAgent: [Slice]
    public let totalWeight: Double

    public var isEmpty: Bool { self.totalWeight <= 0 }

    public init(since: Date, byProject: [Slice], byAgent: [Slice], totalWeight: Double) {
        self.since = since
        self.byProject = byProject
        self.byAgent = byAgent
        self.totalWeight = totalWeight
    }

    /// Start of the current weekly window: `resetsAt − 7 days`.
    public static func windowStart(resetsAt: Date, windowMinutes: Int = 10_080) -> Date {
        resetsAt.addingTimeInterval(-TimeInterval(windowMinutes) * 60)
    }
}

/// Reads the JSONL transcripts for ``WeeklyAttribution``.
///
/// Stateless and synchronous (call it off the main actor). Files whose modification date is older
/// than `since` are skipped without opening — a week of history touches a handful of files, not the
/// archive.
public enum WeeklyAttributionScanner {
    public static func scan(
        directories: [URL]? = nil,
        since: Date,
        fileManager: FileManager = .default) -> WeeklyAttribution
    {
        let roots = directories ?? CostScanner.defaultDirectories(fileManager: fileManager)
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantFuture
                if modified >= since { files.append(url) }
            }
        }

        // One file per worker: a week here is ~170 files / ~1 GB, and the decode is the cost. Each
        // file dedups its own streamed chunks (the last, cumulative chunk wins); the merge keeps the
        // first file's copy of a key that appears in two files.
        let candidates = files
        let results = Results(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let url = candidates[index]
            let fileAgent = Self.subagentName(for: url, fileManager: FileManager())
            var keyed: [String: (offset: Int64, entry: Entry)] = [:]
            var loose: [Entry] = []
            _ = try? CostScanner.scanLines(
                fileURL: url, offset: 0, maxLineBytes: CostScanner.maxLineBytes) { line, offset in
                guard let parsed = Self.parse(line, since: since, fileAgent: fileAgent) else { return }
                if let key = parsed.key {
                    if let existing = keyed[key], existing.offset > offset { return }
                    keyed[key] = (offset, parsed.entry)
                } else {
                    loose.append(parsed.entry)
                }
            }
            let entries = keyed.mapValues(\.entry)
            results.store(index: index, keyed: entries, loose: loose)
        }
        var merged: [String: Entry] = [:]
        let (perFile, unkeyed) = results.snapshot()
        for map in perFile {
            for (key, entry) in map where merged[key] == nil { merged[key] = entry }
        }
        return Self.fold(Array(merged.values) + unkeyed, since: since)
    }

    /// Lock-guarded sink for the concurrent per-file parse.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var perFile: [[String: Entry]]
        private var loose: [Entry] = []

        init(count: Int) { self.perFile = Array(repeating: [:], count: count) }

        func store(index: Int, keyed: [String: Entry], loose: [Entry]) {
            self.lock.withLock {
                self.perFile[index] = keyed
                self.loose.append(contentsOf: loose)
            }
        }

        func snapshot() -> ([[String: Entry]], [Entry]) {
            self.lock.withLock { (self.perFile, self.loose) }
        }
    }

    // MARK: - Fold

    /// One priced message.
    struct Entry: Equatable {
        let project: String
        let agent: String
        let weight: Double
        let tokens: Int
    }

    static func fold(_ entries: [Entry], since: Date) -> WeeklyAttribution {
        let total = entries.reduce(0) { $0 + $1.weight }
        func slices(_ key: (Entry) -> String) -> [WeeklyAttribution.Slice] {
            var acc: [String: (weight: Double, tokens: Int)] = [:]
            for entry in entries {
                acc[key(entry), default: (0, 0)].weight += entry.weight
                acc[key(entry), default: (0, 0)].tokens += entry.tokens
            }
            return acc.map { name, value in
                WeeklyAttribution.Slice(
                    name: name,
                    weight: value.weight,
                    tokens: value.tokens,
                    share: total > 0 ? value.weight / total : 0)
            }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name < $1.name }
        }
        return WeeklyAttribution(
            since: since,
            byProject: slices(\.project),
            byAgent: slices(\.agent),
            totalWeight: total)
    }

    // MARK: - Line parsing

    static func parse(_ line: Data, since: Date, fileAgent: String?) -> (key: String?, entry: Entry)? {
        // Byte pre-filter, same markers as `CostScanner`: most lines are user/tool turns, and
        // decoding them all is where a week of transcripts (≈1 GB here) would spend its time.
        guard !line.isEmpty,
              line.containsAsciiSubsequence(Self.assistantMarker),
              line.containsAsciiSubsequence(Self.usageMarker),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let timestamp = CostScanner.analyticsTimestamp(stamp),
              timestamp >= since
        else { return nil }

        func int(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
        let input = int("input_tokens"), output = int("output_tokens")
        let cacheRead = int("cache_read_input_tokens"), cacheWrite = int("cache_creation_input_tokens")
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        let weight = Pricing.fallbackPrice(for: model)
            .cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)

        let isSidechain = (obj["isSidechain"] as? Bool) ?? false
        let agent = fileAgent ?? (isSidechain ? WeeklyAttribution.unnamedSubagentName : WeeklyAttribution.mainAgentName)

        let key: String? = {
            guard let id = message["id"] as? String, let request = obj["requestId"] as? String else { return nil }
            return "\(id):\(request)"
        }()
        return (key, Entry(
            project: CostScanner.projectName(fromCWD: obj["cwd"] as? String),
            agent: agent,
            weight: weight,
            tokens: input + output + cacheRead + cacheWrite))
    }

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let usageMarker = Array(#""usage""#.utf8)

    // MARK: - Sub-agent naming

    /// `nil` for a main-session file. For a file under `subagents/`, the agent's name: `agentType`
    /// (or `name`) from the sibling `.meta.json`, else `<name>` from `agent-<name>-<hash>.jsonl`,
    /// else the generic label.
    static func subagentName(for url: URL, fileManager: FileManager = .default) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let inSubagentsDir = url.pathComponents.contains("subagents")
        guard inSubagentsDir || stem.hasPrefix("agent-") else { return nil }

        let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
        if let data = fileManager.contents(atPath: meta.path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            for key in ["agentType", "name"] {
                if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty
                {
                    return value
                }
            }
        }
        return Self.nameFromFileStem(stem) ?? WeeklyAttribution.unnamedSubagentName
    }

    /// `agent-dev-fix-qa-1a2b3c4d5e6f7a8b` → `dev-fix-qa`; `agent-1a2b3c4d5e6f7a8b` → `nil`.
    static func nameFromFileStem(_ stem: String) -> String? {
        guard stem.hasPrefix("agent-") else { return nil }
        var parts = stem.dropFirst("agent-".count).split(separator: "-").map(String.init)
        guard parts.count >= 2, let last = parts.last,
              last.count >= 8, last.allSatisfy(\.isHexDigit)
        else { return nil }
        parts.removeLast()
        let name = parts.joined(separator: "-")
        return name.isEmpty ? nil : name
    }
}
