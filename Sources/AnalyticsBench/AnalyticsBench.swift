import ClaudeBarCore
import Foundation

/// Wall-clock benchmark for `CostScanner.scanAnalytics(windowDays:)` — the dashboard's heavy path.
///
/// WHY THIS EXISTS: the Dashboard panel is slow to open and slow to switch periods (7d / 30d / 90d).
/// This target is the **verifier** for that work: it measures the real thing, against the real
/// `~/.claude/projects` history, from outside the code being optimised. What it measures (wall time
/// per window, cold vs. warm, files and bytes admitted by the mtime pre-filter) is the rubric, and it
/// does not change while the scanner is being reworked.
///
/// It deliberately does **not** import any internals: it only calls the public `scanAnalytics` API
/// and computes its own file/byte census by walking the directories itself. If the scanner starts
/// lying about how much it reads, this target still tells the truth.
///
/// Usage:
///   swift run --arch arm64 AnalyticsBench            # cold + warm passes over the real history
///   swift run --arch arm64 AnalyticsBench --cold-only # a single cold pass per window
///
/// Pricing is pinned to the offline fallback table so no network call pollutes the timing, and each
/// run gets a private `UserDefaults` suite so a "cold" pass really is cold.
@main
enum AnalyticsBench {
    static func main() async {
        let arguments = CommandLine.arguments
        let coldOnly = arguments.contains("--cold-only")
        let windows = [7, 30, 90]

        // `--dump <window> --dir <path>`: print a canonical, line-oriented rendering of the whole
        // `UsageAnalytics` for a frozen corpus. Running this from two builds and diffing the output
        // is how the rewrite is checked against the *real* logs, not only against fixtures.
        if let dumpIndex = arguments.firstIndex(of: "--dump") {
            let window = Int(arguments[safe: dumpIndex + 1] ?? "") ?? 30
            guard let dirIndex = arguments.firstIndex(of: "--dir"),
                  let path = arguments[safe: dirIndex + 1]
            else {
                print("error: --dump requires --dir <path>")
                exit(1)
            }
            // `--now <epoch>` pins the scan instant identically across the two builds, so a diff
            // cannot be an artefact of the two processes starting seconds apart.
            var now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            if let nowIndex = arguments.firstIndex(of: "--now"),
               let epoch = Double(arguments[safe: nowIndex + 1] ?? "")
            {
                now = Date(timeIntervalSince1970: epoch)
            }
            await dump(directory: URL(fileURLWithPath: path), window: window, now: now)
            return
        }

        print("=== AnalyticsBench — scanAnalytics wall-clock ===")
        print("host: \(ProcessInfo.processInfo.activeProcessorCount) cores")

        census(for: windows)

        // A private suite per process run: the persisted incremental caches (if any) start empty, so
        // the first pass is a genuine cold scan.
        let suiteName = "analyticsbench.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            print("error: could not create a scratch UserDefaults suite")
            exit(1)
        }
        defer { store.removePersistentDomain(forName: suiteName) }

        let defaults = CostDefaults(store)
        let pricing = Pricing(defaults: defaults, networkEnabled: false)
        let scanner = CostScanner(pricing: pricing, defaults: defaults)

        print("\n--- COLD (empty caches, one scanner instance, windows in order) ---")
        for window in windows {
            let start = DispatchTime.now().uptimeNanoseconds
            let analytics = await scanner.scanAnalytics(windowDays: window)
            report(window: window, seconds: elapsed(since: start), analytics: analytics)
        }

        guard !coldOnly else { return }

        print("\n--- WARM (same scanner, caches populated by the cold pass) ---")
        for window in windows {
            let start = DispatchTime.now().uptimeNanoseconds
            let analytics = await scanner.scanAnalytics(windowDays: window)
            report(window: window, seconds: elapsed(since: start), analytics: analytics)
        }

        // The incremental cache buys speed with a persisted blob; its size is a real cost and worth
        // reporting next to the times it bought.
        if let blob = store.data(forKey: "costScanner.analyticsCache") {
            print(String(format: "\npersisted analytics cache: %.2f MB", Double(blob.count) / 1024 / 1024))
        }

        print("\n--- WARM, fresh scanner instance (persisted cache only, no in-memory state) ---")
        let reopened = CostScanner(pricing: Pricing(defaults: defaults, networkEnabled: false), defaults: defaults)
        for window in windows {
            let start = DispatchTime.now().uptimeNanoseconds
            let analytics = await reopened.scanAnalytics(windowDays: window)
            report(window: window, seconds: elapsed(since: start), analytics: analytics)
        }
    }

    // MARK: - Canonical dump (cross-build equivalence check)

    /// Print every field of `UsageAnalytics` in a stable, sorted, line-oriented form.
    ///
    /// Sections are separated so a diff points straight at *which* view disagrees — a change in the
    /// session table reads very differently from a change in the day/model totals.
    private static func dump(directory: URL, window: Int, now: Date) async {
        let suiteName = "analyticsbench.dump.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else { exit(1) }
        defer { store.removePersistentDomain(forName: suiteName) }
        let defaults = CostDefaults(store)
        let scanner = CostScanner(
            pricing: Pricing(defaults: defaults, networkEnabled: false),
            defaults: defaults)

        let analytics = await scanner.scanAnalytics(directories: [directory], windowDays: window, now: now)

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        let instant = ISO8601DateFormatter()
        instant.formatOptions = [.withInternetDateTime]
        instant.timeZone = TimeZone(secondsFromGMT: 0)

        print("## byDayModel")
        for entry in analytics.byDayModel
            .map({ String(
                format: "%@|%@|%ld|%ld|%ld|%ld|%.6f",
                day.string(from: $0.date), $0.model, $0.inputTokens, $0.outputTokens,
                $0.cacheReadTokens, $0.cacheWriteTokens, $0.cost) })
            .sorted() { print(entry) }

        print("## byProject")
        for entry in analytics.byProject
            .map({ String(format: "%@|%.6f|%ld", $0.project, $0.costUSD, $0.totalTokens) })
            .sorted() { print(entry) }

        print("## heatmap")
        for bucket in analytics.heatmap.flatMap({ $0 }).filter({ $0.tokens > 0 })
            .map({ String(format: "%ld:%ld|%ld", $0.weekday, $0.hour, $0.tokens) })
            .sorted() { print(bucket) }

        print("## topSessions")
        for entry in analytics.topSessions
            .map({ String(
                format: "%@|%@|%@|%@|%ld|%.6f",
                $0.sessionId, instant.string(from: $0.date), $0.project, $0.dominantModel,
                $0.totalTokens, $0.costUSD) })
            .sorted() { print(entry) }

        print("## monthToDate")
        print(String(format: "%.6f", analytics.monthToDateCost))
    }

    // MARK: - Timing

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func report(window: Int, seconds: Double, analytics: UsageAnalytics) {
        let cost = analytics.byDayModel.reduce(0) { $0 + $1.cost }
        let tokens = analytics.byDayModel.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens
        }
        // `%d` in `String(format:)` is 32-bit — token volumes overflow it. `%ld` for every Int.
        print(String(
            format: "%3ldd  %8.3f s   rows=%-6ld projects=%-4ld sessions=%-3ld tokens=%-14ld cost=$%.2f",
            window, seconds, analytics.byDayModel.count, analytics.byProject.count,
            analytics.topSessions.count, tokens, cost))
    }

    // MARK: - Independent file/byte census (does not use scanner internals)

    /// Count the `.jsonl` files and bytes each window's mtime pre-filter would admit, walking the same
    /// default roots the scanner uses. Mirrors the scanner's floor (window start minus one day of
    /// slop) without calling into it — an independent second opinion on the I/O the scan faces.
    private static func census(for windows: [Int]) {
        let roots = defaultRoots()
        print("roots: \(roots.map(\.path).joined(separator: ", "))")

        var files: [(mtime: Date, size: Int64)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((
                    values?.contentModificationDate ?? .distantPast,
                    Int64(values?.fileSize ?? 0)))
            }
        }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        print(String(format: "total: %d files, %.2f GB", files.count, gb(totalBytes)))

        let calendar = Calendar.current
        let now = Date()
        for window in windows {
            let todayStart = calendar.startOfDay(for: now)
            let earliest = calendar.date(byAdding: .day, value: -(window - 1), to: todayStart) ?? todayStart
            let floor = calendar.date(byAdding: .day, value: -1, to: earliest) ?? earliest
            let admitted = files.filter { $0.mtime >= floor }
            let bytes = admitted.reduce(Int64(0)) { $0 + $1.size }
            print(String(format: "  %3dd pre-filter admits %d files, %.2f GB", window, admitted.count, gb(bytes)))
        }
    }

    private static func gb(_ bytes: Int64) -> Double { Double(bytes) / 1024 / 1024 / 1024 }


    /// The scanner's default roots, recomputed here so the census stays independent of internals.
    private static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
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
                roots.append(url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects", isDirectory: true))
            }
        }
        let pi = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: pi.path) { roots.append(pi) }

        var seen = Set<String>()
        return roots
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private extension Array where Element == String {
    /// Bounds-safe indexing for argument lookup — `--dump` may be the last argument.
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
