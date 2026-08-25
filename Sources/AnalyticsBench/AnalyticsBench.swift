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

        // `--fold [--dir <path>]`: warm the archive once, then time the *pure fold* —
        // `analytics(in:)`, which reads no bytes — over several window widths, and report how many
        // rows each dimension emits. This is the measurement that decides whether a new dimension
        // can be exposed whole or has to be cut: the question is the cost of the fold and the size
        // of what it hands to the UI, not the cost of the scan that warmed it.
        if arguments.contains("--synthetic") {
            func value(_ flag: String, _ fallback: Int) -> Int {
                guard let index = arguments.firstIndex(of: flag) else { return fallback }
                return Int(arguments[safe: index + 1] ?? "") ?? fallback
            }
            await synthetic(
                days: value("--days", 730),
                sessionsPerDay: value("--sessions-per-day", 5),
                projects: value("--projects", 120))
            return
        }

        if arguments.contains("--fold") {
            var directories: [URL]?
            if let dirIndex = arguments.firstIndex(of: "--dir"), let path = arguments[safe: dirIndex + 1] {
                directories = [URL(fileURLWithPath: path)]
            }
            await fold(directories: directories)
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

    // MARK: - Synthetic scale (what this costs after the archive has grown)

    /// Generate a corpus of a chosen size, scan it, and report what the fold costs over all of it.
    ///
    /// WHY SYNTHESISE: the archive is permanent and only grows, so the decision that matters is what
    /// a dimension costs in two years, not what it costs today. Extrapolating from today's 41 active
    /// days is a guess; generating 730 of them and folding is a measurement. The generator emits the
    /// same JSONL shape the scanner parses, so the numbers come out of the real pipeline.
    ///
    ///   --synthetic --days N --sessions-per-day S --projects P
    private static func synthetic(days: Int, sessionsPerDay: Int, projects: Int) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyticsbench-synth-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let models = ["claude-sonnet-4", "claude-opus-4-1", "claude-haiku-4-5"]

        let writeStart = DispatchTime.now().uptimeNanoseconds
        var bytes = 0
        for dayIndex in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -dayIndex, to: today) else { continue }
            var lines: [String] = []
            lines.reserveCapacity(sessionsPerDay * 2)
            for session in 0..<sessionsPerDay {
                // Each day touches a rotating slice of the project set, so `(day, project)` pairs
                // grow the way they do in life: many projects overall, a handful active per day.
                let project = (dayIndex * sessionsPerDay + session) % projects
                let model = models[session % models.count]
                for entry in 0..<2 {
                    guard let instant = calendar.date(
                        bySettingHour: (session * 2 + entry) % 24, minute: 0, second: 0, of: day)
                    else { continue }
                    lines.append(syntheticLine(
                        messageId: "m\(dayIndex)-\(session)-\(entry)",
                        requestId: "r\(dayIndex)-\(session)-\(entry)",
                        model: model,
                        project: "project-\(project)",
                        session: "sess-\(dayIndex)-\(session)",
                        instant: instant))
                }
            }
            let blob = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
            bytes += blob.count
            try? blob.write(to: root.appendingPathComponent("day-\(dayIndex).jsonl"))
        }
        print(String(
            format: "generated %ld days × %ld sessions × %ld projects — %.1f MB in %.2f s",
            days, sessionsPerDay, projects, Double(bytes) / 1024 / 1024, elapsed(since: writeStart)))

        let suiteName = "analyticsbench.synth.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else { exit(1) }
        defer { store.removePersistentDomain(forName: suiteName) }
        let defaults = CostDefaults(store)
        let scanner = CostScanner(
            pricing: Pricing(defaults: defaults, networkEnabled: false), defaults: defaults)

        let scanStart = DispatchTime.now().uptimeNanoseconds
        _ = await scanner.scanAnalytics(directories: [root], windowDays: 1, now: now)
        print(String(format: "cold scan: %.2f s", elapsed(since: scanStart)))
        if let blob = store.data(forKey: "costScanner.analyticsCache") {
            print(String(format: "persisted archive: %.2f MB", Double(blob.count) / 1024 / 1024))
        }

        guard let from = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return }
        var samples: [Double] = []
        var last: UsageAnalytics?
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let analytics = await scanner.analytics(in: from...today, now: now)
            samples.append(elapsed(since: start) * 1000)
            last = analytics
        }
        guard let analytics = last else { return }
        samples.sort()
        print(String(
            format: "fold over all %ld days: median %.2f ms   dayModel=%ld projects=%ld%@",
            days, samples[samples.count / 2], analytics.byDayModel.count,
            analytics.byProject.count, extraDimensions(analytics)))
        print(footprint(analytics))
    }

    /// One assistant line in the shape `handleAnalyticsLine` parses.
    private static func syntheticLine(
        messageId: String,
        requestId: String,
        model: String,
        project: String,
        session: String,
        instant: Date) -> String
    {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let object: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": iso.string(from: instant),
            "cwd": "/work/\(project)",
            "sessionId": session,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 1_000,
                    "output_tokens": 500,
                    "cache_read_input_tokens": 20_000,
                    "cache_creation_input_tokens": 3_000,
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Bytes the new dimensions hand to the UI, counted rather than guessed.
    ///
    /// Struct stride plus the UTF-8 of every distinct string they reference. Distinct is the right
    /// unit: the fold copies `String` values that already exist in the archive's dictionaries, so a
    /// repeated project name costs a retain, not a second buffer.
    private static func footprint(_ analytics: UsageAnalytics) -> String {
        let dayProjectBytes = MemoryLayout<DayProjectEntry>.stride * analytics.byDayProject.count
        let sessionBytes = MemoryLayout<SessionUsageEntry>.stride * analytics.sessions.count
        let rankBytes = (MemoryLayout<String>.stride + MemoryLayout<Int>.stride)
            * analytics.projectRankByTotal.count
        // The histogram is the point of the redesign: it does not grow with the archive.
        let histogramBytes = MemoryLayout<Int>.stride * analytics.sessionTokenBuckets.count
        let monthBytes = MemoryLayout<MonthCoverage>.stride * analytics.monthCoverage.count
        var strings = Set<String>()
        for entry in analytics.byDayProject { strings.insert(entry.project) }
        for name in analytics.projectRankByTotal.keys { strings.insert(name) }
        for entry in analytics.sessions {
            strings.insert(entry.sessionId)
            strings.insert(entry.project)
            strings.insert(entry.dominantModel)
        }
        let stringBytes = strings.reduce(0) { $0 + $1.utf8.count }
        let total = dayProjectBytes + sessionBytes + rankBytes + histogramBytes + monthBytes + stringBytes
        return String(
            format: "new dimensions hold %.3f MB (byDayProject %.3f + sessions %.3f + rank %.3f MB; histogram %ld B, months %ld B, %ld strings %.3f MB)",
            Double(total) / 1024 / 1024,
            Double(dayProjectBytes) / 1024 / 1024,
            Double(sessionBytes) / 1024 / 1024,
            Double(rankBytes) / 1024 / 1024,
            histogramBytes, monthBytes, strings.count,
            Double(stringBytes) / 1024 / 1024)
    }

    // MARK: - Fold cost (the range API, which reads no bytes)

    /// Warm the archive once, then time `analytics(in:)` across widening windows.
    ///
    /// The widest widths are deliberately far past what the history covers: they answer "what does
    /// this cost when every day the archive will ever hold is inside the slice", which is the shape
    /// the growth question is really about. Each width is timed several times and the **median** is
    /// reported — a single sample would be reporting the scheduler, not the fold.
    private static func fold(directories: [URL]?) async {
        let suiteName = "analyticsbench.fold.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else { exit(1) }
        defer { store.removePersistentDomain(forName: suiteName) }
        let defaults = CostDefaults(store)
        let scanner = CostScanner(
            pricing: Pricing(defaults: defaults, networkEnabled: false), defaults: defaults)

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        print("=== AnalyticsBench — fold cost (analytics(in:), zero I/O) ===")
        let warmStart = DispatchTime.now().uptimeNanoseconds
        _ = await scanner.scanAnalytics(directories: directories, windowDays: 7, now: now)
        print(String(format: "warm-up scan: %.3f s", elapsed(since: warmStart)))
        if let blob = store.data(forKey: "costScanner.analyticsCache") {
            print(String(format: "persisted archive: %.2f MB", Double(blob.count) / 1024 / 1024))
        }

        for width in [7, 30, 90, 365, 3650] {
            guard let from = calendar.date(byAdding: .day, value: -(width - 1), to: today) else { continue }
            var samples: [Double] = []
            var last: UsageAnalytics?
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                let analytics = await scanner.analytics(in: from...today, now: now)
                samples.append(elapsed(since: start) * 1000)
                last = analytics
            }
            guard let analytics = last else { continue }
            samples.sort()
            print(String(
                format: "%5ldd  median %7.2f ms   dayModel=%-6ld projects=%-5ld topSessions=%-4ld%@",
                width, samples[samples.count / 2], analytics.byDayModel.count,
                analytics.byProject.count, analytics.topSessions.count,
                extraDimensions(analytics)))
        }
    }

    /// Rows emitted by dimensions added after this bench mode was written, or `""` on a build that
    /// does not have them. Keeping the new counts behind one function is what lets the *same* bench
    /// source be run against the before and after builds.
    private static func extraDimensions(_ analytics: UsageAnalytics) -> String {
        String(
            format: " dayProject=%-6ld ranked=%-2ld/%-4ld others=%-4ld sessions=%-6ld/%-6ld cut=%@",
            analytics.byDayProject.count, analytics.rankedProjects.count,
            analytics.projectRankByTotal.count, analytics.otherProjectCount,
            analytics.sessions.count, analytics.totalSessions,
            analytics.sessionsTruncated ? "yes" : "no")
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
