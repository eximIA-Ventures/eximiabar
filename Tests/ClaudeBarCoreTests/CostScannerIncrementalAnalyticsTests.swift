import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-5.6 — the persisted incremental analytics cache.
///
/// The scan no longer re-reads the whole history on every open: unchanged files are skipped, grown
/// files resume at their last byte offset, and the window is applied as a filter over cached days.
/// Every shortcut there is a chance to report the wrong number, so the suite is built around one
/// question: **does the incremental path produce exactly what a from-scratch scan produces?**
///
/// The pivot is `equivalent(...)`, which runs the same fixture through a virgin scanner (its own
/// `UserDefaults` suite, so nothing is cached) and compares the whole `UsageAnalytics`. A test that
/// only checked "the number looks plausible" would pass on a cache that quietly drops a file.
struct CostScannerIncrementalAnalyticsTests {
    // MARK: - Fixture helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exbincr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeDefaults() -> CostDefaults {
        CostDefaults(UserDefaults(suiteName: "exbincr.\(UUID().uuidString)")!)
    }

    /// `Pricing` pinned to the hardcoded fallback table (no network), so cost is deterministic.
    private static func fallbackPricing(_ defaults: CostDefaults) -> Pricing {
        Pricing(
            transport: StubTransport(error: URLError(.notConnectedToInternet)),
            defaults: defaults,
            networkEnabled: false)
    }

    private static func makeScanner(_ defaults: CostDefaults) -> CostScanner {
        CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
    }

    private static func line(
        messageId: String,
        requestId: String?,
        model: String = "claude-sonnet-4",
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cwd: String = "/work/proj",
        sessionId: String = "s1",
        timestamp: Date) -> String
    {
        var obj: [String: Any] = [
            "type": "assistant",
            "timestamp": Self.iso(timestamp),
            "cwd": cwd,
            "sessionId": sessionId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheWrite,
                ],
            ],
        ]
        if let requestId { obj["requestId"] = requestId }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
    }

    /// Append to an existing log the way Claude Code does — the case the byte-offset resume exists for.
    private static func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: (lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    /// What a scanner with **no** cache at all sees for this directory — the reference result.
    private static func freshScan(_ dir: URL, windowDays: Int, now: Date) async -> UsageAnalytics {
        let defaults = Self.makeDefaults()
        return await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: windowDays, now: now)
    }

    /// A **named** local instant, for fixtures that reach backwards by *hours*.
    ///
    /// `Date()` makes such a fixture answer a different question depending on when the suite runs: a
    /// two-hour reach crosses local midnight between 00:00 and 02:00, and the fixture then spans two
    /// days instead of one. Measured by pinning this whole file's clock hour by hour — the suite is
    /// green at 02:30 and later, red at 00:00, 00:30 and 01:30.
    ///
    /// Whole-day offsets (`byAdding: .day`) do not need this: they preserve the hour, so they land on
    /// the same side of midnight whenever the suite runs.
    private static func pinned(hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: hour, minute: 0, second: 0))!
    }

    // MARK: - Equivalence: incremental result == from-scratch result

    /// Two appends, three scans, against one virgin scan of the final file. This is the core
    /// contract: resuming at a byte offset must not change a single number.
    @Test
    func incrementalScanMatchesFullScanAfterAppends() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3_600)

        let scanner = Self.makeScanner(Self.makeDefaults())

        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: hourAgo),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m2", requestId: "r2", input: 200, output: 80, cacheRead: 900, timestamp: hourAgo),
            Self.line(messageId: "m3", requestId: "r3", model: "claude-opus-4", input: 10, output: 5, timestamp: now),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m4", requestId: "r4", input: 7, output: 3, cwd: "/work/other", sessionId: "s2", timestamp: now),
        ], to: url)
        let incremental = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        let full = await Self.freshScan(dir, windowDays: 30, now: now)
        #expect(incremental == full)
        // Guard against the degenerate pass where both sides are empty.
        #expect(!full.byDayModel.isEmpty)
        #expect(full.byProject.count == 2)
    }

    /// An unchanged file must contribute the same numbers on a second scan — not zero (cache
    /// dropped), not double (cache added on top of itself).
    @Test
    func rescanningAnUnchangedFileIsIdempotent() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now),
            Self.line(messageId: "m2", requestId: "r2", input: 300, output: 150, timestamp: now),
        ], to: url)

        let scanner = Self.makeScanner(Self.makeDefaults())
        let first = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let second = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let third = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(first == second)
        #expect(second == third)
        #expect(first.byDayModel.first?.inputTokens == 400)
        #expect(first.byDayModel.first?.outputTokens == 200)
    }

    /// The persisted blob — not just the in-memory copy — must carry the whole state: a brand new
    /// scanner sharing only the `UserDefaults` store reproduces the result.
    @Test
    func persistedCacheSurvivesANewScannerInstance() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 120, output: 60, cacheRead: 40, cacheWrite: 20, timestamp: now),
            Self.line(messageId: "m2", requestId: "r2", model: "claude-opus-4", input: 8, output: 4, sessionId: "s2", timestamp: now),
        ], to: url)

        let first = await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: 30, now: now)
        // A different actor instance, same store: everything must come back off the persisted blob.
        let reopened = await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(first == reopened)
        #expect(first == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }

    // MARK: - Dedup across the resume boundary

    /// The failure mode the ledger exists for: a message's later streaming chunk lands in a byte
    /// range read *after* its earlier chunk was already folded into the cache.
    ///
    /// A whole-file parse dedups those in one dictionary. A resumed parse cannot — unless it
    /// remembers what the earlier chunk contributed. Expected totals are the **last** chunk's
    /// (600/300), never the sum (700/350) and never the first (100/50).
    @Test
    func supersededStreamingChunkAcrossScansIsNotDoubleCounted() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        let scanner = Self.makeScanner(Self.makeDefaults())

        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now),
        ], to: url)
        let afterFirstChunk = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(afterFirstChunk.byDayModel.first?.inputTokens == 100)

        // Same messageId:requestId, cumulative totals — exactly how Claude re-writes a streaming
        // response. Written in a second scan so it can only be reconciled via the persisted ledger.
        try Self.append([
            Self.line(messageId: "m1", requestId: "r1", input: 600, output: 300, timestamp: now),
        ], to: url)
        let afterSupersede = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(afterSupersede.byDayModel.count == 1)
        #expect(afterSupersede.byDayModel.first?.inputTokens == 600)
        #expect(afterSupersede.byDayModel.first?.outputTokens == 300)
        #expect(afterSupersede == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }

    /// The same supersede, but the later chunk lands in a *different* hour — so the earlier chunk's
    /// bucket must be emptied and removed, not merely reduced. A leaked empty bucket would show up
    /// as a phantom cell in the heatmap.
    @Test
    func supersededChunkInAnotherHourLeavesNoGhostBucket() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        // Noon, so "another hour" is another hour of the **same day** — which is what this test is
        // about. With `Date()` here it silently became "another day" between 00:00 and 02:00, and
        // then it was asserting something else entirely; see the sibling test below.
        let now = Self.pinned(hour: 12)
        let earlier = now.addingTimeInterval(-7_200)

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: earlier),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now),
        ], to: url)
        let result = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // Exactly one populated heatmap cell, holding the whole 150 tokens.
        let populated = result.heatmap.flatMap { $0 }.filter { $0.tokens > 0 }
        #expect(populated.count == 1)
        #expect(populated.first?.tokens == 150)
        #expect(result == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }


    /// The same supersede, but deliberately **across local midnight** — and the reason the sibling
    /// above could not stay on a live clock.
    ///
    /// This is what the old test was accidentally asserting between 00:00 and 02:00, and it fails
    /// there for a reason that is not a bug: **coverage is monotone**. The incremental scanner
    /// vouched for the previous day when it first saw a bucket there; the supersede then moved that
    /// usage to today and the bucket vanished, but `recordCoverage` unions and never retracts — "a
    /// day the app once watched does not become unknowable". A fresh scanner reading only the final
    /// file never saw that day at all.
    ///
    /// So across a day boundary the incremental and the from-scratch results **legitimately differ,
    /// in coverage and nowhere else**. Asserting whole-struct equality there reports a defect that
    /// does not exist — which is exactly what happened, at 00:56 in Tokyo.
    ///
    /// What must still hold, and does: no ghost bucket. That invariant is the point of the pair.
    @Test
    func supersededChunkAcrossLocalMidnightLeavesNoGhostBucketEither() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        // 01:00 minus two hours is 23:00 *yesterday*, in every time zone, by construction.
        let now = Self.pinned(hour: 1)
        let earlier = now.addingTimeInterval(-7_200)
        let calendar = Calendar.current
        // Control on the fixture itself: if these ever land on the same day the test is vacuous.
        #expect(calendar.startOfDay(for: earlier) != calendar.startOfDay(for: now))

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: earlier),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now),
        ], to: url)
        let result = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let fresh = await Self.freshScan(dir, windowDays: 30, now: now)

        // The invariant the pair exists for, unaffected by the boundary.
        let populated = result.heatmap.flatMap { $0 }.filter { $0.tokens > 0 }
        #expect(populated.count == 1)
        #expect(populated.first?.tokens == 150)

        // Everything a chart draws agrees with the from-scratch scan.
        #expect(result.byDayModel == fresh.byDayModel)
        #expect(result.byProject == fresh.byProject)
        #expect(result.heatmap == fresh.heatmap)
        #expect(result.topSessions == fresh.topSessions)
        #expect(result.sessions == fresh.sessions)
        #expect(result.byDayProject == fresh.byDayProject)
        #expect(result.monthToDateTokens == fresh.monthToDateTokens)

        // …and the one documented divergence, in the direction only monotone coverage can produce:
        // the incremental scanner remembers watching yesterday, the fresh one never did.
        #expect(result.coveredDays.isSuperset(of: fresh.coveredDays))
        #expect(result.coveredDays.count == fresh.coveredDays.count + 1)
        #expect(result.coveredDays.contains(calendar.startOfDay(for: earlier)))
        #expect(fresh.coveredDays.contains(calendar.startOfDay(for: earlier)) == false)
        // Which is why whole-struct equality is the wrong assertion at a boundary, and holds away
        // from one — the sibling above proves the other half.
        #expect(result != fresh)
    }

    /// Lines with no `messageId`/`requestId` (older logs) are deliberately *not* deduped — each is
    /// distinct usage. The ledger must not start collapsing them.
    @Test
    func unkeyedLinesAccumulateAcrossScans() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "m1", requestId: nil, input: 100, output: 50, timestamp: now),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m1", requestId: nil, input: 100, output: 50, timestamp: now),
        ], to: url)
        let result = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(result.byDayModel.first?.inputTokens == 200)
        #expect(result == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }

    // MARK: - Truncation / rotation

    /// A file that **shrank** was rewritten, so its cached byte offset is meaningless. The record
    /// must be discarded and the file re-read from zero — the old contribution must not survive.
    @Test
    func truncatedFileIsRereadFromZero() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "m1", requestId: "r1", input: 1_000, output: 500, timestamp: now),
            Self.line(messageId: "m2", requestId: "r2", input: 2_000, output: 900, timestamp: now),
            Self.line(messageId: "m3", requestId: "r3", input: 3_000, output: 700, timestamp: now),
        ], to: url)
        let before = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(before.byDayModel.first?.inputTokens == 6_000)

        // Rotation: same path, shorter content, entirely different usage.
        try Self.write([
            Self.line(messageId: "z1", requestId: "q1", input: 5, output: 2, timestamp: now),
        ], to: url)
        let after = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(after.byDayModel.count == 1)
        #expect(after.byDayModel.first?.inputTokens == 5)
        #expect(after.byDayModel.first?.outputTokens == 2)
        #expect(after == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }

    // MARK: - The archive: a deleted transcript must not delete the history

    /// The defect this whole design exists to prevent: Claude Code's retention deleted five months
    /// of this machine's cost history, and the app — a mere reader of those files — lost it too.
    ///
    /// So when a log vanishes, the usage it already contributed **stays**. Note the deliberate
    /// asymmetry with `freshScan`: a scanner with no archive can only report what is on disk, so the
    /// two are *expected* to disagree here. That disagreement is the feature.
    @Test
    func deletedFileKeepsItsContributionInTheArchive() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("keep.jsonl")
        let drop = dir.appendingPathComponent("drop.jsonl")
        let now = Date()

        try Self.write([Self.line(messageId: "k", requestId: "1", input: 10, output: 5, timestamp: now)], to: keep)
        try Self.write([
            Self.line(messageId: "d", requestId: "2", input: 900, output: 400, sessionId: "s2", timestamp: now),
        ], to: drop)

        let scanner = Self.makeScanner(Self.makeDefaults())
        let both = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(both.byDayModel.first?.inputTokens == 910)

        try FileManager.default.removeItem(at: drop)
        let afterDeletion = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // Same numbers as before the deletion — the transcript is gone, the history is not.
        #expect(afterDeletion.byDayModel.first?.inputTokens == 910)
        #expect(afterDeletion.byDayModel.first?.outputTokens == 405)
        #expect(afterDeletion.topSessions.count == 2)
        // A cache-less scanner sees only the surviving file: proof the 910 came from the archive and
        // not from the disk.
        let diskOnly = await Self.freshScan(dir, windowDays: 30, now: now)
        #expect(diskOnly.byDayModel.first?.inputTokens == 10)
    }

    /// The vanished file's numbers must survive a process restart too — otherwise the archive is
    /// only as durable as the app's uptime.
    @Test
    func archivedContributionSurvivesANewScannerInstance() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("keep.jsonl")
        let drop = dir.appendingPathComponent("drop.jsonl")
        let now = Date()
        let defaults = Self.makeDefaults()

        try Self.write([Self.line(messageId: "k", requestId: "1", input: 10, output: 5, timestamp: now)], to: keep)
        try Self.write([
            Self.line(messageId: "d", requestId: "2", input: 900, output: 400, sessionId: "s2", timestamp: now),
        ], to: drop)

        _ = await Self.makeScanner(defaults).scanAnalytics(directories: [dir], windowDays: 30, now: now)
        try FileManager.default.removeItem(at: drop)

        let reopened = await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(reopened.byDayModel.first?.inputTokens == 910)
    }

    /// The hazard the archive's per-path attribution exists for: a log recreated at a path that was
    /// already archived. Keeping the archived contribution *and* parsing the new file would count
    /// that path twice.
    @Test
    func recreatedFileAtAnArchivedPathIsNotCountedTwice() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: now),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try FileManager.default.removeItem(at: url)
        let archivedOnly = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(archivedOnly.byDayModel.first?.inputTokens == 100)

        // Same path comes back, carrying the same entry plus a new one.
        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: now),
            Self.line(messageId: "b", requestId: "2", input: 7, output: 3, timestamp: now),
        ], to: url)
        let recreated = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // 107, not 207: the archived generation was withdrawn before the file was parsed again.
        #expect(recreated.byDayModel.first?.inputTokens == 107)
        #expect(recreated.byDayModel.first?.outputTokens == 53)
    }

    /// `resetCaches()` must force a re-read without destroying what can no longer be re-read.
    @Test
    func resetCachesKeepsTheArchiveOfVanishedFiles() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("keep.jsonl")
        let drop = dir.appendingPathComponent("drop.jsonl")
        let now = Date()
        let defaults = Self.makeDefaults()

        try Self.write([Self.line(messageId: "k", requestId: "1", input: 10, output: 5, timestamp: now)], to: keep)
        try Self.write([
            Self.line(messageId: "d", requestId: "2", input: 900, output: 400, sessionId: "s2", timestamp: now),
        ], to: drop)

        let scanner = Self.makeScanner(defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        try FileManager.default.removeItem(at: drop)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        await scanner.resetCaches()
        let afterReset = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // The surviving file was re-read from zero and the vanished one's history is still there.
        #expect(afterReset.byDayModel.first?.inputTokens == 910)

        // The destructive variant is a separate, explicit act.
        await scanner.eraseAnalyticsArchive()
        let afterErase = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(afterErase.byDayModel.first?.inputTokens == 10)
    }

    // MARK: - Window expiry

    /// Read the persisted cache back out of the store the scanner was given.
    ///
    /// Expiry is invisible from the result alone — the aggregation filters by window anyway, so a
    /// bucket that should have been evicted still produces the right totals while quietly growing
    /// the cache forever. Asserting on the *result* would therefore pass on a scanner that never
    /// evicts anything; the only honest witness is the blob itself.
    private static func persistedCache(_ defaults: CostDefaults) -> AnalyticsCacheState? {
        guard let data = defaults.data(forKey: CostScanner.analyticsCacheDefaultsKey) else { return nil }
        return AnalyticsCacheCodec.decode(data)
    }

    private static func cachedDays(_ state: AnalyticsCacheState) -> Set<Date> {
        Set(state.files.values.flatMap { $0.buckets.keys.map(\.day) })
    }

    /// A day that aged past the dashboard's widest window must **stay in the archive**.
    ///
    /// This assertion is the exact inverse of what the scan did before EXB-5.7, and the inversion is
    /// deliberate: expiring the aggregate alongside the window is how the history evaporates the
    /// moment the source transcript is deleted. The window is now a read filter and nothing more,
    /// which is invisible from the result — hence the assertion on the persisted blob.
    @Test
    func daysNeverLeaveThePersistedArchive() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()
        let eightyDaysAgo = calendar.date(byAdding: .day, value: -80, to: now)!
        let oldDay = calendar.startOfDay(for: eightyDaysAgo)
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(messageId: "old", requestId: "1", input: 900, output: 400, sessionId: "old", timestamp: eightyDaysAgo),
            Self.line(messageId: "new", requestId: "2", input: 10, output: 5, sessionId: "new", timestamp: now),
        ], to: url)

        let scanner = Self.makeScanner(defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)
        let warm = try #require(Self.persistedCache(defaults))
        #expect(Self.cachedDays(warm).contains(oldDay))

        // A year later the entry is far outside every window the dashboard offers.
        let muchLater = calendar.date(byAdding: .day, value: 365, to: now)!
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: muchLater)

        let aged = try #require(Self.persistedCache(defaults))
        #expect(Self.cachedDays(aged).contains(oldDay))
        // And it is still readable by widening the window far enough.
        let wide = await scanner.scanAnalytics(directories: [dir], windowDays: 500, now: muchLater)
        #expect(wide.byDayModel.contains { $0.inputTokens == 900 })
    }

    // MARK: - Coverage: "no usage" is not "no data"

    /// A day inside the covered span with no usage is a real zero; a day before the archive ever saw
    /// anything is unknown. The panel draws those differently, so the scan has to tell them apart.
    @Test
    func coveredDaysSpanFromTheEarliestObservedDayToToday() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let firstDay = calendar.startOfDay(for: threeDaysAgo)

        // Usage three days ago and today; nothing on the two days between.
        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: threeDaysAgo),
            Self.line(messageId: "b", requestId: "2", input: 10, output: 5, timestamp: now),
        ], to: url)

        let analytics = await Self.freshScan(dir, windowDays: 30, now: now)

        // The gap days are covered — the archive was watching, so zero means zero.
        let dayBetween = calendar.date(byAdding: .day, value: -2, to: today)!
        #expect(analytics.coveredDays.contains(firstDay))
        #expect(analytics.coveredDays.contains(dayBetween))
        #expect(analytics.coveredDays.contains(today))
        // The day before the first observation is NOT covered: no data, not zero usage.
        let beforeFirst = calendar.date(byAdding: .day, value: -4, to: today)!
        #expect(!analytics.coveredDays.contains(beforeFirst))
    }

    /// Coverage is monotone: a day once vouched for stays vouched for after its transcript is gone,
    /// which is the only way "zero usage" keeps meaning anything for old days.
    @Test
    func coverageSurvivesTheDeletionOfTheSourceFile() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()
        let fiveDaysAgo = calendar.date(byAdding: .day, value: -5, to: now)!
        let oldDay = calendar.startOfDay(for: fiveDaysAgo)

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: fiveDaysAgo),
        ], to: url)
        let before = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(before.coveredDays.contains(oldDay))

        try FileManager.default.removeItem(at: url)
        let after = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(after.coveredDays.contains(oldDay))
    }

    /// An archive that has never seen anything must not claim to cover anything.
    @Test
    func anEmptyArchiveCoversNothing() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let analytics = await Self.freshScan(dir, windowDays: 30, now: Date())
        #expect(analytics.coveredDays.isEmpty)
        #expect(analytics.byDayModel.isEmpty)
    }

    // MARK: - Month-to-date tokens

    /// The monthly projection is a projection of **tokens**, so the month's volume is summed here
    /// rather than derived downstream from cost by a tokens÷cost ratio — that ratio is wrong
    /// whenever the month's model mix differs from the window's.
    @Test
    func monthToDateTokensSumsAllFourTokenTypesWithinTheMonth() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current

        // Pin `now` to the 15th at noon so "before the 1st" is unambiguous.
        var components = calendar.dateComponents([.year, .month], from: Date())
        components.day = 15
        components.hour = 12
        let now = calendar.date(from: components)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let lastMonth = calendar.date(byAdding: .day, value: -2, to: monthStart)!
        let thisMonth = calendar.date(byAdding: .day, value: 2, to: monthStart)!

        try Self.write([
            // Inside the month: 1 + 2 + 4 + 8 = 15 tokens.
            Self.line(
                messageId: "in", requestId: "1", input: 1, output: 2, cacheRead: 4, cacheWrite: 8,
                sessionId: "a", timestamp: thisMonth),
            // Before the 1st: must not count, despite being well inside the 90-day window.
            Self.line(
                messageId: "out", requestId: "2", input: 1_000, output: 1_000,
                cacheRead: 1_000, cacheWrite: 1_000, sessionId: "b", timestamp: lastMonth),
        ], to: url)

        let analytics = await Self.freshScan(dir, windowDays: 90, now: now)

        // Both entries are in the window…
        #expect(analytics.byDayModel.count == 2)
        // …but only the one on this side of the 1st is in the month.
        #expect(analytics.monthToDateTokens == 15)
        #expect(analytics.monthToDateCost > 0)
    }

    /// Month-to-date must span the whole month so far, whatever period is on screen.
    ///
    /// It used to be folded inside the window filter, making it "this month ∩ the selected period".
    /// On the 24th with a 7-day window it counted 7 days, and `monthProjection`, which divides by 24
    /// elapsed days, came out about three times too low. The number looked perfectly plausible — it
    /// was answering a different question from the one its name asks. It must also be independent of
    /// the slice, or dragging the range selector would move "this month's" projection.
    @Test
    func monthToDateIgnoresTheSelectedPeriod() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current

        // Pin `now` to the 25th so a 7-day window covers only the 19th onward — a fraction of the month.
        var components = calendar.dateComponents([.year, .month], from: Date())
        components.day = 25
        components.hour = 12
        let now = calendar.date(from: components)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        // One entry on the 2nd (inside the month, outside a 7-day window) and one on the 25th.
        try Self.write([
            Self.line(
                messageId: "early", requestId: "1", input: 1_000, output: 0, sessionId: "a",
                timestamp: calendar.date(byAdding: .day, value: 1, to: monthStart)!),
            Self.line(
                messageId: "late", requestId: "2", input: 7, output: 0, sessionId: "b", timestamp: now),
        ], to: dir.appendingPathComponent("session.jsonl"))

        let scanner = Self.makeScanner(Self.makeDefaults())

        let week = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)
        // The 7-day view shows only the recent entry…
        #expect(week.byDayModel.count == 1)
        // …but the month total covers both. 1007, not 7.
        #expect(week.monthToDateTokens == 1_007)

        // And a wider window agrees — the figure does not depend on what is on screen.
        let month = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)
        #expect(month.monthToDateTokens == 1_007)
        #expect(abs(month.monthToDateCost - week.monthToDateCost) < 1e-12)

        // Same through the range door, including a slice that excludes the early entry entirely.
        let today = calendar.startOfDay(for: now)
        let lastThree = await scanner.analytics(
            in: calendar.date(byAdding: .day, value: -2, to: today)!...today, now: now)
        #expect(lastThree.byDayModel.count == 1)
        #expect(lastThree.monthToDateTokens == 1_007)
    }

    /// Superseded (`messageId:requestId`) chunks must not inflate the month either.
    @Test
    func monthToDateTokensRespectsDedup() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        let scanner = Self.makeScanner(Self.makeDefaults())
        try Self.write([
            Self.line(messageId: "m", requestId: "r", input: 1, output: 1, cacheRead: 1, cacheWrite: 1, timestamp: now),
        ], to: url)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        try Self.append([
            Self.line(messageId: "m", requestId: "r", input: 10, output: 10, cacheRead: 10, cacheWrite: 10, timestamp: now),
        ], to: url)
        let result = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // 40 (the surviving chunk), not 44 (both) and not 4 (the first).
        #expect(result.monthToDateTokens == 40)
    }

    /// The result-level view of ageing: a day outside the window is filtered from the answer even
    /// though it is still in the archive.
    @Test
    func daysThatLeaveTheWindowAreFilteredFromTheResult() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()
        let eightyDaysAgo = calendar.date(byAdding: .day, value: -80, to: now)!

        try Self.write([
            Self.line(messageId: "old", requestId: "1", input: 900, output: 400, sessionId: "old", timestamp: eightyDaysAgo),
            Self.line(messageId: "new", requestId: "2", input: 10, output: 5, sessionId: "new", timestamp: now),
        ], to: url)

        let scanner = Self.makeScanner(Self.makeDefaults())
        let atStart = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)
        #expect(atStart.byDayModel.count == 2)

        // Twenty days later the −80 d entry sits at −100 d: outside the 90-day window.
        let later = calendar.date(byAdding: .day, value: 20, to: now)!
        let aged = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: later)

        #expect(aged.byDayModel.count == 1)
        #expect(aged.byDayModel.first?.inputTokens == 10)
        #expect(aged.topSessions.map(\.sessionId) == ["new"])
        // Filtered from the answer, still in the archive: widening the window brings it back.
        let wide = await scanner.scanAnalytics(directories: [dir], windowDays: 200, now: later)
        #expect(wide.byDayModel.count == 2)
    }

    // MARK: - One scan serves every window

    /// Warming at 7 d must still populate the full retention, so widening the period is a filter and
    /// not a re-read.
    ///
    /// The proof is a **content swap that preserves size and mtime**: the scanner decides a file is
    /// unchanged from exactly those two attributes, so after the swap any file it actually re-reads
    /// would report the new payload. The 90 d result still reporting the *original* payload is the
    /// evidence that no bytes were read — and the 7 d scan having already seen the 60-day-old entry
    /// is the evidence that the first scan warmed the whole retention.
    @Test
    func wideningThePeriodAfterANarrowScanReadsNoBytes() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()
        let sixtyDaysAgo = calendar.date(byAdding: .day, value: -60, to: now)!

        let original = [
            Self.line(messageId: "recent", requestId: "1", input: 100, output: 50, sessionId: "a", timestamp: now),
            Self.line(messageId: "older", requestId: "2", input: 700, output: 300, sessionId: "b", timestamp: sixtyDaysAgo),
        ]
        try Self.write(original, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalModified = attributes[.modificationDate] as! Date
        let originalSize = attributes[.size] as! Int

        let scanner = Self.makeScanner(Self.makeDefaults())
        let week = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)
        #expect(week.byDayModel.count == 1) // only the recent entry is inside 7 days

        // Same byte count, same mtime, different numbers. `900` and `100` are both 3 and 3 digits,
        // and `400`/`50` differ in length, so pad the replacement to keep the size identical.
        let swapped = [
            Self.line(messageId: "recent", requestId: "1", input: 111, output: 55, sessionId: "a", timestamp: now),
            Self.line(messageId: "older", requestId: "2", input: 777, output: 333, sessionId: "b", timestamp: sixtyDaysAgo),
        ]
        try Self.write(swapped, to: url)
        let swappedSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(swappedSize == originalSize) // the ruse only works if the size really is unchanged
        try FileManager.default.setAttributes([.modificationDate: originalModified], ofItemAtPath: url.path)

        let quarter = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)

        // Both days are present — so the 7-day scan had already read the 60-day-old entry — and the
        // numbers are the ORIGINAL ones, so the 90-day scan opened no file.
        #expect(quarter.byDayModel.count == 2)
        #expect(quarter.byDayModel.map(\.inputTokens).sorted() == [100, 700])
    }

    /// Narrowing the period must genuinely filter the warmed cache, not hand back the wide result.
    @Test
    func narrowingThePeriodFiltersTheWarmedCache() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let calendar = Calendar.current
        let now = Date()

        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, sessionId: "a", timestamp: now),
            Self.line(
                messageId: "b", requestId: "2", input: 200, output: 100, sessionId: "b",
                timestamp: calendar.date(byAdding: .day, value: -15, to: now)!),
            Self.line(
                messageId: "c", requestId: "3", input: 400, output: 200, sessionId: "c",
                timestamp: calendar.date(byAdding: .day, value: -60, to: now)!),
        ], to: url)

        let scanner = Self.makeScanner(Self.makeDefaults())
        let quarter = await scanner.scanAnalytics(directories: [dir], windowDays: 90, now: now)
        let month = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let week = await scanner.scanAnalytics(directories: [dir], windowDays: 7, now: now)

        #expect(quarter.byDayModel.count == 3)
        #expect(month.byDayModel.count == 2)
        #expect(week.byDayModel.count == 1)
        // And each must match what a scanner with no cache at all would say for that window.
        #expect(month == (await Self.freshScan(dir, windowDays: 30, now: now)))
        #expect(week == (await Self.freshScan(dir, windowDays: 7, now: now)))
    }

    // MARK: - Multi-file / parallel parse determinism

    /// The parse runs in a task group, so file completion order varies run to run. The aggregate
    /// must not: repeated scans of the same many-file fixture have to be bit-identical, including
    /// the `Double` costs.
    @Test
    func manyFilesAggregateDeterministically() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        for index in 0..<40 {
            try Self.write([
                Self.line(
                    messageId: "m\(index)", requestId: "r\(index)",
                    model: index.isMultiple(of: 3) ? "claude-opus-4" : "claude-sonnet-4",
                    input: 100 + index, output: 50 + index,
                    cacheRead: index * 7, cacheWrite: index,
                    cwd: "/work/p\(index % 4)", sessionId: "s\(index % 5)",
                    timestamp: now.addingTimeInterval(Double(-index) * 600)),
            ], to: dir.appendingPathComponent("session-\(index).jsonl"))
        }

        let first = await Self.freshScan(dir, windowDays: 30, now: now)
        let second = await Self.freshScan(dir, windowDays: 30, now: now)
        let third = await Self.freshScan(dir, windowDays: 30, now: now)

        #expect(first == second)
        #expect(second == third)
        #expect(first.byProject.count == 4)
        #expect(first.topSessions.count == 5)
    }

    // MARK: - Fingerprint

    /// The fingerprint used to be the *root directories'* mtimes, which change whenever Claude Code
    /// opens a session — so the dashboard threw its cache away while the user was working. It must
    /// be stable when no log changed, and move when one does.
    @Test
    func fingerprintIsStableUntilAFileActuallyChanges() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()

        try Self.write([Self.line(messageId: "m1", requestId: "r1", input: 10, output: 5, timestamp: now)], to: url)
        let before = CostScanner.sourceFingerprint(directories: [dir], now: now)
        #expect(before == CostScanner.sourceFingerprint(directories: [dir], now: now))

        // A brand-new sibling session file bumps the directory mtime *and* the fingerprint — this one
        // is a real change, and must be seen.
        try Self.write(
            [Self.line(messageId: "m2", requestId: "r2", input: 20, output: 9, timestamp: now)],
            to: dir.appendingPathComponent("other.jsonl"))
        let after = CostScanner.sourceFingerprint(directories: [dir], now: now)
        #expect(after != before)
    }

    /// The fingerprint feeds cache invalidation across app launches, so it must not be derived from
    /// anything process-seeded (`Hasher` is).
    @Test
    func fingerprintIsProcessIndependent() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 10, output: 5, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))

        // Same inputs, recomputed — a seeded hash would differ here about half the time.
        let a = CostScanner.sourceFingerprint(directories: [dir], now: now)
        let b = CostScanner.sourceFingerprint(directories: [dir], now: now)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    /// `scanAnalyticsResult` gives the dashboard both halves from one walk; the fingerprint it
    /// reports must be the same one the standalone helper computes.
    @Test
    func scanResultCarriesTheSameFingerprintAsTheHelper() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 10, output: 5, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))

        let result = await Self.makeScanner(Self.makeDefaults())
            .scanAnalyticsResult(directories: [dir], windowDays: 30, now: now)
        #expect(result.fingerprint == CostScanner.sourceFingerprint(directories: [dir], now: now))
        #expect(result.analytics.byDayModel.count == 1)
    }

    // MARK: - Timestamp fast path

    /// The scan swapped `ISO8601DateFormatter` (one allocation per entry) for a direct integer
    /// parse. It must agree with the general decoder exactly, and fall back for anything it does
    /// not handle rather than inventing a date.
    @Test
    func fastTimestampParserAgreesWithTheGeneralDecoder() {
        let samples = [
            "2026-08-24T12:34:56.789Z",
            "2026-08-24T12:34:56Z",
            "2026-01-01T00:00:00.000Z",
            "2026-12-31T23:59:59.999Z",
            "2024-02-29T06:07:08.123Z", // leap day
            "2000-02-29T00:00:00Z",     // leap century
            "1999-12-31T23:59:59Z",
            "2026-08-24T12:34:56+03:00", // offset — must fall back, not be misread as UTC
        ]
        for sample in samples {
            let fast = CostScanner.analyticsTimestamp(sample)
            let reference = ISO8601Decoder.date(from: sample)
            #expect(fast != nil, "no date for \(sample)")
            #expect(reference != nil, "reference could not parse \(sample)")
            if let fast, let reference {
                #expect(abs(fast.timeIntervalSince1970 - reference.timeIntervalSince1970) < 0.0005,
                        "mismatch on \(sample): \(fast) vs \(reference)")
            }
        }
    }

    @Test
    func fastTimestampParserRejectsGarbage() {
        #expect(CostScanner.analyticsTimestamp("") == nil)
        #expect(CostScanner.analyticsTimestamp("not-a-date") == nil)
        #expect(CostScanner.analyticsTimestamp("2026-13-99T99:99:99Z") == nil)
        #expect(CostScanner.analyticsTimestamp("2026-08-24") == nil)
    }

    // MARK: - Cache codec

    /// The persisted blob interns model / project / session names. A round trip has to give back
    /// exactly what went in, including which files had a dedup ledger and which did not.
    @Test
    func cacheCodecRoundTripsBucketsAndLedger() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let key = AnalyticsBucketKey(day: day, hour: 14, model: "claude-opus-4", project: "proj", session: "sess")
        let totals = AnalyticsBucketTotals(
            inputTokens: 11, outputTokens: 22, cacheReadTokens: 33, cacheWriteTokens: 44,
            firstTimestamp: day.addingTimeInterval(50_400))

        var state = AnalyticsCacheState()
        state.files["/tmp/a.jsonl"] = AnalyticsFileRecord(
            size: 123, modified: day, endOffset: 99, buckets: [key: totals],
            ledger: ["m:r": AnalyticsLedgerEntry(offset: 7, bucket: key, totals: totals)])
        state.files["/tmp/b.jsonl"] = AnalyticsFileRecord(
            size: 4, modified: day, endOffset: 4, buckets: [:], ledger: nil)

        let data = try #require(AnalyticsCacheCodec.encode(state))
        let decoded = try #require(AnalyticsCacheCodec.decode(data))

        #expect(decoded.files.count == 2)
        let a = try #require(decoded.files["/tmp/a.jsonl"])
        #expect(a.size == 123)
        #expect(a.endOffset == 99)
        #expect(a.buckets[key] == totals)
        #expect(a.ledger?["m:r"]?.offset == 7)
        #expect(a.ledger?["m:r"]?.bucket == key)
        let b = try #require(decoded.files["/tmp/b.jsonl"])
        #expect(b.ledger == nil)
        #expect(b.buckets.isEmpty)
    }

    /// The archive of vanished files and the coverage set are the two things a rescan cannot
    /// reconstruct. If the codec dropped either, nothing would look broken until the day someone
    /// needed the history — so they get their own round trip.
    @Test
    func cacheCodecRoundTripsTheArchiveAndCoverage() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)!
        let key = AnalyticsBucketKey(
            day: previousDay, hour: 9, model: "claude-sonnet-4", project: "gone", session: "old")
        let totals = AnalyticsBucketTotals(
            inputTokens: 5, outputTokens: 6, cacheReadTokens: 7, cacheWriteTokens: 8,
            firstTimestamp: previousDay)

        var state = AnalyticsCacheState()
        state.archived["/tmp/deleted.jsonl"] = [key: totals]
        state.coveredDays = [previousDay, day]

        let data = try #require(AnalyticsCacheCodec.encode(state))
        let decoded = try #require(AnalyticsCacheCodec.decode(data))

        #expect(decoded.archived.count == 1)
        // Still keyed by the original path — that is what lets a recreated log be reconciled
        // instead of double-counted.
        #expect(decoded.archived["/tmp/deleted.jsonl"]?[key] == totals)
        #expect(decoded.coveredDays == [previousDay, day])
        #expect(decoded.allBuckets().flatMap(\.values).count == 1)
    }

    /// A blob from a future (or corrupt) schema must not be half-decoded into wrong numbers.
    @Test
    func cacheCodecRejectsAForeignBlob() {
        #expect(AnalyticsCacheCodec.decode(Data("not json".utf8)) == nil)
        #expect(AnalyticsCacheCodec.decode(Data(#"{"v":999,"models":[],"projects":[],"sessions":[],"files":[]}"#.utf8)) == nil)
    }

    // MARK: - Arbitrary date range (EXB-5.8) — the draggable selector's entry point

    /// Counts file-system probes on the injected `FileManager`.
    ///
    /// A subclass rather than a flag inside the scanner: the question is whether the range API
    /// touches the file system *at all*, and only something outside the scanner can answer that
    /// without taking the scanner's word for it.
    ///
    /// `fileExists(atPath:)` is the hook because it is the census's first act on every root — and
    /// because the obvious candidate, `enumerator(at:includingPropertiesForKeys:options:)`, is a
    /// Swift extension method on `FileManager` and cannot be overridden at all. Counting the gate
    /// the census must pass through is equivalent for this purpose: the walk cannot start without it.
    private final class CensusSpy: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var probes: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.count
        }

        override func fileExists(atPath path: String) -> Bool {
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
            return super.fileExists(atPath: path)
        }
    }

    /// The gate the draggable selector depends on: a drag emits dozens of events per second, so the
    /// range API must not walk the directory even once.
    ///
    /// Proved from outside the scanner, by counting enumerations on an injected `FileManager`. The
    /// scan is allowed its walk; every `analytics(in:)` after it must add nothing.
    @Test
    func repeatedRangeQueriesTouchTheFileSystemZeroTimes() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: now),
            Self.line(
                messageId: "b", requestId: "2", input: 200, output: 100, sessionId: "s2",
                timestamp: calendar.date(byAdding: .day, value: -10, to: now)!),
        ], to: dir.appendingPathComponent("session.jsonl"))

        // `FileManager` is not `Sendable`, so the spy needs an explicit opt-out to cross into the
        // actor. It is sound: every mutable field behind `CensusSpy` is guarded by its own lock.
        nonisolated(unsafe) let spy = CensusSpy()
        let scanner = CostScanner(
            pricing: Self.fallbackPricing(defaults), defaults: defaults, fileManager: spy)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        let afterScan = spy.probes
        #expect(afterScan > 0) // control: the spy does observe the scan's walk
        let blobAfterScan = defaults.data(forKey: CostScanner.analyticsCacheDefaultsKey)

        // Simulate a drag: many range queries in a row, each a different slice.
        let today = calendar.startOfDay(for: now)
        for offset in 1...25 {
            let from = calendar.date(byAdding: .day, value: -offset, to: today)!
            _ = await scanner.analytics(in: from...today, now: now)
        }

        #expect(spy.probes == afterScan)
        // Second, independent witness: the range API is read-only. Had it run the scan pipeline it
        // would have re-archived and re-persisted, and these bytes would differ.
        #expect(defaults.data(forKey: CostScanner.analyticsCacheDefaultsKey) == blobAfterScan)
    }

    /// Going through the range door must give exactly what going through the window door gives —
    /// in **all five dimensions**, not just the ones whose output structs carry a date.
    ///
    /// `byProject` and `heatmap` have no date in them, so a caller cannot slice those after the
    /// fact. If the range API returned them whole while the other three respected the range, the
    /// panel would render two different periods at once and say nothing. That is why the whole
    /// `UsageAnalytics` is compared here rather than a field or two.
    @Test
    func rangeQueryMatchesTheEquivalentWindowScan() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()

        for offset in [0, 3, 12, 29, 45] {
            try Self.write([
                Self.line(
                    messageId: "m\(offset)", requestId: "r\(offset)",
                    model: offset.isMultiple(of: 2) ? "claude-sonnet-4" : "claude-opus-4",
                    input: 100 + offset, output: 50 + offset,
                    cacheRead: offset * 11, cacheWrite: offset,
                    cwd: "/work/p\(offset % 3)", sessionId: "s\(offset)",
                    timestamp: calendar.date(byAdding: .day, value: -offset, to: now)!),
            ], to: dir.appendingPathComponent("session-\(offset).jsonl"))
        }

        let scanner = Self.makeScanner(Self.makeDefaults())
        let today = calendar.startOfDay(for: now)

        for days in [1, 7, 30, 90] {
            let viaWindow = await scanner.scanAnalytics(directories: [dir], windowDays: days, now: now)
            let earliest = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
            let viaRange = await scanner.analytics(in: earliest...today, now: now)
            #expect(viaRange == viaWindow, "range and window disagree for \(days)d")
        }

        // Guard against the degenerate pass where every comparison is empty-vs-empty.
        let thirty = await scanner.analytics(
            in: calendar.date(byAdding: .day, value: -29, to: today)!...today, now: now)
        #expect(thirty.byDayModel.count == 4) // offsets 0, 3, 12, 29 — the 45-day-old one is outside
        #expect(!thirty.byProject.isEmpty)
        #expect(thirty.topSessions.count == 4)
    }

    /// A slice that starts before the archive ever saw anything must not invent days: coverage is a
    /// claim about what was observed, and stretching it to fill the selector would be a lie the
    /// panel would draw as real zeros.
    @Test
    func rangeStartingBeforeCoverageDoesNotInventDays() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let firstDay = calendar.startOfDay(for: threeDaysAgo)

        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: threeDaysAgo),
        ], to: dir.appendingPathComponent("session.jsonl"))

        let scanner = Self.makeScanner(Self.makeDefaults())
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // Drag the handle far past the beginning of the record.
        let wayBack = calendar.date(byAdding: .day, value: -200, to: today)!
        let analytics = await scanner.analytics(in: wayBack...today, now: now)

        // Coverage starts where observation started, not where the selector was dragged to.
        #expect(analytics.coveredDays.min() == firstDay)
        #expect(analytics.coveredDays.count == 4) // −3 … today, inclusive
        #expect(!analytics.coveredDays.contains(wayBack))
        #expect(analytics.byDayModel.count == 1)
    }

    /// A slice entirely before any usage is empty, not a copy of the nearest data.
    @Test
    func rangeWhollyBeforeTheArchiveIsEmpty() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()

        try Self.write(
            [Self.line(messageId: "a", requestId: "1", input: 100, output: 50, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))
        let scanner = Self.makeScanner(Self.makeDefaults())
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        let from = calendar.date(byAdding: .day, value: -100, to: now)!
        let to = calendar.date(byAdding: .day, value: -50, to: now)!
        let analytics = await scanner.analytics(in: from...to, now: now)

        #expect(analytics.byDayModel.isEmpty)
        #expect(analytics.byProject.isEmpty)
        #expect(analytics.topSessions.isEmpty)
        #expect(analytics.coveredDays.isEmpty)
        #expect(analytics.heatmap.flatMap { $0 }.allSatisfy { $0.tokens == 0 })
        // Month-to-date is "this month" regardless of the slice, so it is NOT zeroed by an old range.
        #expect(analytics.monthToDateTokens > 0)
    }

    /// Both bounds are inclusive and snapped to start-of-day, so a range given as two mid-afternoon
    /// instants still contains the whole of both days.
    @Test
    func rangeBoundsAreInclusiveAtDayGranularity() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        try Self.write([
            Self.line(messageId: "a", requestId: "1", input: 10, output: 5, sessionId: "a", timestamp: yesterday),
            Self.line(messageId: "b", requestId: "2", input: 20, output: 9, sessionId: "b", timestamp: now),
        ], to: dir.appendingPathComponent("session.jsonl"))

        let scanner = Self.makeScanner(Self.makeDefaults())
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // Bounds are arbitrary instants inside those two days, not their midnights.
        let analytics = await scanner.analytics(in: yesterday...now, now: now)
        #expect(analytics.byDayModel.count == 2)

        // A single-day range, both bounds inside today, sees only today.
        let onlyToday = await scanner.analytics(in: now...now, now: now)
        #expect(onlyToday.byDayModel.count == 1)
        #expect(onlyToday.byDayModel.first?.inputTokens == 20)
    }

    // MARK: - An unreadable archive is preserved, never discarded

    /// The trap this closes: bumping `AnalyticsCacheCodec.version` used to *delete* the old blob.
    ///
    /// That was safe only while every bucket could be rebuilt from logs still on disk — and it stops
    /// being safe the moment Claude Code deletes its first transcript, silently, with nothing in the
    /// code able to notice the line was crossed. A maintainer bumping the constant for a perfectly
    /// good reason would erase unrecoverable history. So refusal must never destroy: the bytes move
    /// aside, byte-for-byte, and a migrator written later can still rescue them.
    @Test
    func unknownArchiveVersionIsPreservedNotDiscarded() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let defaults = Self.makeDefaults()

        // A blob from a build that does not exist yet.
        let future = Data(
            #"{"v":9999,"models":["m"],"projects":["p"],"sessions":["s"],"files":[],"archived":[],"covered":[]}"#.utf8)
        defaults.set(future, forKey: CostScanner.analyticsCacheDefaultsKey)

        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))
        let analytics = await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // The scan carried on with a fresh archive…
        #expect(analytics.byDayModel.first?.inputTokens == 100)
        // …and the bytes it could not read are still there, unchanged.
        let orphan = defaults.data(forKey: "\(CostScanner.analyticsCacheDefaultsKey).v9999.orphan")
        #expect(orphan == future)
        // The live key was rewritten with the new archive, which is only acceptable *because* the
        // old bytes were copied aside first.
        #expect(defaults.data(forKey: CostScanner.analyticsCacheDefaultsKey) != future)
    }

    /// Corruption is a different cause with the same consequence, so it gets the same protection —
    /// and the copy is filed under `unknown` rather than a version it never had.
    @Test
    func corruptArchiveIsPreservedNotDiscarded() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let defaults = Self.makeDefaults()

        let garbage = Data("this is not json at all".utf8)
        defaults.set(garbage, forKey: CostScanner.analyticsCacheDefaultsKey)

        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 7, output: 3, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))
        _ = await Self.makeScanner(defaults).scanAnalytics(directories: [dir], windowDays: 30, now: now)

        #expect(defaults.data(forKey: "\(CostScanner.analyticsCacheDefaultsKey).vunknown.orphan") == garbage)
    }

    /// A downgrade/upgrade cycle can orphan the same version twice. The second rescue must not
    /// consume the first — otherwise the mechanism that exists to prevent data loss becomes the
    /// thing that causes it.
    @Test
    func orphaningTheSameVersionTwiceKeepsBothCopies() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let defaults = Self.makeDefaults()
        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 1, output: 1, timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))

        let first = Data(
            #"{"v":9999,"models":["a"],"projects":[],"sessions":[],"files":[],"archived":[],"covered":[]}"#.utf8)
        defaults.set(first, forKey: CostScanner.analyticsCacheDefaultsKey)
        _ = await Self.makeScanner(defaults).scanAnalytics(directories: [dir], windowDays: 30, now: now)

        let second = Data(
            #"{"v":9999,"models":["b"],"projects":[],"sessions":[],"files":[],"archived":[],"covered":[]}"#.utf8)
        defaults.set(second, forKey: CostScanner.analyticsCacheDefaultsKey)
        _ = await Self.makeScanner(defaults).scanAnalytics(directories: [dir], windowDays: 30, now: now)

        let base = "\(CostScanner.analyticsCacheDefaultsKey).v9999.orphan"
        #expect(defaults.data(forKey: base) == first)
        #expect(defaults.data(forKey: "\(base).2") == second)
    }

    /// When a migration path exists it is taken, and nothing is orphaned — preservation is the
    /// fallback for what cannot be understood, not a substitute for understanding it.
    @Test
    func versionOneArchiveIsMigratedNotOrphaned() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        // Version 1's shape: no `archived`, no `covered`.
        let v1 = """
        {"v":1,"models":["claude-sonnet-4"],"projects":["proj"],"sessions":["s1"],"files":[\
        {"path":"/tmp/old.jsonl","size":10,"mod":\(day.timeIntervalSince1970),"end":10,"buckets":[\
        {"d":\(day.timeIntervalSince1970),"h":9,"m":0,"p":0,"s":0,"i":100,"o":50,"r":4,"w":2,\
        "t":\(day.timeIntervalSince1970)}]}]}
        """
        let result = AnalyticsCacheCodec.read(Data(v1.utf8))

        guard case let .migrated(state, from) = result else {
            Issue.record("expected a migration, got \(result)")
            return
        }
        #expect(from == 1)
        // The buckets came through intact…
        let record = try #require(state.files["/tmp/old.jsonl"])
        let key = AnalyticsBucketKey(
            day: day, hour: 9, model: "claude-sonnet-4", project: "proj", session: "s1")
        #expect(record.buckets[key]?.inputTokens == 100)
        #expect(record.buckets[key]?.cacheReadTokens == 4)
        // …and coverage was seeded from the days the buckets already prove were observed, since
        // version 1 had no coverage set to carry forward.
        #expect(state.coveredDays == [day])
    }

    /// The scanner must actually go through `read(_:)`: a v1 blob left in the store has to come back
    /// as data, not be quietly replaced by an empty archive.
    @Test
    func versionOneArchiveSurvivesAScan() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar.current
        let now = Date()
        let day = calendar.startOfDay(for: now)
        let defaults = Self.makeDefaults()

        // A v1 archive whose source file no longer exists anywhere — only the archive has it.
        let v1 = """
        {"v":1,"models":["claude-sonnet-4"],"projects":["proj"],"sessions":["s1"],"files":[\
        {"path":"\(dir.path)/gone.jsonl","size":10,"mod":\(day.timeIntervalSince1970),"end":10,\
        "buckets":[{"d":\(day.timeIntervalSince1970),"h":9,"m":0,"p":0,"s":0,"i":900,"o":400,\
        "r":0,"w":0,"t":\(day.timeIntervalSince1970)}]}]}
        """
        defaults.set(Data(v1.utf8), forKey: CostScanner.analyticsCacheDefaultsKey)

        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 10, output: 5, sessionId: "new", timestamp: now)],
            to: dir.appendingPathComponent("session.jsonl"))
        let analytics = await Self.makeScanner(defaults)
            .scanAnalytics(directories: [dir], windowDays: 30, now: now)

        // 910: the migrated archive plus the file on disk. The migrated file is missing from disk,
        // so its contribution moved into the permanent archive rather than vanishing.
        #expect(analytics.byDayModel.first?.inputTokens == 910)
        #expect(defaults.data(forKey: "\(CostScanner.analyticsCacheDefaultsKey).v1.orphan") == nil)
    }

    /// Audit of every route that can clear the archive key: only the explicitly-named one may.
    @Test
    func onlyTheExplicitEraseDestroysTheArchive() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let defaults = Self.makeDefaults()
        let gone = dir.appendingPathComponent("gone.jsonl")

        try Self.write(
            [Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now)],
            to: gone)
        let scanner = Self.makeScanner(defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        try FileManager.default.removeItem(at: gone)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(try #require(Self.persistedCache(defaults)).archived.count == 1)

        // A plain rescan keeps it…
        await scanner.resetCaches()
        #expect(try #require(Self.persistedCache(defaults)).archived.count == 1)
        // …a scan over a now-empty directory keeps it…
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(try #require(Self.persistedCache(defaults)).archived.count == 1)
        // …and only the named, deliberate call removes it.
        await scanner.eraseAnalyticsArchive()
        #expect(defaults.data(forKey: CostScanner.analyticsCacheDefaultsKey) == nil)
    }

    /// `resetCaches()` must drop the per-file offsets so every present file is read again — while
    /// leaving intact the one thing a rescan cannot rebuild.
    @Test
    func resetCachesDropsFileOffsetsButRebuildsTheSameAnswer() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let now = Date()
        let defaults = Self.makeDefaults()

        try Self.write([Self.line(messageId: "m1", requestId: "r1", input: 100, output: 50, timestamp: now)], to: url)
        let scanner = Self.makeScanner(defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(try #require(Self.persistedCache(defaults)).files.count == 1)

        await scanner.resetCaches()
        // The file records are gone (everything will be re-read)…
        #expect(try #require(Self.persistedCache(defaults)).files.isEmpty)

        // …and the rescan lands on exactly the same numbers.
        let rebuilt = await scanner.scanAnalytics(directories: [dir], windowDays: 30, now: now)
        #expect(rebuilt == (await Self.freshScan(dir, windowDays: 30, now: now)))
    }
}
