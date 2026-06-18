import Foundation
import os

extension CostScanner {
    /// Signpost handle for the dashboard's heavy paths (EXB-3.6 AC8). Categorised `"DashboardPerf"`
    /// so Instruments' "Points of Interest" / `log stream` can isolate the analytics scan from the
    /// rest of the app. Static + `nonisolated` so both the actor and the MainActor controller emit
    /// into the same stream.
    public nonisolated static let perfSignposter = OSSignposter(
        logHandle: OSLog(subsystem: CoreLog.subsystem, category: "DashboardPerf"))
    /// Scan the Claude JSONL logs and produce the rich `UsageAnalytics` the EXB-3.2 dashboard needs:
    /// per-`(day, model)` rows with the cache-token split, per-project totals, a weekday × hour
    /// heatmap, and the top sessions.
    ///
    /// This intentionally does **not** use the popover's incremental offset cache. The persisted
    /// `Aggregate` only carries `(day, model)` totals — it lacks hour-of-day, project, session, and
    /// the cache-token split the analytics views require. So `scanAnalytics` runs a fresh full-window
    /// scan over the same byte pipeline (`scanLines` + the pre-filter), reusing all of the existing
    /// parsing logic; no JSONL parsing is duplicated. The dashboard's own in-memory cache (EXB-3.2 T3)
    /// guards against re-scanning the same period while the window is open, so the cost is paid once
    /// per period per open.
    ///
    /// Anti-freeze: runs on this actor's executor (callers invoke from `Task.detached`), never the
    /// MainActor. `now` is injected for deterministic bucketing in tests.
    /// Resolve the base `(input, output)` per-token USD prices for `model` on the scanner's injected
    /// `Pricing` actor (EXB-4.5 AC1/AC4). Used by the dashboard to estimate cache savings from the
    /// dominant model's prices without ever touching `Pricing` from the MainActor or hardcoding a
    /// per-model price in the view. Never throws — `Pricing` always returns a usable price.
    public func modelPrice(for model: String) async -> (input: Double, output: Double) {
        await self.pricing.costPerToken(model: model)
    }

    public func scanAnalytics(
        directories: [URL]? = nil,
        windowDays: Int,
        now: Date = Date()) async -> UsageAnalytics
    {
        let signposter = Self.perfSignposter
        let scanID = signposter.makeSignpostID()
        let scanState = signposter.beginInterval("scanAnalytics", id: scanID, "window=\(windowDays)d")
        defer { signposter.endInterval("scanAnalytics", scanState) }

        let roots = directories ?? Self.defaultDirectories(fileManager: self.fileManager)
        let window = max(1, windowDays)

        var rows: [AnalyticsRow] = []
        var scannedFiles = 0
        var skippedFiles = 0
        for root in roots {
            guard self.fileManager.fileExists(atPath: root.path) else { continue }
            for file in self.analyticsJSONLFiles(in: root, window: window, now: now) {
                guard file.inWindow else { skippedFiles += 1; continue }
                scannedFiles += 1
                rows.append(contentsOf: await self.parseAnalyticsFile(at: file.url, now: now, window: window))
            }
        }
        signposter.emitEvent("scanAnalytics.files", id: scanID, "scanned=\(scannedFiles) skipped=\(skippedFiles)")

        let aggregateState = signposter.beginInterval("makeAnalytics", id: scanID, "rows=\(rows.count)")
        let analytics = self.makeAnalytics(from: rows, window: window, now: now)
        signposter.endInterval("makeAnalytics", aggregateState)
        return analytics
    }

    // MARK: - File enumeration (mirrors the popover scan, exposed for analytics)

    /// A JSONL file paired with whether its modification date places it inside the scan window
    /// (EXB-3.6 BUG 2 root cause). A file last written before the window's earliest day cannot hold a
    /// single in-window entry, so it is read zero bytes. On a 1 GB / ~2 000-file history this turns a
    /// ~22 s full read into a fraction of it for the common 7 d / 30 d windows.
    struct AnalyticsFile {
        let url: URL
        let inWindow: Bool
    }

    /// Earliest instant a file may have been modified and still carry an in-window entry: the start
    /// of the window's first day, minus one day of slop to absorb time-zone / clock skew between the
    /// log's wall-clock timestamps and the filesystem's modification date. Conservative on purpose —
    /// we would rather scan a file needlessly than ever drop a real entry.
    static func windowFileFloor(window: Int, now: Date, calendar: Calendar = .current) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let earliestDay = calendar.date(byAdding: .day, value: -(max(1, window) - 1), to: todayStart) ?? todayStart
        return calendar.date(byAdding: .day, value: -1, to: earliestDay) ?? earliestDay
    }

    private func analyticsJSONLFiles(in root: URL, window: Int, now: Date) -> [AnalyticsFile] {
        guard let enumerator = self.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        let floor = Self.windowFileFloor(window: window, now: now)
        var files: [AnalyticsFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // mtime pre-filter: keep files modified on/after the floor; mark the rest out-of-window so
            // the caller skips them without opening a FileHandle. A missing mtime → scan (fail-open).
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let inWindow = modified.map { $0 >= floor } ?? true
            files.append(AnalyticsFile(url: url, inWindow: inWindow))
        }
        return files
    }

    // MARK: - Per-file parse (reuses the byte pipeline + pre-filter)

    private func parseAnalyticsFile(at url: URL, now: Date, window: Int) async -> [AnalyticsRow] {
        // Dedup streaming chunks the same way the popover scan does: "messageId:requestId" → latest
        // (highest byte-offset) chunk; older logs without IDs are treated as distinct rows.
        var keyed: [String: AnalyticsRow] = [:]
        var unkeyed: [AnalyticsRow] = []
        // Fallback session label when the JSONL omits `sessionId`: the file's basename without ext.
        let fileSession = url.deletingPathExtension().lastPathComponent

        do {
            try Self.scanLines(fileURL: url, offset: 0, maxLineBytes: Self.analyticsMaxLineBytes) { line, lineOffset in
                self.handleAnalyticsLine(
                    line,
                    lineOffset: lineOffset,
                    fileSession: fileSession,
                    now: now,
                    window: window,
                    keyed: &keyed,
                    unkeyed: &unkeyed)
            }
        } catch {
            // Never crash on a bad file — skip it (mirrors the popover scan's tolerance).
            return []
        }

        var out = Array(keyed.values)
        out.append(contentsOf: unkeyed)

        // Price each deduped row on the scanner's injected pricing actor (deterministic in tests).
        for index in out.indices {
            let row = out[index]
            let price = await self.pricing.costPerToken(model: row.model)
            // Cache-read is far cheaper and cache-write slightly dearer than base input, but exímIABar
            // prices on the base input/output table (EXB-1.7). Keep parity with the popover scan:
            // cost = input * inputPrice + output * outputPrice. Cache tokens are surfaced as volume
            // (heatmap / stacked chart / project totals) but not separately repriced, matching the
            // popover's `ProviderCost`.
            out[index].cost = Double(row.inputTokens) * price.input + Double(row.outputTokens) * price.output
        }
        return out
    }

    private func handleAnalyticsLine(
        _ line: Data,
        lineOffset: Int64,
        fileSession: String,
        now: Date,
        window: Int,
        keyed: inout [String: AnalyticsRow],
        unkeyed: inout [AnalyticsRow])
    {
        guard !line.isEmpty else { return }
        // Same byte-level pre-filter as the popover scan (skip without JSON decode).
        guard line.containsAsciiSubsequence(Self.analyticsAssistantMarker),
              line.containsAsciiSubsequence(Self.analyticsUsageMarker)
        else { return }

        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return }

        let input = max(0, Self.analyticsInt(usage["input_tokens"]))
        let output = max(0, Self.analyticsInt(usage["output_tokens"]))
        let cacheRead = max(0, Self.analyticsInt(usage["cache_read_input_tokens"]))
        let cacheWrite = max(0, Self.analyticsInt(usage["cache_creation_input_tokens"]))
        guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }

        guard let tsText = obj["timestamp"] as? String,
              let timestamp = ISO8601Decoder.date(from: tsText)
        else { return }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: timestamp)
        guard Self.isWithinWindow(dayStart: dayStart, now: now, days: window) else { return }

        let normalizedModel = Pricing.normalize(model)
        // Project from the entry's `cwd` (top-level field), falling back to "Unknown" (AC6).
        let project = Self.projectName(fromCWD: obj["cwd"] as? String)
        // Session from `sessionId` (top-level), falling back to the file basename (AC8).
        let sessionId = (obj["sessionId"] as? String)
            ?? (obj["session_id"] as? String)
            ?? fileSession

        let row = AnalyticsRow(
            offset: lineOffset,
            day: dayStart,
            timestamp: timestamp,
            weekday: cal.component(.weekday, from: timestamp) - 1, // 0 = Sun … 6 = Sat
            hour: cal.component(.hour, from: timestamp),
            model: normalizedModel,
            project: project,
            sessionId: sessionId,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            cost: 0)

        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        if let messageId, let requestId {
            let key = "\(messageId):\(requestId)"
            if let existing = keyed[key], existing.offset > lineOffset { return }
            keyed[key] = row
        } else {
            unkeyed.append(row)
        }
    }

    // MARK: - Aggregation → UsageAnalytics

    private func makeAnalytics(from rows: [AnalyticsRow], window: Int, now: Date) -> UsageAnalytics {
        let cal = Calendar.current

        // --- Per-(day, model) rows with cache split ---
        var dayModel: [DayModelKey: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cost: Double)] = [:]
        // --- Per-project totals ---
        var project: [String: (cost: Double, tokens: Int)] = [:]
        // --- Heatmap 7 × 24 token volume ---
        var heat = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        // --- Per-session accumulators ---
        var session: [String: SessionAccumulator] = [:]
        // --- Month-to-date spend (run-rate numerator) ---
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        var monthToDate = 0.0

        for row in rows {
            let allTokens = row.inputTokens + row.outputTokens + row.cacheReadTokens + row.cacheWriteTokens

            let key = DayModelKey(day: row.day, model: row.model)
            dayModel[key, default: (0, 0, 0, 0, 0)].input += row.inputTokens
            dayModel[key]!.output += row.outputTokens
            dayModel[key]!.cacheRead += row.cacheReadTokens
            dayModel[key]!.cacheWrite += row.cacheWriteTokens
            dayModel[key]!.cost += row.cost

            project[row.project, default: (0, 0)].cost += row.cost
            project[row.project]!.tokens += allTokens

            if row.weekday >= 0, row.weekday < 7, row.hour >= 0, row.hour < 24 {
                heat[row.weekday][row.hour] += allTokens
            }

            session[row.sessionId, default: SessionAccumulator(project: row.project, firstDate: row.timestamp)]
                .add(row: row, allTokens: allTokens)

            if row.timestamp >= monthStart, row.timestamp <= now {
                monthToDate += row.cost
            }
        }

        // Build per-(day, model) entries, sorted by cost desc (then date desc, model asc).
        let byDayModel = dayModel
            .map { key, t in
                ModelCostEntry(
                    model: key.model,
                    date: key.day,
                    inputTokens: t.input,
                    outputTokens: t.output,
                    cacheReadTokens: t.cacheRead,
                    cacheWriteTokens: t.cacheWrite,
                    cost: t.cost)
            }
            .sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.model < $1.model
            }

        let byProject = project
            .map { name, t in ProjectUsageEntry(project: name, costUSD: t.cost, totalTokens: t.tokens) }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.project < $1.project }

        var heatmap = UsageAnalytics.emptyHeatmap()
        for weekday in 0..<7 {
            for hour in 0..<24 {
                heatmap[weekday][hour] = HeatmapBucket(weekday: weekday, hour: hour, tokens: heat[weekday][hour])
            }
        }

        let topSessions = session
            .map { id, acc in acc.entry(sessionId: id) }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.date > $1.date }
            .prefix(10)
            .map { $0 }

        return UsageAnalytics(
            byDayModel: byDayModel,
            byProject: byProject,
            heatmap: heatmap,
            topSessions: topSessions,
            monthToDateCost: monthToDate)
    }

    // MARK: - Source fingerprint (dashboard cache invalidation, AC12)

    /// A cheap fingerprint of the Claude source directories: each existing root's path + content
    /// modification date. The dashboard compares this between scans to decide whether its per-period
    /// cache is still valid (new sessions written → fingerprint changes → cache invalidated). Uses
    /// directory mtimes only — no file enumeration — so it is fast even on a 90-day history.
    public static func sourceFingerprint(
        directories: [URL]? = nil,
        fileManager: FileManager = .default) -> String
    {
        let roots = directories ?? Self.defaultDirectories(fileManager: fileManager)
        var parts: [String] = []
        for root in roots {
            guard let attrs = try? fileManager.attributesOfItem(atPath: root.path),
                  let modified = attrs[.modificationDate] as? Date
            else { continue }
            parts.append("\(root.path):\(modified.timeIntervalSince1970)")
        }
        return parts.sorted().joined(separator: "|")
    }

    // MARK: - Project derivation (AC6)

    /// Derive a display project name from a session `cwd`: the last path component, or "Unknown".
    static func projectName(fromCWD cwd: String?) -> String {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Unknown" : name
    }

    // MARK: - Constants (analytics-local to avoid touching the popover scanner's privates)

    static let analyticsMaxLineBytes = 1024 * 1024
    private static let analyticsAssistantMarker = Array(#""type":"assistant""#.utf8)
    private static let analyticsUsageMarker = Array(#""usage""#.utf8)

    private static func analyticsInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }
}

// MARK: - Analytics intermediate value types

/// One priced, deduped assistant entry — the unit the analytics aggregation folds over.
struct AnalyticsRow {
    let offset: Int64
    let day: Date
    let timestamp: Date
    let weekday: Int
    let hour: Int
    let model: String
    let project: String
    let sessionId: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    var cost: Double
}

/// Mutable per-session accumulator used while building `topSessions`.
private struct SessionAccumulator {
    let project: String
    var firstDate: Date
    var totalTokens = 0
    var totalCost = 0.0
    /// Cost contributed per model — the max determines the session's `dominantModel`.
    var costByModel: [String: Double] = [:]

    init(project: String, firstDate: Date) {
        self.project = project
        self.firstDate = firstDate
    }

    mutating func add(row: AnalyticsRow, allTokens: Int) {
        if row.timestamp < self.firstDate { self.firstDate = row.timestamp }
        self.totalTokens += allTokens
        self.totalCost += row.cost
        self.costByModel[row.model, default: 0] += row.cost
    }

    func entry(sessionId: String) -> SessionUsageEntry {
        let dominant = self.costByModel
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?
            .key ?? "—"
        return SessionUsageEntry(
            sessionId: sessionId,
            date: self.firstDate,
            project: self.project,
            dominantModel: dominant,
            totalTokens: self.totalTokens,
            costUSD: self.totalCost)
    }
}
