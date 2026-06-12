import Foundation
import os

/// Scans Claude Code's local JSONL session logs and estimates spend (EXB-1.7).
///
/// Anti-freeze (AC10/AC13): all file I/O (`FileManager.enumerator`, `FileHandle` reads) runs on the
/// actor's own executor, never the MainActor. Callers invoke `scan(...)` from
/// `Task.detached(priority: .background)` (see `LiveUsageProvider`).
///
/// Efficiency (AC2/AC4): a byte-level pre-filter skips lines that cannot carry assistant usage
/// before any JSON decode; an incremental byte-offset cache means a re-scan of an unchanged file
/// reads zero new bytes.
public actor CostScanner {
    /// Process-wide shared scanner so the offset / aggregate cache survives across refresh cycles.
    public static let shared = CostScanner()

    /// `UserDefaults` key for the incremental byte-offset cache (`[absolutePath: lastOffset]`, AC4).
    static let offsetsDefaultsKey = "costScanner.fileOffsets"
    /// `UserDefaults` key for the persisted per-`(day, model)` aggregate (incremental accumulation).
    static let aggregateDefaultsKey = "costScanner.aggregate"

    /// Max bytes we keep of a single line for pre-filter + decode. Claude tool outputs can be large;
    /// the usage block lives near the start of an assistant line, so a generous prefix suffices and
    /// bounds memory.
    static let maxLineBytes = 1024 * 1024

    /// Internal (not `private`) so the analytics extension (`CostScanner+Analytics.swift`) reuses the
    /// same injected `Pricing` — keeps analytics pricing deterministic in tests (`networkEnabled:
    /// false`) and consistent with the popover scan (EXB-3.2).
    let pricing: Pricing
    private let defaults: CostDefaults
    /// Internal (not `private`) so the analytics extension can reuse the injected `FileManager` for
    /// its file enumeration (EXB-3.2).
    let fileManager: FileManager
    private let log = Logger(subsystem: CoreLog.subsystem, category: "cost.scanner")

    public init(
        pricing: Pricing = Pricing(),
        defaults: CostDefaults = CostDefaults(),
        fileManager: FileManager = .default)
    {
        self.pricing = pricing
        self.defaults = defaults
        self.fileManager = fileManager
    }

    // MARK: - Public scan API

    /// Scan `directories` for Claude JSONL logs and produce a `ProviderCost` over the trailing
    /// `costDays` window. `now` is injected for deterministic day-bucketing in tests (AC9).
    ///
    /// When `directories` is `nil` the default Claude projects roots are used (AC1).
    public func scan(directories: [URL]? = nil, costDays: Int, now: Date = Date()) async -> ProviderCost {
        let roots = directories ?? Self.defaultDirectories(fileManager: self.fileManager)
        let window = max(1, costDays)

        var offsets = self.loadOffsets()
        // Per-(day, model) accumulator carried across incremental scans.
        var aggregate = self.loadAggregate()

        for root in roots {
            guard self.fileManager.fileExists(atPath: root.path) else { continue }
            let files = self.enumerateJSONLFiles(in: root)
            for file in files {
                let path = file.path
                let fileSize = self.fileSize(of: file)
                var startOffset = offsets[path] ?? 0
                // Truncation / rotation: file shrank → re-scan from 0 and drop its prior contribution.
                if fileSize < startOffset {
                    startOffset = 0
                }
                guard fileSize > startOffset else {
                    // Nothing new in this file (AC4: zero new bytes on an unchanged file).
                    offsets[path] = fileSize
                    continue
                }

                let parsed = await self.parseFile(at: file, startOffset: startOffset, now: now, window: window)
                for (key, totals) in parsed.totalsByKey {
                    aggregate[key, default: Aggregate()].add(totals)
                }
                offsets[path] = parsed.endOffset
            }
        }

        self.saveOffsets(offsets)
        self.saveAggregate(aggregate)

        return Self.makeProviderCost(from: aggregate, costDays: window, now: now)
    }

    // MARK: - Directory enumeration (T4 / AC1)

    /// The default Claude projects roots (AC1):
    ///  - `~/.claude/projects`
    ///  - `~/.config/claude/projects`
    ///  - `$CLAUDE_CONFIG_DIR/projects` (comma-separated paths supported)
    ///  - `~/.pi/agent/sessions` (only when present)
    static func defaultDirectories(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var roots: [URL] = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        {
            for part in env.split(separator: ",") {
                let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let url = URL(fileURLWithPath: raw)
                roots.append(
                    url.lastPathComponent == "projects"
                        ? url
                        : url.appendingPathComponent("projects", isDirectory: true))
            }
        }

        let piSessions = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        if fileManager.fileExists(atPath: piSessions.path) {
            roots.append(piSessions)
        }

        // De-duplicate while preserving order (env + defaults can overlap).
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Enumerate `.jsonl` files under `root`, recursively, skipping hidden files (AC1 / T3).
    private func enumerateJSONLFiles(in root: URL) -> [URL] {
        guard let enumerator = self.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    // MARK: - Per-file parse (AC2, AC3, AC6)

    private struct FileParseResult {
        var totalsByKey: [DayModelKey: Totals] = [:]
        var endOffset: Int64
    }

    /// Byte-aware key (used only within one parse pass) → the deduped row, with the row's byte
    /// offset so a later chunk overrides an earlier one (AC3, "higher offset wins").
    private struct DedupedRow {
        var offset: Int64
        var dayKey: DayModelKey
        var inputTokens: Int
        var outputTokens: Int
        var model: String
        var timestamp: Date
    }

    private func parseFile(at url: URL, startOffset: Int64, now: Date, window: Int) async -> FileParseResult {
        // Dedup map: "messageId:requestId" → the latest (highest-offset) chunk for that key (AC3).
        var keyed: [String: DedupedRow] = [:]
        var unkeyed: [DedupedRow] = []

        let endOffset: Int64
        do {
            endOffset = try Self.scanLines(
                fileURL: url,
                offset: startOffset,
                maxLineBytes: Self.maxLineBytes) { line, lineOffset in
                self.handleLine(line, lineOffset: lineOffset, now: now, window: window, keyed: &keyed, unkeyed: &unkeyed)
            }
        } catch {
            // AC12: never crash — skip the offending file, do not advance its offset.
            self.log.debug("scan failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return FileParseResult(totalsByKey: [:], endOffset: startOffset)
        }

        // Price the deduped rows and roll up per (day, model).
        var totalsByKey: [DayModelKey: Totals] = [:]
        let rows = keyed.values + unkeyed
        for row in rows {
            let price = await self.pricing.costPerToken(model: row.model)
            let cost = Double(row.inputTokens) * price.input + Double(row.outputTokens) * price.output
            totalsByKey[row.dayKey, default: Totals()].add(
                input: row.inputTokens,
                output: row.outputTokens,
                cost: cost)
        }

        return FileParseResult(totalsByKey: totalsByKey, endOffset: endOffset)
    }

    /// Pre-filter (AC2) + decode (AC3/AC6) for a single raw line.
    private func handleLine(
        _ line: Data,
        lineOffset: Int64,
        now: Date,
        window: Int,
        keyed: inout [String: DedupedRow],
        unkeyed: inout [DedupedRow])
    {
        guard !line.isEmpty else { return }
        // Byte-level pre-filter: skip without JSON decode unless both markers are present (AC2).
        guard line.containsAsciiSubsequence(Self.assistantMarker),
              line.containsAsciiSubsequence(Self.usageMarker)
        else { return }

        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return }

        let input = max(0, Self.toInt(usage["input_tokens"]))
        let output = max(0, Self.toInt(usage["output_tokens"]))
        guard input > 0 || output > 0 else { return }

        guard let tsText = obj["timestamp"] as? String,
              let timestamp = ISO8601Decoder.date(from: tsText)
        else { return }

        // Day bucket in the user's local time zone (AC9).
        let dayStart = Calendar.current.startOfDay(for: timestamp)
        // Window filter: keep only entries within the trailing `window` calendar days (inclusive).
        guard Self.isWithinWindow(dayStart: dayStart, now: now, days: window) else { return }

        let normalizedModel = Pricing.normalize(model)
        let dayKey = DayModelKey(day: dayStart, model: normalizedModel)
        let row = DedupedRow(
            offset: lineOffset,
            dayKey: dayKey,
            inputTokens: input,
            outputTokens: output,
            model: normalizedModel,
            timestamp: timestamp)

        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        if let messageId, let requestId {
            let key = "\(messageId):\(requestId)"
            // Higher byte offset wins — keep the last (cumulative) streaming chunk (AC3).
            if let existing = keyed[key], existing.offset > lineOffset { return }
            keyed[key] = row
        } else {
            // Older logs may omit IDs; treat each as distinct to avoid dropping usage.
            unkeyed.append(row)
        }
    }

    // MARK: - Aggregation → ProviderCost (AC6, AC7)

    static func makeProviderCost(from aggregate: [DayModelKey: Aggregate], costDays: Int, now: Date) -> ProviderCost {
        let todayStart = Calendar.current.startOfDay(for: now)

        var today = 0.0, todayTokens = 0
        var total = 0.0, totalTokens = 0
        var byModel: [ModelCostEntry] = []

        for (key, agg) in aggregate {
            guard Self.isWithinWindow(dayStart: key.day, now: now, days: costDays) else { continue }
            let tokens = agg.inputTokens + agg.outputTokens
            total += agg.cost
            totalTokens += tokens
            if key.day == todayStart {
                today += agg.cost
                todayTokens += tokens
            }
            byModel.append(ModelCostEntry(
                model: key.model,
                date: key.day,
                inputTokens: agg.inputTokens,
                outputTokens: agg.outputTokens,
                cost: agg.cost))
        }

        // Sort descending by cost (then by date desc, model asc) for a stable, useful submenu (AC8).
        byModel.sort {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.model < $1.model
        }

        return ProviderCost(
            today: today,
            last30Days: total,
            todayTokens: todayTokens,
            last30DaysTokens: totalTokens,
            byModel: byModel)
    }

    // MARK: - Day window helper

    /// `true` when `dayStart` is within the trailing `days` calendar days ending today (inclusive),
    /// in the user's local time zone (AC9).
    static func isWithinWindow(dayStart: Date, now: Date, days: Int) -> Bool {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        guard dayStart <= todayStart else { return false } // ignore future-dated rows
        guard let earliest = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: todayStart) else {
            return false
        }
        return dayStart >= earliest
    }

    // MARK: - Offset & aggregate persistence (AC4)

    private func loadOffsets() -> [String: Int64] {
        guard let raw = self.defaults.dictionary(forKey: Self.offsetsDefaultsKey) as? [String: NSNumber] else {
            return [:]
        }
        return raw.mapValues { $0.int64Value }
    }

    private func saveOffsets(_ offsets: [String: Int64]) {
        let bridged = offsets.mapValues { NSNumber(value: $0) }
        self.defaults.set(bridged as NSDictionary, forKey: Self.offsetsDefaultsKey)
    }

    private func loadAggregate() -> [DayModelKey: Aggregate] {
        guard let data = self.defaults.data(forKey: Self.aggregateDefaultsKey),
              let rows = try? JSONDecoder().decode([AggregateRow].self, from: data)
        else { return [:] }
        var result: [DayModelKey: Aggregate] = [:]
        for row in rows {
            let key = DayModelKey(day: Date(timeIntervalSince1970: row.day), model: row.model)
            result[key] = Aggregate(inputTokens: row.input, outputTokens: row.output, cost: row.cost)
        }
        return result
    }

    private func saveAggregate(_ aggregate: [DayModelKey: Aggregate]) {
        let rows = aggregate.map { key, agg in
            AggregateRow(
                day: key.day.timeIntervalSince1970,
                model: key.model,
                input: agg.inputTokens,
                output: agg.outputTokens,
                cost: agg.cost)
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        self.defaults.set(data, forKey: Self.aggregateDefaultsKey)
    }

    /// Reset the incremental caches — used by tests and a future "rescan" action.
    public func resetCaches() {
        self.defaults.removeObject(forKey: Self.offsetsDefaultsKey)
        self.defaults.removeObject(forKey: Self.aggregateDefaultsKey)
    }

    // MARK: - Constants

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let usageMarker = Array(#""usage""#.utf8)

    private static func toInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }
}

// MARK: - Aggregation value types

/// Key for per-`(day, model)` aggregation. `day` is start-of-day in the local time zone.
struct DayModelKey: Hashable, Sendable {
    let day: Date
    let model: String
}

/// Mutable per-`(day, model)` token + cost accumulator used during a single scan pass.
struct Totals {
    var inputTokens = 0
    var outputTokens = 0
    var cost = 0.0

    mutating func add(input: Int, output: Int, cost: Double) {
        self.inputTokens += input
        self.outputTokens += output
        self.cost += cost
    }
}

/// Persisted per-`(day, model)` accumulator (carries across incremental scans).
struct Aggregate {
    var inputTokens = 0
    var outputTokens = 0
    var cost = 0.0

    init(inputTokens: Int = 0, outputTokens: Int = 0, cost: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }

    mutating func add(_ totals: Totals) {
        self.inputTokens += totals.inputTokens
        self.outputTokens += totals.outputTokens
        self.cost += totals.cost
    }
}

/// Codable row for persisting `Aggregate` to `UserDefaults`.
private struct AggregateRow: Codable {
    let day: TimeInterval
    let model: String
    let input: Int
    let output: Int
    let cost: Double
}
