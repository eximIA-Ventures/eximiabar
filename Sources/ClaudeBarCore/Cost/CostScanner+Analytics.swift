import Foundation
import os

/// The analytics scan plus the source fingerprint it observed, from a single directory walk
/// (EXB-5.6). The dashboard needs both to decide whether its per-period cache is still valid;
/// returning them together means the file system is enumerated once, not twice.
public struct AnalyticsScanResult: Sendable {
    public let analytics: UsageAnalytics
    /// Fingerprint of the source files as seen by *this* scan — see `CostScanner.sourceFingerprint`.
    public let fingerprint: String

    public init(analytics: UsageAnalytics, fingerprint: String) {
        self.analytics = analytics
        self.fingerprint = fingerprint
    }
}

extension CostScanner {
    /// Signpost handle for the dashboard's heavy paths (EXB-3.6 AC8). Categorised `"DashboardPerf"`
    /// so Instruments' "Points of Interest" / `log stream` can isolate the analytics scan from the
    /// rest of the app. Static + `nonisolated` so both the actor and the MainActor controller emit
    /// into the same stream.
    public nonisolated static let perfSignposter = OSSignposter(
        logHandle: OSLog(subsystem: CoreLog.subsystem, category: "DashboardPerf"))

    /// Logger for the archive's own lifecycle — migrations and, above all, a blob this build could
    /// not read. That last one has to be loud: it is the only signal that history was set aside.
    nonisolated static let analyticsLog = Logger(subsystem: CoreLog.subsystem, category: "cost.analytics")

    // `modelPrice(for:)` was removed in EXB-5.7. It existed so the dashboard could price the
    // dominant model for the "economia estimada" card (EXB-4.5); that card was dropped when the
    // owner decided the cache saving belongs on screen as a rate, not as dollars, and its only
    // caller — `DashboardWindowController.cachePricing(for:scanner:)` — went with it. A `public`
    // function with no consumer reads as live API and is not; same ruling as `windowFileFloor`.
    // Prices now enter exactly one place: `makeAnalytics`, once per distinct model per scan.

    // MARK: - Public scan API

    /// `UsageAnalytics` for an arbitrary date range, folded from the archive already in memory —
    /// **no directory walk, no `stat`, no file read** (EXB-5.8).
    ///
    /// This is the entry point a draggable range selector needs. `scanAnalytics` cannot serve one:
    /// it begins with `analyticsCensus`, which enumerates and stats every candidate log (≈2 100
    /// files, ~66 ms on this machine). A drag emits dozens of events per second, so paying the
    /// census per event is not a slow path, it is the wrong shape.
    ///
    /// **All five dimensions are recomputed here, and that is the point.** `byProject` and
    /// `heatmap` carry no date in their output structs, so a caller physically cannot slice them
    /// after the fact. If this method returned those two whole while the other three respected the
    /// range, the dashboard would show two different periods side by side and say nothing about it.
    /// Slicing has to happen at the buckets, which is here.
    ///
    /// The range is interpreted at day granularity: both bounds are snapped to start-of-day in the
    /// user's local time zone, and both are inclusive. `now` fixes the current calendar month for
    /// the month-to-date figures only — those mean "this month" regardless of the slice on screen.
    ///
    /// Cost: the first call in a process may decode the persisted archive; after that it is pure
    /// arithmetic over the in-memory buckets. It never returns stale data relative to the last
    /// scan, and it never *causes* a scan — refreshing from disk stays `scanAnalytics`'s job.
    public func analytics(in range: ClosedRange<Date>, now: Date = Date()) async -> UsageAnalytics {
        let signposter = Self.perfSignposter
        let state = signposter.beginInterval("analyticsInRange")
        defer { signposter.endInterval("analyticsInRange", state) }

        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: range.lowerBound)
        let upper = calendar.startOfDay(for: range.upperBound)
        // `startOfDay` is monotonic, so `lower <= upper` already holds for a valid `ClosedRange`;
        // the clamp is belt-and-braces against a caller building one from odd time zones.
        return await self.makeAnalytics(
            from: self.loadAnalyticsCache(),
            dayRange: Swift.min(lower, upper)...Swift.max(lower, upper),
            now: now)
    }

    /// The inclusive start-of-day range a trailing `days`-day window covers, ending today.
    ///
    /// Shared by `scanAnalytics` and `analytics(in:)` so "last 30 days" means the same set of days
    /// through both doors — the equivalence between them is then structural, not a coincidence two
    /// separate expressions happen to preserve.
    static func windowDayRange(days: Int, now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let todayStart = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: todayStart) ?? todayStart
        return earliest...todayStart
    }

    /// Scan the Claude JSONL logs and produce the rich `UsageAnalytics` the dashboard needs:
    /// per-`(day, model)` rows with the cache-token split, per-project totals, a weekday × hour
    /// heatmap, and the top sessions.
    ///
    /// Backed by the persisted archive (`AnalyticsCache.swift`): a file whose size and modification
    /// date are unchanged since the last scan is not opened at all, and a file that merely grew is
    /// resumed at its last byte offset. Every day ever seen is kept — nothing expires — and
    /// `windowDays` is applied as a *filter over days* at aggregation time, so switching period in
    /// the dashboard costs arithmetic, never I/O.
    ///
    /// Anti-freeze: runs on this actor's executor (callers invoke from `Task.detached`), never the
    /// MainActor. `now` is injected for deterministic bucketing in tests.
    public func scanAnalytics(
        directories: [URL]? = nil,
        windowDays: Int,
        now: Date = Date()) async -> UsageAnalytics
    {
        await self.scanAnalyticsResult(directories: directories, windowDays: windowDays, now: now)
            .analytics
    }

    /// `scanAnalytics` plus the source fingerprint observed during the same walk (EXB-5.6).
    public func scanAnalyticsResult(
        directories: [URL]? = nil,
        windowDays: Int,
        now: Date = Date()) async -> AnalyticsScanResult
    {
        let signposter = Self.perfSignposter
        let scanID = signposter.makeSignpostID()
        let scanState = signposter.beginInterval("scanAnalytics", id: scanID, "window=\(windowDays)d")
        defer { signposter.endInterval("scanAnalytics", scanState) }

        let roots = directories ?? Self.defaultDirectories(fileManager: self.fileManager)
        let window = max(1, windowDays)

        // --- 1. One directory walk: every candidate file *and* the fingerprint ---
        let census = self.analyticsCensus(roots: roots)

        // --- 2. Plan: which files actually need bytes read ---
        var state = self.loadAnalyticsCache()
        var jobs: [AnalyticsParseJob] = []
        for file in census.files {
            let record = state.files[file.path]
            // Unchanged since the last scan → zero bytes read, cached buckets reused verbatim.
            if let record,
               record.size == file.size,
               record.modified == file.modified
            { continue }

            if let record,
               let ledger = record.ledger,
               file.size >= record.endOffset,
               record.endOffset > 0
            {
                // Grew (or was merely touched): resume at the last offset, carrying the dedup ledger
                // so a streaming chunk written after the previous scan *replaces* its earlier self.
                jobs.append(AnalyticsParseJob(
                    file: file,
                    startOffset: record.endOffset,
                    priorBuckets: record.buckets,
                    priorLedger: ledger))
            } else {
                // No record, truncation/rotation (`size < endOffset`), or a ledger we chose not to
                // retain → full re-read from 0, discarding this file's prior contribution entirely.
                jobs.append(AnalyticsParseJob(
                    file: file,
                    startOffset: 0,
                    priorBuckets: [:],
                    priorLedger: [:]))
            }
            // A path that was archived as gone has come back. Its archived contribution must be
            // withdrawn before the file is parsed again, or the same day is booked twice.
            state.archived.removeValue(forKey: file.path)
        }

        // --- 3. Parse the changed files in parallel ---
        signposter.emitEvent(
            "scanAnalytics.plan", id: scanID,
            "candidates=\(census.files.count) parsed=\(jobs.count)")
        if !jobs.isEmpty {
            let parseState = signposter.beginInterval("parseFiles", id: scanID, "files=\(jobs.count)")
            let outcomes = await Self.runParseJobs(jobs, now: now)
            signposter.endInterval("parseFiles", parseState)
            for outcome in outcomes {
                guard !outcome.failed else { continue }
                state.files[outcome.path] = AnalyticsFileRecord(
                    size: outcome.size,
                    modified: outcome.modified,
                    endOffset: outcome.endOffset,
                    buckets: outcome.buckets,
                    ledger: outcome.ledger)
            }
        }

        // --- 4. Archive what left the disk, record coverage, persist ---
        Self.archiveVanishedFiles(&state, census: census)
        Self.trimLedgers(&state, now: now)
        Self.recordCoverage(&state, now: now)
        self.storeAnalyticsCache(state)

        // --- 5. Aggregate the requested window out of the archive ---
        let aggregateState = signposter.beginInterval("makeAnalytics", id: scanID, "files=\(state.files.count)")
        let analytics = await self.makeAnalytics(
            from: state,
            dayRange: Self.windowDayRange(days: window, now: now),
            now: now)
        signposter.endInterval("makeAnalytics", aggregateState)

        return AnalyticsScanResult(analytics: analytics, fingerprint: census.fingerprint)
    }

    // MARK: - File census (enumeration + mtime pre-filter + fingerprint), one walk

    /// A candidate JSONL file with the two attributes that decide whether it must be re-read.
    struct AnalyticsFile: Sendable {
        let url: URL
        let path: String
        let size: Int64
        let modified: Date
    }

    struct AnalyticsCensus: Sendable {
        /// Files admitted by the modification-date pre-filter, in enumeration order.
        let files: [AnalyticsFile]
        /// Absolute paths of `files`, for pruning records of files that dropped out.
        let admitted: Set<String>
        /// Standardised paths of the roots that were walked.
        let rootPaths: [String]
        let fingerprint: String
    }

    // The modification-date floor that used to live here (`windowFileFloor`) is gone as of EXB-5.7.
    // It was what made a full re-read of the history affordable — the fix for EXB-3.6 BUG 2's
    // multi-second freeze — but the persisted archive made that job obsolete and the floor actively
    // harmful: a log older than it could never be ingested at all, which on a fresh install is
    // precisely the history nobody else is keeping. The freeze is now prevented by not *re*-reading,
    // pinned by `CostScannerIncrementalAnalyticsTests.wideningThePeriodAfterANarrowScanReadsNoBytes`.

    /// Walk the roots once, collecting every `.jsonl` file and, at the same time, the fingerprint of
    /// what was seen.
    ///
    /// There is deliberately **no modification-date floor** any more. It used to skip files older
    /// than the window, which was free when the scan re-read everything each time — but with the
    /// archive it would mean a log older than the floor could never be ingested at all, and on a
    /// fresh install that is precisely the history nobody else is keeping. Skipping is now decided by
    /// `(size, modified)` against the cache, which is strictly better: an already-ingested old file
    /// costs a `stat` and nothing else.
    private func analyticsCensus(roots: [URL]) -> AnalyticsCensus {
        var files: [AnalyticsFile] = []
        var admitted = Set<String>()
        var rootPaths: [String] = []
        // Order-independent digest: a running sum + xor of per-file FNV-1a hashes, plus the count.
        // Deliberately *not* `Hasher` — that is seeded per process, so it would change on every
        // launch and defeat the very cache invalidation it feeds.
        var sum: UInt64 = 0
        var xor: UInt64 = 0
        var count = 0

        for root in roots {
            guard self.fileManager.fileExists(atPath: root.path) else { continue }
            rootPaths.append(root.standardizedFileURL.path)
            guard let enumerator = self.fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                // A missing mtime → treat as "changed" (fail-open); we would rather read needlessly.
                let modified = values?.contentModificationDate ?? Date.distantFuture
                let size = Int64(values?.fileSize ?? 0)
                let path = url.standardizedFileURL.path

                files.append(AnalyticsFile(url: url, path: path, size: size, modified: modified))
                admitted.insert(path)

                let digest = Self.fnv1a(path, size: size, modified: modified)
                sum = sum &+ digest
                xor ^= digest
                count += 1
            }
        }

        return AnalyticsCensus(
            files: files,
            admitted: admitted,
            rootPaths: rootPaths,
            fingerprint: "\(count):\(sum):\(xor)")
    }

    /// FNV-1a over `path` mixed with the file's size and modification date — a stable, process
    /// independent digest of "this exact file, in this exact state".
    private static func fnv1a(_ path: String, size: Int64, modified: Date) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        for byte in path.utf8 { mix(byte) }
        // Millisecond resolution on the mtime is plenty to notice a rewrite, and avoids a
        // fingerprint that churns on sub-millisecond float noise.
        let stamp = UInt64(bitPattern: Int64((modified.timeIntervalSince1970 * 1000).rounded()))
        for shift in stride(from: 0, to: 64, by: 8) { mix(UInt8(truncatingIfNeeded: stamp >> UInt64(shift))) }
        let bits = UInt64(bitPattern: size)
        for shift in stride(from: 0, to: 64, by: 8) { mix(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        return hash
    }

    // MARK: - Parallel parse

    struct AnalyticsParseJob: Sendable {
        let file: AnalyticsFile
        let startOffset: Int64
        let priorBuckets: [AnalyticsBucketKey: AnalyticsBucketTotals]
        let priorLedger: [String: AnalyticsLedgerEntry]
    }

    struct AnalyticsParseOutcome: Sendable {
        let path: String
        let size: Int64
        let modified: Date
        let endOffset: Int64
        let buckets: [AnalyticsBucketKey: AnalyticsBucketTotals]
        let ledger: [String: AnalyticsLedgerEntry]
        /// `true` when the file could not be read — the caller keeps the previous record untouched.
        let failed: Bool
    }

    /// Parse the planned files concurrently, bounded by the core count.
    ///
    /// Determinism: every outcome is scoped to one file and merged by path, and each bucket carries
    /// integer token counts only, so the result does not depend on completion order. Money enters
    /// once, at aggregation, over a sorted key order.
    private static func runParseJobs(
        _ jobs: [AnalyticsParseJob],
        now: Date) async -> [AnalyticsParseOutcome]
    {
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: AnalyticsParseOutcome.self) { group in
            var outcomes: [AnalyticsParseOutcome] = []
            outcomes.reserveCapacity(jobs.count)
            var next = 0

            func addTask(_ job: AnalyticsParseJob) {
                group.addTask {
                    Self.parseAnalyticsFile(job: job, now: now)
                }
            }

            while next < jobs.count, next < limit {
                addTask(jobs[next])
                next += 1
            }
            for await outcome in group {
                outcomes.append(outcome)
                if next < jobs.count {
                    addTask(jobs[next])
                    next += 1
                }
            }
            return outcomes
        }
    }

    /// Read one file from `job.startOffset` to EOF and fold the new lines into the file's buckets.
    ///
    /// `nonisolated static` on purpose: it touches no actor state, so the task group actually runs
    /// these in parallel instead of serialising on the scanner's executor.
    nonisolated static func parseAnalyticsFile(
        job: AnalyticsParseJob,
        now: Date) -> AnalyticsParseOutcome
    {
        var buckets = job.priorBuckets
        var ledger = job.priorLedger
        // Fallback session label when the JSONL omits `sessionId`: the file's basename without ext.
        let fileSession = job.file.url.deletingPathExtension().lastPathComponent
        var clock = LocalClock(now: now)

        let endOffset: Int64
        do {
            endOffset = try Self.scanLines(
                fileURL: job.file.url,
                offset: job.startOffset,
                maxLineBytes: Self.analyticsMaxLineBytes) { line, lineOffset in
                Self.handleAnalyticsLine(
                    line,
                    lineOffset: lineOffset,
                    fileSession: fileSession,
                    clock: &clock,
                    buckets: &buckets,
                    ledger: &ledger)
            }
        } catch {
            // Never crash on a bad file — leave the previous record alone (mirrors the popover scan).
            return AnalyticsParseOutcome(
                path: job.file.path, size: job.file.size, modified: job.file.modified,
                endOffset: job.startOffset, buckets: job.priorBuckets, ledger: job.priorLedger,
                failed: true)
        }

        return AnalyticsParseOutcome(
            path: job.file.path,
            size: job.file.size,
            modified: job.file.modified,
            endOffset: endOffset,
            buckets: buckets,
            ledger: ledger,
            failed: false)
    }

    /// Pre-filter + decode + fold for a single raw line.
    private nonisolated static func handleAnalyticsLine(
        _ line: Data,
        lineOffset: Int64,
        fileSession: String,
        clock: inout LocalClock,
        buckets: inout [AnalyticsBucketKey: AnalyticsBucketTotals],
        ledger: inout [String: AnalyticsLedgerEntry])
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
              let timestamp = Self.analyticsTimestamp(tsText),
              let slot = clock.slot(for: timestamp)
        else { return }

        let key = AnalyticsBucketKey(
            day: slot.day,
            hour: slot.hour,
            model: Pricing.normalize(model),
            // Project from the entry's `cwd` (top-level field), falling back to "Unknown".
            project: Self.projectName(fromCWD: obj["cwd"] as? String),
            // Session from `sessionId` (top-level), falling back to the file basename.
            session: (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? fileSession)
        let totals = AnalyticsBucketTotals(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            firstTimestamp: timestamp)

        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        guard let messageId, let requestId else {
            // Older logs may omit the ids; treat each as distinct to avoid dropping usage.
            buckets[key, default: AnalyticsBucketTotals()].add(totals)
            return
        }

        let dedupKey = "\(messageId):\(requestId)"
        if let previous = ledger[dedupKey] {
            // "Higher byte offset wins": an earlier chunk never overrides a later one.
            guard previous.offset < lineOffset else { return }
            // Withdraw the superseded chunk before booking the new one — this is what keeps a
            // resumed scan from double-counting a message it had already seen.
            if var existing = buckets[previous.bucket] {
                existing.subtract(previous.totals)
                if existing.isEmpty {
                    buckets.removeValue(forKey: previous.bucket)
                } else {
                    buckets[previous.bucket] = existing
                }
            }
        }
        ledger[dedupKey] = AnalyticsLedgerEntry(offset: lineOffset, bucket: key, totals: totals)
        buckets[key, default: AnalyticsBucketTotals()].add(totals)
    }

    // MARK: - Local-time bucketing (hot path)

    /// Maps an instant to its local `(start-of-day, hour)` slot, memoised per UTC hour.
    ///
    /// `Calendar` work dominated the old per-row cost: three `Calendar.current` lookups per entry,
    /// millions of entries. Every instant inside one UTC hour maps to the same local day and hour —
    /// zone transitions land on hour boundaries — so one memo slot collapses that to one `Calendar`
    /// round trip per hour of history actually present in the file.
    struct LocalClock {
        private let calendar: Calendar
        /// Start of the scan's "today". The only entries rejected are future-dated ones.
        private let todayStart: Date
        private var memoHour: Int64 = .min
        private var memoDay = Date.distantPast
        private var memoLocalHour = 0
        private var memoAccepted = false

        init(now: Date) {
            let calendar = Calendar.current
            self.calendar = calendar
            self.todayStart = calendar.startOfDay(for: now)
        }

        /// The local slot for `timestamp`, or `nil` when the entry is dated in the future.
        ///
        /// There is no lower bound: the archive keeps every day it ever sees, and the dashboard's
        /// window is applied later, at aggregation. Filtering here would mean an old entry read once
        /// and then deleted from disk is lost forever — the failure this whole design exists to
        /// prevent. Future-dated entries are still rejected, since they can only be clock skew.
        mutating func slot(for timestamp: Date) -> (day: Date, hour: Int)? {
            let utcHour = Int64((timestamp.timeIntervalSince1970 / 3600).rounded(.down))
            if utcHour != self.memoHour {
                self.memoHour = utcHour
                self.memoDay = self.calendar.startOfDay(for: timestamp)
                self.memoLocalHour = self.calendar.component(.hour, from: timestamp)
                self.memoAccepted = self.memoDay <= self.todayStart
            }
            guard self.memoAccepted else { return nil }
            return (self.memoDay, self.memoLocalHour)
        }
    }

    // MARK: - Archiving (EXB-5.7) — nothing here subtracts a number

    /// Move the contribution of files that have left the disk into the permanent archive.
    ///
    /// This is the inversion the archive requirement demanded. The scan used to *delete* the record
    /// of a vanished file, which quietly deleted its usage with it — the exact mechanism by which
    /// Claude Code's retention erased five months of this machine's history. Now the byte offset and
    /// the dedup ledger are dropped (they describe a file that no longer exists and are meaningless)
    /// while the buckets are kept forever, still attributed to the original path so a log recreated
    /// there can be reconciled instead of double-counted.
    private static func archiveVanishedFiles(_ state: inout AnalyticsCacheState, census: AnalyticsCensus) {
        // Snapshot the keys first: the loop mutates the dictionary it reads from.
        for path in Array(state.files.keys) where !census.admitted.contains(path) {
            // Only under the roots this scan actually walked, so a scan scoped to one directory
            // never declares another directory's files vanished.
            guard census.rootPaths.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            guard let record = state.files.removeValue(forKey: path) else { continue }
            guard !record.buckets.isEmpty else { continue }
            // Merging rather than assigning: a path could already hold an archived generation from
            // an earlier disappearance. Token counts add; the earliest timestamp wins.
            state.archived[path, default: [:]].merge(record.buckets) { existing, incoming in
                var merged = existing
                merged.add(incoming)
                return merged
            }
        }
    }

    /// Keep dedup ledgers only for logs recent enough to still be appended to, capped so the
    /// persisted blob stays bounded. A file whose ledger was dropped is re-read in full if it ever
    /// changes — slower for that one file, but always exact.
    ///
    /// Note this trims *ledgers*, never buckets: nothing in the archive is ever forgotten.
    private static func trimLedgers(_ state: inout AnalyticsCacheState, now: Date) {
        let floor = Date(timeIntervalSince1970:
            now.timeIntervalSince1970 - Double(CostScanner.analyticsLedgerRetentionDays) * 86_400)
        let keep = Set(
            state.files
                .filter { $0.value.ledger != nil && $0.value.modified >= floor }
                .sorted { $0.value.modified > $1.value.modified }
                .prefix(CostScanner.analyticsMaxLedgerFiles)
                .map(\.key))
        for (path, record) in state.files where record.ledger != nil && !keep.contains(path) {
            var record = record
            record.ledger = nil
            state.files[path] = record
        }
    }

    /// Extend the set of days the archive can vouch for.
    ///
    /// The claim being recorded is narrow and checkable: *at this scan, the app could see the logs
    /// covering these days*. So the span runs from the earliest day any surviving bucket knows about
    /// through today — within it, a day with no entry is a day with no usage. Union, never replace:
    /// coverage is monotone, because a day the app once watched does not become unknowable when the
    /// transcript behind it is later deleted.
    ///
    /// Honest limit: a day whose transcript Claude Code deleted *before* exímIABar ever ran cannot be
    /// distinguished from a day with no usage by any amount of bookkeeping here. That gap is closed
    /// by retention settings, not by this function.
    private static func recordCoverage(_ state: inout AnalyticsCacheState, now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Earliest day visible from files still on disk — vanished files' days were already vouched
        // for when they were live, and must not extend the claim now that they are gone.
        guard let earliest = state.files.values.flatMap({ $0.buckets.keys.map(\.day) }).min() else { return }

        // Normalised on insert for the reason spelled out in `monthCoverage`: a day-by-day walk can
        // step off midnight for good when it crosses a daylight-saving change that happened *at*
        // midnight, and every consumer that asks `coveredDays.contains(startOfDay)` would then get
        // `false` for days the archive really did watch. Only reachable on an archive old enough to
        // span such a change — which is exactly what a permanent archive becomes.
        var day = calendar.startOfDay(for: earliest)
        while day <= today {
            state.coveredDays.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
    }

    // MARK: - Aggregation → UsageAnalytics

    /// Fold the warmed cache into `UsageAnalytics` for an inclusive range of **start-of-day** dates.
    ///
    /// Every accumulator below is integer until the last step; prices are then applied once per
    /// distinct model, walking keys in sorted order. That is what makes two runs — and a full scan
    /// versus an incremental one — produce bit-identical costs rather than order-dependent ULPs.
    ///
    /// `now` is *not* the range: it only fixes the current calendar month for the month-to-date
    /// figures, which are "this month" regardless of what slice the caller is looking at.
    private func makeAnalytics(
        from state: AnalyticsCacheState,
        dayRange: ClosedRange<Date>,
        now: Date) async -> UsageAnalytics
    {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now

        var dayModel: [DayModelKey: AnalyticsBucketTotals] = [:]
        var projectModel: [ProjectModelKey: AnalyticsBucketTotals] = [:]
        var sessionModel: [SessionModelKey: AnalyticsBucketTotals] = [:]
        var sessionProject: [String: String] = [:]
        var sessionFirst: [String: Date] = [:]
        var monthModel: [String: AnalyticsBucketTotals] = [:]
        var heat = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var models = Set<String>()

        // Month-to-date spans the current calendar month, NOT the selected slice — see below.
        let todayStart = calendar.startOfDay(for: now)

        // Live files and the archive of vanished ones are folded identically — from the dashboard's
        // point of view a day's usage is a day's usage, whether or not its transcript still exists.
        for buckets in state.allBuckets() {
            for (key, totals) in buckets {
                let inRange = dayRange.contains(key.day)
                // Month-to-date is deliberately computed outside the slice.
                //
                // It used to be folded inside the range guard, which made it "this month ∩ the
                // selected period" — silently understated whenever the period did not cover the
                // whole month so far. On the 24th with a 7-day window it counted 7 days and the
                // run-rate projection that divides it by 24 elapsed days came out roughly three
                // times too low. Nothing in the number looked wrong; it was simply answering a
                // different question from the one its name asks.
                //
                // It also has to be slice-independent for the draggable selector: dragging the
                // handle must not move "this month's" projection.
                let inMonth = key.day >= monthStart && key.day <= todayStart
                guard inRange || inMonth else { continue }
                // Priced below, so every model that contributes to *either* total must be listed.
                models.insert(key.model)

                // Whole days only — start-of-month is itself a day boundary, so no precision is lost.
                if inMonth {
                    monthModel[key.model, default: AnalyticsBucketTotals()].add(totals)
                }
                guard inRange else { continue }

                dayModel[DayModelKey(day: key.day, model: key.model), default: AnalyticsBucketTotals()]
                    .add(totals)
                projectModel[ProjectModelKey(project: key.project, model: key.model), default: AnalyticsBucketTotals()]
                    .add(totals)
                sessionModel[SessionModelKey(session: key.session, model: key.model), default: AnalyticsBucketTotals()]
                    .add(totals)

                // A session's project is the one it was first seen under (ties resolve to the
                // earliest timestamp), matching the previous per-row accumulator.
                if let existing = sessionFirst[key.session] {
                    if totals.firstTimestamp < existing {
                        sessionFirst[key.session] = totals.firstTimestamp
                        sessionProject[key.session] = key.project
                    }
                } else {
                    sessionFirst[key.session] = totals.firstTimestamp
                    sessionProject[key.session] = key.project
                }

                let weekday = calendar.component(.weekday, from: key.day) - 1
                if weekday >= 0, weekday < 7, key.hour >= 0, key.hour < 24 {
                    heat[weekday][key.hour] += totals.inputTokens + totals.outputTokens
                        + totals.cacheReadTokens + totals.cacheWriteTokens
                }
            }
        }

        // One price lookup per distinct model in the whole scan (was: one per parsed row).
        var prices: [String: (input: Double, output: Double)] = [:]
        for model in models.sorted() {
            prices[model] = await self.pricing.costPerToken(model: model)
        }
        // Cache-read is cheaper and cache-write dearer than base input, but exímIABar prices on the
        // base input/output table (EXB-1.7), same as the popover scan. Cache tokens surface as
        // volume (heatmap / stacked chart / project totals), never as a separate charge.
        func cost(_ totals: AnalyticsBucketTotals, _ model: String) -> Double {
            let price = prices[model] ?? (0, 0)
            return Double(totals.inputTokens) * price.input + Double(totals.outputTokens) * price.output
        }

        // --- Per-(day, model) entries, sorted by cost desc (then date desc, model asc) ---
        let byDayModel = dayModel
            .map { key, totals in
                ModelCostEntry(
                    model: key.model,
                    date: key.day,
                    inputTokens: totals.inputTokens,
                    outputTokens: totals.outputTokens,
                    cacheReadTokens: totals.cacheReadTokens,
                    cacheWriteTokens: totals.cacheWriteTokens,
                    cost: cost(totals, key.model))
            }
            .sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.model < $1.model
            }

        // --- Per-project totals (summed over models in a sorted order, for determinism) ---
        var projectCost: [String: Double] = [:]
        var projectTokens: [String: Int] = [:]
        for key in projectModel.keys.sorted(by: Self.isOrderedBefore) {
            guard let totals = projectModel[key] else { continue }
            projectCost[key.project, default: 0] += cost(totals, key.model)
            projectTokens[key.project, default: 0] += totals.inputTokens + totals.outputTokens
                + totals.cacheReadTokens + totals.cacheWriteTokens
        }
        let byProject = projectCost
            .map { project, total in
                ProjectUsageEntry(
                    project: project,
                    costUSD: total,
                    totalTokens: projectTokens[project] ?? 0)
            }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.project < $1.project }

        // --- Top sessions ---
        var sessionCost: [String: Double] = [:]
        var sessionTokens: [String: Int] = [:]
        var sessionDominant: [String: (model: String, cost: Double)] = [:]
        for key in sessionModel.keys.sorted(by: Self.isOrderedBefore) {
            guard let totals = sessionModel[key] else { continue }
            let modelCost = cost(totals, key.model)
            sessionCost[key.session, default: 0] += modelCost
            sessionTokens[key.session, default: 0] += totals.inputTokens + totals.outputTokens
                + totals.cacheReadTokens + totals.cacheWriteTokens
            // Dominant = most cost in the session; ties resolve to the lexicographically smaller
            // model name (the keys are walked sorted, so the first one wins).
            if let current = sessionDominant[key.session] {
                if modelCost > current.cost { sessionDominant[key.session] = (key.model, modelCost) }
            } else {
                sessionDominant[key.session] = (key.model, modelCost)
            }
        }
        let topSessions = sessionCost
            .map { session, total in
                SessionUsageEntry(
                    sessionId: session,
                    date: sessionFirst[session] ?? .distantPast,
                    project: sessionProject[session] ?? "Unknown",
                    dominantModel: sessionDominant[session]?.model ?? "—",
                    totalTokens: sessionTokens[session] ?? 0,
                    costUSD: total)
            }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : $0.date > $1.date }
            .prefix(10)
            .map { $0 }

        var heatmap = UsageAnalytics.emptyHeatmap()
        for weekday in 0..<7 {
            for hour in 0..<24 {
                heatmap[weekday][hour] = HeatmapBucket(weekday: weekday, hour: hour, tokens: heat[weekday][hour])
            }
        }

        var monthToDate = 0.0
        var monthToDateTokens = 0
        for model in monthModel.keys.sorted() {
            guard let totals = monthModel[model] else { continue }
            monthToDate += cost(totals, model)
            // Tokens are the dashboard's primary quantity, so the month's volume is summed directly
            // here rather than derived downstream from cost by a tokens÷cost ratio — that ratio is
            // wrong whenever the month's model mix differs from the window's.
            monthToDateTokens += totals.inputTokens + totals.outputTokens
                + totals.cacheReadTokens + totals.cacheWriteTokens
        }

        return UsageAnalytics(
            byDayModel: byDayModel,
            byProject: byProject,
            heatmap: heatmap,
            topSessions: topSessions,
            monthToDateCost: monthToDate,
            monthToDateTokens: monthToDateTokens,
            // Only the slice's own days: the caller is drawing this slice's axis, and a covered day
            // outside it would just be noise.
            coveredDays: state.coveredDays.filter { dayRange.contains($0) })
    }

    private static func isOrderedBefore(_ lhs: ProjectModelKey, _ rhs: ProjectModelKey) -> Bool {
        lhs.project != rhs.project ? lhs.project < rhs.project : lhs.model < rhs.model
    }

    private static func isOrderedBefore(_ lhs: SessionModelKey, _ rhs: SessionModelKey) -> Bool {
        lhs.session != rhs.session ? lhs.session < rhs.session : lhs.model < rhs.model
    }

    // MARK: - Source fingerprint (dashboard cache invalidation)

    /// A fingerprint of the Claude source files: count, plus an order-independent digest of every
    /// `.jsonl` file's path, size and modification date.
    ///
    /// It used to be the *root directories'* mtimes, which change every time Claude Code opens a new
    /// session — so the dashboard's per-period cache was thrown away almost every time the user was
    /// actually working. This version changes only when a log file really changed, and even then the
    /// re-scan costs the delta, not the history.
    ///
    /// Covers every file, with no modification-date floor, so it stays identical to the fingerprint
    /// `scanAnalyticsResult` computes during its own walk. A floor here and none there would make the
    /// two disagree the moment a log crossed the boundary — a divergence that would show up as a
    /// dashboard cache that refuses to settle, with nothing obviously wrong to point at.
    public static func sourceFingerprint(
        directories: [URL]? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()) -> String
    {
        let roots = directories ?? Self.defaultDirectories(fileManager: fileManager)
        var sum: UInt64 = 0
        var xor: UInt64 = 0
        var count = 0

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = values?.contentModificationDate ?? Date.distantFuture
                let digest = Self.fnv1a(
                    url.standardizedFileURL.path,
                    size: Int64(values?.fileSize ?? 0),
                    modified: modified)
                sum = sum &+ digest
                xor ^= digest
                count += 1
            }
        }
        return "\(count):\(sum):\(xor)"
    }

    // MARK: - Cache persistence

    /// Decode the persisted archive without touching actor state — `nonisolated` so `resetCaches()`
    /// can reach it too. Never destructive: an unreadable blob is preserved, not replaced.
    nonisolated static func decodeAnalyticsCache(_ defaults: CostDefaults) -> AnalyticsCacheState {
        guard let data = defaults.data(forKey: Self.analyticsCacheDefaultsKey) else {
            return AnalyticsCacheState()
        }
        switch AnalyticsCacheCodec.read(data) {
        case let .ok(state):
            return state
        case let .migrated(state, from):
            Self.analyticsLog.notice(
                "analytics archive migrated from v\(from, privacy: .public) to v\(AnalyticsCacheCodec.version, privacy: .public)")
            return state
        case let .unreadable(version):
            // The blob cannot be parsed by this build. Starting fresh would be fine for a cache and
            // catastrophic for an archive, so the bytes are moved aside first — a copy nobody reads
            // can still be rescued by a migrator written later; a copy overwritten cannot.
            let key = Self.preserveUnreadableArchive(data, version: version, defaults: defaults)
            Self.analyticsLog.error(
                """
                analytics archive at v\(version.map(String.init) ?? "unknown", privacy: .public) is \
                unreadable by this build (v\(AnalyticsCacheCodec.version, privacy: .public)); \
                preserved under "\(key, privacy: .public)" and starting a new archive
                """)
            return AnalyticsCacheState()
        }
    }

    /// Copy an unreadable archive to a side key so the next write cannot destroy it.
    ///
    /// Returns the key it landed on. Never overwrites an existing orphan — a downgrade/upgrade cycle
    /// can orphan the same version twice, and the second rescue must not consume the first.
    private nonisolated static func preserveUnreadableArchive(
        _ data: Data,
        version: Int?,
        defaults: CostDefaults) -> String
    {
        let base = "\(Self.analyticsCacheDefaultsKey).v\(version.map(String.init) ?? "unknown").orphan"
        if defaults.data(forKey: base) == nil {
            defaults.set(data, forKey: base)
            return base
        }
        // Bounded search rather than an unbounded loop: if a machine has orphaned the same version
        // this many times, something else is wrong and the older copies are the ones worth keeping.
        for suffix in 2...Self.analyticsMaxOrphanCopies {
            let key = "\(base).\(suffix)"
            if defaults.data(forKey: key) == nil {
                defaults.set(data, forKey: key)
                return key
            }
        }
        return base
    }

    private func loadAnalyticsCache() -> AnalyticsCacheState {
        if let cached = self.analyticsCache { return cached }
        let decoded = Self.decodeAnalyticsCache(self.defaults)
        self.analyticsCache = decoded
        return decoded
    }

    private func storeAnalyticsCache(_ state: AnalyticsCacheState) {
        self.analyticsCache = state
        guard let data = AnalyticsCacheCodec.encode(state) else { return }
        self.defaults.set(data, forKey: Self.analyticsCacheDefaultsKey)
    }

    // MARK: - Project derivation

    /// Derive a display project name from a session `cwd`: the last path component, or "Unknown".
    static func projectName(fromCWD cwd: String?) -> String {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Unknown" : name
    }

    // MARK: - Timestamp parsing (hot path)

    /// Parse Claude's `timestamp` field.
    ///
    /// The general decoder allocates an `ISO8601DateFormatter` per call, which is unaffordable at
    /// millions of entries, so the exact shape Claude writes — `YYYY-MM-DDTHH:MM:SS[.fff]Z` — gets a
    /// direct integer path. Anything else falls back to `ISO8601Decoder`, so no format is lost.
    nonisolated static func analyticsTimestamp(_ text: String) -> Date? {
        if let fast = Self.fastUTCTimestamp(text) { return fast }
        return ISO8601Decoder.date(from: text)
    }

    private nonisolated static func fastUTCTimestamp(_ text: String) -> Date? {
        let utf8 = text.utf8
        let parsed: Date?? = utf8.withContiguousStorageIfAvailable { buffer in
            Self.fastUTCTimestamp(buffer)
        }
        if let parsed { return parsed }
        // Non-contiguous storage (rare): copy once rather than give up on the fast path.
        return Array(text.utf8).withUnsafeBufferPointer { Self.fastUTCTimestamp($0) }
    }

    private nonisolated static func fastUTCTimestamp(_ buffer: UnsafeBufferPointer<UInt8>) -> Date? {
        // Minimum shape: "2026-08-24T12:34:56Z" — 19 characters plus a zone marker.
        guard buffer.count >= 20 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start..<(start + count) {
                let byte = buffer[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard buffer[4] == 0x2D, buffer[7] == 0x2D, buffer[10] == 0x54, // '-', '-', 'T'
              buffer[13] == 0x3A, buffer[16] == 0x3A,                   // ':', ':'
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31,
              hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < buffer.count, buffer[index] == 0x2E { // '.'
            index += 1
            var scale = 0.1
            var seen = 0
            while index < buffer.count, buffer[index] >= 0x30, buffer[index] <= 0x39 {
                fraction += Double(buffer[index] - 0x30) * scale
                scale /= 10
                index += 1
                seen += 1
            }
            guard seen > 0 else { return nil }
        }
        // Only the UTC form is handled here; offsets fall back to the general decoder.
        guard index == buffer.count - 1, buffer[index] == 0x5A else { return nil } // 'Z'

        let days = Self.daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400 + Double(hour) * 3_600 + Double(minute) * 60 + Double(second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Days between 1970-01-01 and the given proleptic-Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Exact for every date the logs can contain, and branch-cheap.
    private nonisolated static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                    // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    // MARK: - Constants (analytics-local to avoid touching the popover scanner's privates)

    static let analyticsMaxLineBytes = 1024 * 1024
    // No retention constant: the archive keeps every day it has ever seen. `windowDays` is a read
    // filter applied at aggregation, not a horizon the stored data is trimmed to.
    /// How recently a log must have been written for its dedup ledger to be worth keeping.
    static let analyticsLedgerRetentionDays = 3
    /// Hard cap on retained ledgers, so the persisted blob cannot grow without bound.
    static let analyticsMaxLedgerFiles = 48
    /// `UserDefaults` key for the persisted analytics bucket cache.
    static let analyticsCacheDefaultsKey = "costScanner.analyticsCache"
    /// How many orphaned copies of the same archive version to keep before stopping. A bound, not a
    /// policy: reaching it means something is repeatedly failing, and the *older* copies are the
    /// ones worth protecting at that point.
    static let analyticsMaxOrphanCopies = 5

    private static let analyticsAssistantMarker = Array(#""type":"assistant""#.utf8)
    private static let analyticsUsageMarker = Array(#""usage""#.utf8)

    private static func analyticsInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }
}

// MARK: - Aggregation keys

/// Key for the per-project fold. Model is carried so cost can be priced per model before summing.
struct ProjectModelKey: Hashable, Sendable {
    let project: String
    let model: String
}

/// Key for the per-session fold, for the same reason.
struct SessionModelKey: Hashable, Sendable {
    let session: String
    let model: String
}
