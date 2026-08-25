import Foundation
import Testing
@testable import ClaudeBarCore

/// EXB-6.1 — the two dimensions the fold used to discard: `byDayProject` and the full `sessions`
/// list.
///
/// Both were already in the archive. A bucket key carries `day`, `project` and `session` together,
/// and aggregation threw two of those associations away: `byProject` folded the date off (so no
/// chart could say which project *rose*), and `topSessions` kept ten rows of a distribution whose
/// whole point is the shape of the other two thousand.
///
/// Every assertion here is anchored on an **absolute** — an exact token count, an exact dollar
/// figure from the offline price table, a named calendar day. Cross-dimension agreement is asserted
/// too, but never on its own: two folds that share a defect agree with each other while both are
/// wrong, so agreement is a second witness, not the first.
struct CostScannerDimensionsTests {
    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exbdims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeDefaults() -> CostDefaults {
        CostDefaults(UserDefaults(suiteName: "exbdims.\(UUID().uuidString)")!)
    }

    /// `Pricing` pinned to the offline fallback table, so the dollar figures below are exact:
    /// `claude-sonnet-4` is $0.000003 per input token and $0.000015 per output token.
    private static func fallbackPricing(_ defaults: CostDefaults) -> Pricing {
        Pricing(
            transport: StubTransport(error: URLError(.notConnectedToInternet)),
            defaults: defaults,
            networkEnabled: false)
    }

    /// A **named** local wall-clock instant — never an offset from `Date()`.
    ///
    /// A fixture derived from an epoch instant describes data the app does not produce: the archive
    /// buckets by local start-of-day, so a fixture that names 21 August at 23:00 is the only kind
    /// that can tell a local-day fold apart from a UTC one.
    private static func localInstant(_ day: Int, hour: Int, month: Int = 8, year: Int = 2026) -> Date {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        parts.hour = hour; parts.minute = 0; parts.second = 0
        return Calendar.current.date(from: parts)!
    }

    /// ISO8601 rendering of an instant, in UTC — the shape Claude writes.
    private static func iso(_ instant: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: instant)
    }

    private static func line(
        messageId: String,
        requestId: String,
        model: String = "claude-sonnet-4",
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        project: String,
        session: String,
        instant: Date) -> String
    {
        let object: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": Self.iso(instant),
            "cwd": "/work/\(project)",
            "sessionId": session,
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
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private static func write(_ lines: [String], to dir: URL, name: String = "session.jsonl") throws {
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent(name))
    }

    /// The calendar day of `date` as `(year, month, day)`, in the local zone — the unit every day
    /// assertion below is written in, so the expectation reads the same in São Paulo and in Tokyo.
    private static func parts(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    /// Whether `date` falls in a **named** year and month. Matching on the month alone is not enough
    /// once a range spans more than a year: the first "July" in a ten-year window is July 2017.
    private static func isMonth(_ date: Date, _ year: Int, _ month: Int) -> Bool {
        let parts = Self.parts(date)
        return parts.year == year && parts.month == month
    }

    /// A window wide enough that no fixture ever falls out of it — these tests are about the fold's
    /// dimensions, not about the window filter, which has its own tests.
    private static let wideWindow = 3_650
    private static let now = CostScannerDimensionsTests.localInstant(24, hour: 12)

    // MARK: - byDayProject: the date the per-project fold used to discard

    /// Two projects across two days must produce **four** rows, each with its own day.
    ///
    /// This is the defect stated positively. `byProject` gives two rows for this fixture and cannot
    /// give more: the date is not in its output struct, so no consumer can recover it afterwards.
    /// Revert the fold to key on project alone and the count collapses to two.
    @Test
    func byDayProjectKeepsTheDayThatByProjectFoldsAway() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(
                messageId: "a1", requestId: "r1", input: 1_000, output: 500,
                project: "alpha", session: "s1", instant: Self.localInstant(20, hour: 10)),
            Self.line(
                messageId: "a2", requestId: "r2", input: 2_000, output: 1_000,
                project: "alpha", session: "s2", instant: Self.localInstant(21, hour: 10)),
            Self.line(
                messageId: "b1", requestId: "r3", input: 100, output: 50,
                project: "beta", session: "s3", instant: Self.localInstant(20, hour: 11)),
            Self.line(
                messageId: "b2", requestId: "r4", input: 200, output: 100,
                project: "beta", session: "s4", instant: Self.localInstant(21, hour: 11)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.byProject.count == 2)   // the coarser fold, unchanged
        #expect(analytics.byDayProject.count == 4) // one row per (day, project)

        // Absolute: the exact rows, by name and by number. 1 000 input + 500 output of sonnet-4 is
        // 1 000 × $0.000003 + 500 × $0.000015 = $0.0105.
        let alphaFirst = try #require(analytics.byDayProject.first {
            $0.project == "alpha" && Self.parts($0.day).day == 20
        })
        #expect(alphaFirst.totalTokens == 1_500)
        #expect(abs(alphaFirst.costUSD - 0.0105) < 1e-9)

        let alphaSecond = try #require(analytics.byDayProject.first {
            $0.project == "alpha" && Self.parts($0.day).day == 21
        })
        #expect(alphaSecond.totalTokens == 3_000)
        #expect(abs(alphaSecond.costUSD - 0.021) < 1e-9)

        // …and the rise the coarse fold could not express: alpha doubled from the 20th to the 21st.
        #expect(alphaSecond.costUSD > alphaFirst.costUSD)
    }

    /// The rows come out day-ascending, so a timeline can be drawn without re-sorting.
    ///
    /// Order is part of the contract precisely because a caller that has to sort is a caller that
    /// will one day sort differently from the next caller.
    @Test
    func byDayProjectIsOrderedByDayAscending() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // Written out of order on purpose — the sort has to do the work, not the input.
        try Self.write([
            Self.line(
                messageId: "c", requestId: "r3", input: 300, output: 0,
                project: "p", session: "s3", instant: Self.localInstant(22, hour: 9)),
            Self.line(
                messageId: "a", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(20, hour: 9)),
            Self.line(
                messageId: "b", requestId: "r2", input: 200, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(21, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.byDayProject.map { Self.parts($0.day).day } == [20, 21, 22])
    }

    /// The day is the **local** day, at both ends of the clock.
    ///
    /// One sample cannot prove this. An entry at 23:00 local is a different UTC day only west of
    /// Greenwich; an entry at 01:00 local is a different UTC day only east of it. A fold that used
    /// UTC start-of-day would pass with either sample alone, in half the world's zones — so both
    /// are here, and the pair fails everywhere.
    @Test
    func byDayProjectBooksTheLocalDayAtBothEndsOfTheClock() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            // 23:00 local on the 20th — 02:00 UTC on the 21st anywhere west of Greenwich.
            Self.line(
                messageId: "late", requestId: "r1", input: 100, output: 0,
                project: "night", session: "s1", instant: Self.localInstant(20, hour: 23)),
            // 01:00 local on the 22nd — 16:00 UTC on the 21st anywhere east of it.
            Self.line(
                messageId: "early", requestId: "r2", input: 200, output: 0,
                project: "night", session: "s2", instant: Self.localInstant(22, hour: 1)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.byDayProject.count == 2)
        // Absolute days, named — not "the two rows differ", which a UTC fold also satisfies.
        #expect(analytics.byDayProject.map { Self.parts($0.day).day } == [20, 22])
        #expect(analytics.byDayProject.allSatisfy { Self.parts($0.day).month == 8 })
        // And each day carries its own tokens, so the two were not merely relabelled.
        #expect(analytics.byDayProject.map(\.totalTokens) == [100, 200])
        // Every day is a start-of-day boundary in the local zone.
        #expect(analytics.byDayProject.allSatisfy {
            $0.day == Calendar.current.startOfDay(for: $0.day)
        })
    }

    /// The finer fold sums to the coarser one, per project — the second witness, never the first.
    @Test
    func byDayProjectSumsToByProject() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for day in 18...22 {
            for (index, project) in ["alpha", "beta", "gamma"].enumerated() {
                lines.append(Self.line(
                    messageId: "m\(day)-\(index)", requestId: "r\(day)-\(index)",
                    model: index == 1 ? "claude-opus-4" : "claude-sonnet-4",
                    input: 100 * (index + 1), output: 50 * (index + 1),
                    cacheRead: 7 * day, cacheWrite: day,
                    project: project, session: "s\(day)-\(index)",
                    instant: Self.localInstant(day, hour: 8 + index)))
            }
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.byDayProject.count == 15) // 5 days × 3 projects

        for project in analytics.byProject {
            let daily = analytics.byDayProject.filter { $0.project == project.project }
            #expect(daily.count == 5)
            #expect(daily.reduce(0) { $0 + $1.totalTokens } == project.totalTokens)
            #expect(abs(daily.reduce(0) { $0 + $1.costUSD } - project.costUSD) < 1e-9)
        }

        // Absolute anchor, so the agreement above cannot be two folds sharing one defect: alpha is
        // 100 input + 50 output per day for 5 days, plus cache tokens that are volume, not charge.
        let alpha = try #require(analytics.byProject.first { $0.project == "alpha" })
        #expect(abs(alpha.costUSD - 5 * (100 * 0.000003 + 50 * 0.000015)) < 1e-9)
        // 5 days × (100 + 50) + cache read 7×(18+19+20+21+22) + cache write (18+…+22)
        #expect(alpha.totalTokens == 750 + 7 * 100 + 100)
    }


    // MARK: - The top-8 cap: a sum, not a discard, and it says so

    /// Beyond the ranking, projects are **aggregated**, and the day's rows still add up.
    ///
    /// This is the half of a cap that is easy to get wrong and impossible to see: dropping the tail
    /// instead of summing it makes every total on this chart quietly smaller than the same total
    /// everywhere else in the panel, and nothing on screen looks broken.
    @Test
    func projectsBeyondTheRankingAreSummedNotDropped() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // 12 projects, descending volume, all on one day → 8 ranked + 4 folded into the aggregate.
        var lines: [String] = []
        for index in 1...12 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 1_000 * (13 - index), output: 0,
                project: String(format: "p%02ld", index), session: "s\(index)",
                instant: Self.localInstant(20, hour: index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.rankedProjects.count == 8)
        #expect(analytics.rankedProjects == (1...8).map { String(format: "p%02ld", $0) })
        #expect(analytics.otherProjectCount == 4)
        #expect(analytics.projectsTruncated)

        // 9 rows for the one day: 8 named + 1 aggregate.
        #expect(analytics.byDayProject.count == 9)
        let others = try #require(analytics.byDayProject.first { $0.isOthers })
        #expect(others.project.isEmpty)

        // Absolute: p09…p12 carry 4 000 + 3 000 + 2 000 + 1 000 input tokens.
        #expect(others.totalTokens == 10_000)
        #expect(abs(others.costUSD - 10_000 * 0.000003) < 1e-9)

        // The reconciliation that makes it an aggregation rather than a remainder: the nine rows sum
        // to the day's true total, which `byProject` computes without any cap at all.
        let dayTokens: Int = analytics.byDayProject.reduce(0) { $0 + $1.totalTokens }
        let projectTokens: Int = analytics.byProject.reduce(0) { $0 + $1.totalTokens }
        let expectedTokens: Int = (1...12).reduce(0) { $0 + 1_000 * (13 - $1) }
        #expect(dayTokens == projectTokens)
        #expect(dayTokens == expectedTokens)

        let dayCost: Double = analytics.byDayProject.reduce(0) { $0 + $1.costUSD }
        let projectCost: Double = analytics.byProject.reduce(0) { $0 + $1.costUSD }
        #expect(abs(dayCost - projectCost) < 1e-9)
    }

    /// Under the ceiling there is no aggregate row at all, and the flag says so.
    ///
    /// The control for the test above: without it, a fold that *always* emitted an aggregate row
    /// would pass every reconciliation while showing an empty band on every chart.
    @Test
    func belowTheCeilingNothingIsAggregated() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...8 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 100 * index, output: 0,
                project: "p\(index)", session: "s\(index)",
                instant: Self.localInstant(20, hour: index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.rankedProjects.count == 8)
        #expect(analytics.otherProjectCount == 0)
        #expect(analytics.projectsTruncated == false)
        #expect(analytics.byDayProject.contains { $0.isOthers } == false)
        #expect(analytics.byDayProject.count == 8)
    }

    /// The ranking is fixed by the **whole archive**, not by the slice on screen.
    ///
    /// This is what stops a drag from re-ranking the stack under the cursor: a band must not change
    /// owner mid-gesture, or its height stops meaning anything. The fixture makes the two answers
    /// disagree on purpose — `giant` is enormous outside the slice and tiny inside it, while nine
    /// others are larger than it within the slice. Rank by the slice and `giant` loses its band.
    @Test
    func theRankingComesFromTheArchiveNotFromTheSlice() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = [
            // Far outside the slice: 5 000 000 tokens, which no other project approaches.
            Self.line(
                messageId: "giant-old", requestId: "rg1", input: 5_000_000, output: 0,
                project: "giant", session: "sg1", instant: Self.localInstant(2, hour: 9)),
            // Inside the slice: a rounding error next to the others.
            Self.line(
                messageId: "giant-new", requestId: "rg2", input: 1, output: 0,
                project: "giant", session: "sg2", instant: Self.localInstant(21, hour: 9)),
        ]
        for index in 1...9 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 1_000 * index, output: 0,
                project: String(format: "q%02ld", index), session: "sq\(index)",
                instant: Self.localInstant(21, hour: 10 + index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)
        // A slice that deliberately excludes the giant's big day.
        let slice = Self.localInstant(20, hour: 0)...Calendar.current.startOfDay(for: Self.now)
        let analytics = await scanner.analytics(in: slice, now: Self.now)

        // Ranked first despite being the smallest thing in the picture.
        #expect(analytics.rankedProjects.first == "giant")
        #expect(analytics.rankedProjects.contains("giant"))
        // q01, the smallest of the nine, is the one squeezed out — not the giant.
        #expect(analytics.rankedProjects.contains("q01") == false)
        #expect(analytics.otherProjectCount == 2) // q01 and q02

        // And the height still answers to the slice: one token, not five million.
        let giantRow = try #require(analytics.byDayProject.first { $0.project == "giant" })
        #expect(giantRow.totalTokens == 1)
    }

    /// The aggregate row is pinned to the end of its day whatever its size.
    ///
    /// Sorting it by cost like any other row would let it migrate through the stack from day to day,
    /// and a band that changes position is read as a band that changed value.
    @Test
    func theAggregateRowSortsLastWithinItsDay() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // Eight projects earn their bands on volume spent OUTSIDE the slice, and contribute almost
        // nothing inside it. Three others exist only inside the slice — too small to be ranked
        // globally, yet together the largest thing on the day. That is precisely the case a cost
        // sort would place first.
        var lines: [String] = []
        for index in 1...8 {
            lines.append(Self.line(
                messageId: "big\(index)", requestId: "rb\(index)",
                input: 1_000_000, output: 0,
                project: String(format: "ranked%02ld", index), session: "sb\(index)",
                instant: Self.localInstant(2, hour: index))) // outside the slice: fixes the ranking
            lines.append(Self.line(
                messageId: "small\(index)", requestId: "rs\(index)",
                input: 1, output: 0,
                project: String(format: "ranked%02ld", index), session: "ss\(index)",
                instant: Self.localInstant(21, hour: index)))
        }
        for index in 1...3 {
            lines.append(Self.line(
                messageId: "tail\(index)", requestId: "rt\(index)",
                input: 100, output: 0,
                project: "tail\(index)", session: "st\(index)",
                instant: Self.localInstant(21, hour: 12 + index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)
        let slice = Self.localInstant(20, hour: 0)...Calendar.current.startOfDay(for: Self.now)
        let analytics = await scanner.analytics(in: slice, now: Self.now)

        let day21 = analytics.byDayProject.filter { Self.parts($0.day).day == 21 }
        #expect(day21.count == 9)
        // The aggregate is by far the biggest row and still comes last.
        let last = try #require(day21.last)
        #expect(last.isOthers)
        // 3 × 100 — larger than any of the eight ranked rows, which hold 1 token each that day.
        #expect(last.totalTokens == 300)
        #expect(day21.dropLast().allSatisfy { !$0.isOthers })
        #expect(day21.dropLast().allSatisfy { $0.totalTokens == 1 })
    }

    // MARK: - Session distribution: 20 integers instead of one object per session

    /// The histogram counts every session, on fixed edges, and the median is exact.
    ///
    /// Sizes chosen to land in known buckets: √10-spaced edges put 100 in bucket 4, 1 000 in bucket
    /// 6 and 10 000 in bucket 8.
    @Test
    func theHistogramCountsEverySessionOnFixedEdges() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // 4 sessions of 100 tokens, 1 of 1 500, 4 of 10 000 — nine in total, so the median is the
        // fifth: 1 500. That value sits in the *middle* of bucket 6 (which spans 1 000…3 161), so a
        // median read off the histogram could not produce it.
        var lines: [String] = []
        var index = 0
        for (tokens, count) in [(100, 4), (1_500, 1), (10_000, 4)] {
            for _ in 0..<count {
                index += 1
                lines.append(Self.line(
                    messageId: "m\(index)", requestId: "r\(index)",
                    input: tokens, output: 0,
                    project: "p", session: "s\(index)",
                    instant: Self.localInstant(20, hour: index)))
            }
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.totalSessions == 9)
        #expect(analytics.sessionTokenBuckets.count == UsageAnalytics.sessionTokenBucketCount)
        // Every session is counted exactly once — nothing falls off either end.
        #expect(analytics.sessionTokenBuckets.reduce(0, +) == 9)

        #expect(analytics.sessionTokenBuckets[UsageAnalytics.sessionTokenBucketIndex(forTokens: 100)] == 4)
        #expect(analytics.sessionTokenBuckets[UsageAnalytics.sessionTokenBucketIndex(forTokens: 1_500)] == 1)
        #expect(analytics.sessionTokenBuckets[UsageAnalytics.sessionTokenBucketIndex(forTokens: 10_000)] == 4)
        // Absolute bucket indices, so a change to the binning is a change to this test, not a silent
        // reshuffle of every chart drawn on it.
        #expect(analytics.sessionTokenBuckets[4] == 4)
        #expect(analytics.sessionTokenBuckets[6] == 1)
        #expect(analytics.sessionTokenBuckets[8] == 4)

        // The exact median. Bucket 6 spans 1 000…3 161, so no bucket boundary equals 1 500 — this
        // number can only come from the real session totals.
        #expect(analytics.medianSessionTokens == 1_500)
    }

    /// Bucket edges are a property of the scale, not of the data in front of them.
    ///
    /// Two different slices must put a session of the same size in the same bucket, or the axis moves
    /// under the reader and two periods stop being comparable. Derived edges would pass every
    /// single-slice test and fail this one.
    @Test
    func bucketEdgesDoNotMoveWithTheDataInTheSlice() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            // Day 20: one small session on its own.
            Self.line(
                messageId: "a", requestId: "r1", input: 500, output: 0,
                project: "p", session: "small", instant: Self.localInstant(20, hour: 9)),
            // Day 21: a session a thousand times larger, which would stretch any derived scale.
            Self.line(
                messageId: "b", requestId: "r2", input: 500_000, output: 0,
                project: "p", session: "huge", instant: Self.localInstant(21, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        let day20 = Self.localInstant(20, hour: 0)
        let narrow = await scanner.analytics(in: day20...day20, now: Self.now)
        let wide = await scanner.analytics(
            in: day20...Calendar.current.startOfDay(for: Self.now), now: Self.now)

        let slot = UsageAnalytics.sessionTokenBucketIndex(forTokens: 500)
        #expect(narrow.sessionTokenBuckets[slot] == 1)
        #expect(wide.sessionTokenBuckets[slot] == 1) // same bucket, though the slice grew 1000×
        #expect(narrow.totalSessions == 1)
        #expect(wide.totalSessions == 2)
        // The published edges are the ones the fold used, and they are the same both times.
        #expect(UsageAnalytics.sessionTokenBucketEdges.count == UsageAnalytics.sessionTokenBucketCount + 1)
        #expect(UsageAnalytics.sessionTokenBucketEdges[slot] <= 500)
        #expect(UsageAnalytics.sessionTokenBucketEdges[slot + 1] > 500)
    }

    /// The published binning is the one the fold used, over the whole scale, and it handles the ends.
    ///
    /// The consumer needs this function to mark `topSessions` on the histogram. If it disagreed with
    /// the fold by one bucket, the mark would sit next to its own bar — visible, and unattributable.
    @Test
    func thePublishedBinningIsMonotoneAndClampsBothEnds() {
        // Zero cannot come out of the scan, but a caller can ask; `log(0)` must not escape.
        #expect(UsageAnalytics.sessionTokenBucketIndex(forTokens: 0) == 0)
        #expect(UsageAnalytics.sessionTokenBucketIndex(forTokens: -5) == 0)
        #expect(UsageAnalytics.sessionTokenBucketIndex(forTokens: 1) == 0)
        // Above the last edge everything piles into the final bucket rather than off the end.
        #expect(UsageAnalytics.sessionTokenBucketIndex(forTokens: Int.max)
            == UsageAnalytics.sessionTokenBucketCount - 1)

        var previous = 0
        for exponent in 0...9 {
            let index = UsageAnalytics.sessionTokenBucketIndex(forTokens: Int(pow(10.0, Double(exponent))))
            #expect(index >= previous)
            previous = index
            // Each index really does address the range its published edges claim.
            let tokens = Int(pow(10.0, Double(exponent)))
            #expect(UsageAnalytics.sessionTokenBucketEdges[index] <= tokens)
            if index < UsageAnalytics.sessionTokenBucketCount - 1 {
                #expect(UsageAnalytics.sessionTokenBucketEdges[index + 1] > tokens)
            }
        }
    }

    /// An even number of sessions takes the midpoint of the two central values.
    @Test
    func theMedianOfAnEvenSampleIsTheMidpointOfTheTwoCentralSessions() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // 100, 200, 300, 400 → the two central are 200 and 300, midpoint 250. No bucket boundary
        // lands there, so a median read off the histogram could not produce this number.
        try Self.write((1...4).map { index in
            Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 100 * index, output: 0,
                project: "p", session: "s\(index)",
                instant: Self.localInstant(20, hour: index))
        }, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.totalSessions == 4)
        #expect(analytics.medianSessionTokens == 250)
    }

    /// An empty window reports an empty distribution, not a fabricated one.
    @Test
    func anEmptyWindowHasNoDistributionAtAll() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        try Self.write([
            Self.line(
                messageId: "a", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // A slice that lands on a day with nothing in it.
        let empty = Self.localInstant(23, hour: 0)
        let analytics = await scanner.analytics(in: empty...empty, now: Self.now)

        #expect(analytics.totalSessions == 0)
        #expect(analytics.medianSessionTokens == 0)
        #expect(analytics.sessionTokenBuckets.reduce(0, +) == 0)
        // Still 20 slots, so a chart binds to the same axis whether or not there is data on it.
        #expect(analytics.sessionTokenBuckets.count == UsageAnalytics.sessionTokenBucketCount)
        #expect(analytics.topSessions.isEmpty)
    }

    /// `topSessions` lands on buckets the histogram actually filled.
    ///
    /// The two views are drawn on top of each other, so a mark with no bar under it is the failure
    /// that matters — and it is the one nobody writes a test for.
    @Test
    func everyTopSessionLandsOnANonEmptyBucket() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...25 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 137 * index * index, output: 11 * index,
                project: "p\(index % 3)", session: "s\(index)",
                instant: Self.localInstant(18 + index % 5, hour: index % 24)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.totalSessions == 25)
        #expect(analytics.topSessions.count == 10)
        for session in analytics.topSessions {
            let slot = UsageAnalytics.sessionTokenBucketIndex(forTokens: session.totalTokens)
            #expect(analytics.sessionTokenBuckets[slot] > 0)
        }
    }


    // MARK: - The full session list, kept alongside the histogram

    /// Every session is handed over, not ten — and not the twenty numbers of the histogram either.
    ///
    /// The two answer different questions. The histogram gives the *shape* at constant size; this
    /// gives per-session identity, which is what says *which* session the outlier was. Revert the
    /// fold to publish the truncated list and the first expectation fails.
    @Test
    func sessionsHoldsEveryOneNotJustTheTopTen() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...15 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 100 * index, output: 0,
                project: "p\(index % 3)", session: "s\(index)",
                instant: Self.localInstant(20, hour: index % 24)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.sessions.count == 15)
        #expect(analytics.totalSessions == 15)
        #expect(analytics.sessionsTruncated == false)
        #expect(analytics.topSessions.count == 10) // unchanged, still the head

        // The tail is what a distribution view exists for: the cheapest session must be present, and
        // be the one the top ten drops. 100 input tokens of sonnet-4 is $0.0003.
        let cheapest = try #require(analytics.sessions.last)
        #expect(cheapest.sessionId == "s1")
        #expect(cheapest.totalTokens == 100)
        #expect(abs(cheapest.costUSD - 0.0003) < 1e-9)
        #expect(analytics.topSessions.contains(cheapest) == false)

        // Sorted dearest first all the way down, not only across the head.
        let costs = analytics.sessions.map(\.costUSD)
        #expect(costs == costs.sorted(by: >))
    }

    /// `topSessions` is the head of `sessions`, structurally.
    ///
    /// Two roll-ups that are *supposed* to agree are two roll-ups that can disagree, and a top ten
    /// naming a session the list behind it dropped would be invisible on screen.
    @Test
    func topSessionsIsExactlyTheHeadOfSessions() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...12 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                model: index.isMultiple(of: 2) ? "claude-opus-4" : "claude-sonnet-4",
                input: 500 * index, output: 10 * index,
                project: "p", session: "s\(index)",
                instant: Self.localInstant(21, hour: index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        #expect(analytics.sessions.count == 12)
        #expect(analytics.topSessions == Array(analytics.sessions.prefix(10)))
    }

    /// A requested cap is applied and declared, and the histogram does not shrink with it.
    ///
    /// This is the branch that keeps `sessionsTruncated` from being decoration — without a caller
    /// able to cut, the flag could never be `true`, and a control that never fires is not a control.
    /// The second half matters just as much: a cap is a decision about payload, not a claim about
    /// the distribution, so a histogram that followed the cut would report a different *shape*
    /// depending on how much the caller asked to carry.
    @Test
    func aRequestedCapIsAppliedAndDeclaredWithoutMovingTheDistribution() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...15 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 100 * index, output: 0,
                project: "p", session: "s\(index)",
                instant: Self.localInstant(20, hour: index % 24)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let capped = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now, sessionLimit: 5)

        #expect(capped.sessions.count == 5)
        // The number that makes the cut legible: it counts what the window held, not what survived.
        #expect(capped.totalSessions == 15)
        #expect(capped.sessionsTruncated)
        #expect(capped.sessions.map(\.sessionId) == ["s15", "s14", "s13", "s12", "s11"])
        #expect(capped.topSessions == capped.sessions)
        // The distribution still describes all fifteen.
        #expect(capped.sessionTokenBuckets.reduce(0, +) == 15)

        // Control: the same fixture uncut is not truncated, and the histogram is identical — so the
        // flag reports the cut and the histogram reports the data, and neither reports the other.
        let whole = await scanner.analytics(
            in: Self.localInstant(1, hour: 0)...Calendar.current.startOfDay(for: Self.now),
            now: Self.now)
        #expect(whole.sessions.count == 15)
        #expect(whole.sessionsTruncated == false)
        #expect(whole.sessionTokenBuckets == capped.sessionTokenBuckets)
        #expect(whole.medianSessionTokens == capped.medianSessionTokens)
    }

    /// A hand-built `UsageAnalytics` that says nothing about the total is not claiming a cut.
    ///
    /// `totalSessions` defaults to `nil`, resolving to `sessions.count`. Had it defaulted to `0`,
    /// every fixture in the app's other test suites would silently report a *negative* truncation.
    @Test
    func anOmittedTotalMeansTheseAreAllOfThem() {
        let session = SessionUsageEntry(
            sessionId: "s1", date: Self.localInstant(20, hour: 9), project: "p",
            dominantModel: "claude-sonnet-4", totalTokens: 10, costUSD: 1)
        let analytics = UsageAnalytics(
            byDayModel: [], byProject: [], heatmap: UsageAnalytics.emptyHeatmap(),
            topSessions: [session], monthToDateCost: 0, sessions: [session])

        #expect(analytics.totalSessions == 1)
        #expect(analytics.sessionsTruncated == false)
    }

    // MARK: - The global rank the view needs to cut with a stable identity

    /// The published rank covers every project, is global, and `rankedProjects` is its head.
    ///
    /// A consumer that cuts at some other N must get the *same* ordering the fold used for the
    /// aggregate row. Two orderings that are supposed to agree can disagree, and here the symptom
    /// would be a band whose colour belongs to one project and whose height belongs to another.
    @Test
    func theRankMapCoversEveryProjectAndAgreesWithTheHead() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for index in 1...12 {
            lines.append(Self.line(
                messageId: "m\(index)", requestId: "r\(index)",
                input: 1_000 * (13 - index), output: 0,
                project: String(format: "p%02ld", index), session: "s\(index)",
                instant: Self.localInstant(20, hour: index)))
        }
        try Self.write(lines, to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // Every project, not only the eight that got a band.
        #expect(analytics.projectRankByTotal.count == 12)
        #expect(analytics.projectRankByTotal["p01"] == 0)  // largest
        #expect(analytics.projectRankByTotal["p12"] == 11) // smallest
        // Ranks are a permutation of 0..<n — no gaps, no repeats, so a caller can sort by them.
        #expect(Set(analytics.projectRankByTotal.values) == Set(0..<12))

        // The head agrees with the map, in order.
        let headByRank = analytics.projectRankByTotal
            .filter { $0.value < UsageAnalytics.maxRankedProjects }
            .sorted { $0.value < $1.value }
            .map(\.key)
        #expect(analytics.rankedProjects == headByRank)
    }

    /// The rank map ignores the slice, exactly as the head does.
    ///
    /// Same fixture idea as the ranking test above: were the map derived from the slice, a drag would
    /// hand the view a new ordering on every frame, and the view would recolour bands mid-gesture
    /// while believing it was using a stable identity.
    @Test
    func theRankMapIsArchiveWideNotSliceWide() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(
                messageId: "g1", requestId: "rg1", input: 5_000_000, output: 0,
                project: "giant", session: "sg1", instant: Self.localInstant(2, hour: 9)),
            Self.line(
                messageId: "g2", requestId: "rg2", input: 1, output: 0,
                project: "giant", session: "sg2", instant: Self.localInstant(21, hour: 9)),
            Self.line(
                messageId: "s1", requestId: "rs1", input: 9_000, output: 0,
                project: "small", session: "ss1", instant: Self.localInstant(21, hour: 10)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        let narrow = await scanner.analytics(
            in: Self.localInstant(20, hour: 0)...Calendar.current.startOfDay(for: Self.now),
            now: Self.now)
        let whole = await scanner.analytics(
            in: Self.localInstant(1, hour: 0)...Calendar.current.startOfDay(for: Self.now),
            now: Self.now)

        // Inside the narrow slice `small` outweighs `giant` 9 000 to 1, and the rank still says
        // otherwise — because the rank is not about the slice.
        #expect(narrow.projectRankByTotal["giant"] == 0)
        #expect(narrow.projectRankByTotal["small"] == 1)
        #expect(narrow.projectRankByTotal == whole.projectRankByTotal)
    }

    // MARK: - Month coverage: without it the cascade fabricates a fall

    /// A month still in progress is reported incomplete, and a whole one is not.
    ///
    /// This is the field the month-over-month cascade cannot be built without. On the 24th, August
    /// holds 24 days against July's 31; comparing them unguarded makes *every* project read as
    /// having slowed, and every bar agrees with every other bar, which is what makes it invisible.
    @Test
    func aMonthStillInProgressIsReportedIncomplete() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // One entry in July and one in August, so the archive vouches for both months.
        try Self.write([
            Self.line(
                messageId: "jul", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(1, hour: 9, month: 7)),
            Self.line(
                messageId: "aug", requestId: "r2", input: 100, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // The year matters: a 3 650-day window spans ten years, so "the July" is ambiguous — the
        // first match was July *2017*, a month the range covers and the archive never saw.
        let july = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 7) })
        let august = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 8) })

        #expect(july.daysInMonth == 31)
        #expect(july.daysCovered == 31)
        #expect(july.isComplete)

        // `now` is the 24th, so the archive can vouch for 24 of August's 31 days.
        #expect(august.daysInMonth == 31)
        #expect(august.daysCovered == 24)
        #expect(august.isComplete == false)

        // Ascending, so a cascade can walk it as a series.
        let months: [Date] = analytics.monthCoverage.map(\.month)
        #expect(months == months.sorted())
    }

    /// A month clipped by the range is distinguishable from a month the archive is missing.
    ///
    /// Both look like "fewer days" through a single number. They are different facts — one is the
    /// user's selection, the other is lost history — and a cascade that confuses them tells the user
    /// their July collapsed when they merely dragged the handle.
    @Test
    func aClippedMonthIsDistinguishableFromMissingHistory() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(
                messageId: "jul", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(1, hour: 9, month: 7)),
            Self.line(
                messageId: "aug", requestId: "r2", input: 100, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // A slice that starts on 15 July: the month is clipped by the selection, not by the archive.
        let analytics = await scanner.analytics(
            in: Self.localInstant(15, hour: 0, month: 7)...Calendar.current.startOfDay(for: Self.now),
            now: Self.now)

        let july = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 7) })
        #expect(july.daysInMonth == 31)
        #expect(july.daysInRange == 17)   // 15…31 July
        #expect(july.daysCovered == 17)   // the archive was watching every selected day
        #expect(july.isComplete == false) // still not comparable to a whole month
        // The pair of numbers is what separates the two causes: everything selected was covered.
        #expect(july.daysCovered == july.daysInRange)
    }

    /// A month the archive was never watching is **absent**, not a zero row.
    ///
    /// Zero would be a claim — "nothing happened in June" — that the archive cannot support: it was
    /// not running. Absence is the honest answer, and it is the one `coveredDays` already gives
    /// everywhere else, so the two agree instead of the panel having to reconcile them.
    ///
    /// It is also what bounds the cost. Enumerating every selected month regardless would mean 3 287
    /// rows for the `windowDays: 100_000` the panel scans with, all of them zero.
    @Test
    func aMonthTheArchiveNeverWatchedIsAbsentRatherThanZero() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(
                messageId: "aug", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        _ = await scanner.scanAnalytics(directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // June is fully inside the selection and entirely before the archive's first watched day.
        let analytics = await scanner.analytics(
            in: Self.localInstant(1, hour: 0, month: 6)...Calendar.current.startOfDay(for: Self.now),
            now: Self.now)

        #expect(analytics.monthCoverage.contains { Self.isMonth($0.month, 2026, 6) } == false)
        // Control: the month that *was* watched is present, so absence above is a judgement about
        // June and not a fold that returned nothing.
        let august = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 8) })
        #expect(august.daysCovered == 5) // 20…24 August
        #expect(august.daysInRange == 24)
    }

    /// A month inside the watched span with no usage is reported covered, not missing.
    ///
    /// The distinction the cascade turns on: "we were watching and nothing happened" is a fact worth
    /// comparing, while "we were not watching" is not. Both look like an empty chart.
    @Test
    func aQuietMonthInsideTheWatchedSpanIsStillFullyCovered() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        // Usage in June and in August, none at all in July — but the app was running throughout.
        try Self.write([
            Self.line(
                messageId: "jun", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(1, hour: 9, month: 6)),
            Self.line(
                messageId: "aug", requestId: "r2", input: 100, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        let july = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 7) })
        #expect(july.daysCovered == 31)
        #expect(july.isComplete)
        // …and it really is empty of usage, which is what makes it comparable rather than unknown.
        #expect(analytics.byDayProject.contains { Self.parts($0.day).month == 7 } == false)
    }

    /// Coverage survives an archive old enough to span a daylight-saving change.
    ///
    /// Found by measurement, not by reading: São Paulo used to enter daylight saving **at midnight**,
    /// so on those dates midnight did not exist. A walk that steps a day at a time lands on 01:00
    /// there and inherits the hour for ever after — from 2016-08-27 the walk reaches 2026-07-01 at
    /// 01:00 local. Every `Set<Date>` membership test against true midnights then answers `false`,
    /// and a decade of covered days reads as uncovered.
    ///
    /// A permanent archive is precisely the thing that eventually spans such a change, so this is a
    /// defect with a fuse on it rather than a hypothetical. The fixture reproduces it by asking for a
    /// range that starts a decade back, which is what the panel's "tudo" shortcut does.
    @Test
    func coverageSurvivesARangeThatSpansADaylightSavingChange() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        try Self.write([
            Self.line(
                messageId: "a", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1", instant: Self.localInstant(1, hour: 9, month: 7)),
            Self.line(
                messageId: "b", requestId: "r2", input: 100, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        // 3 650 days reaches back to 2016 — across two Brazilian daylight-saving changes.
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // Control: the archive really did record coverage for these days.
        #expect(analytics.coveredDays.isEmpty == false)

        let july = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 7) })
        #expect(july.daysCovered == 31)
        // Control: months a decade back are inside the selection but outside the watched span, so
        // they are absent — which also keeps the assertion above from being satisfied by a fold that
        // simply marks everything covered.
        #expect(analytics.monthCoverage.contains { Self.isMonth($0.month, 2017, 7) } == false)
        #expect(analytics.monthCoverage.count == 2) // July and August 2026, and nothing else
    }


    /// Coverage already persisted with the drifted hour is still counted.
    ///
    /// The pair of fixes above is not one fix twice. Normalising on **write** canonicalises days this
    /// build records; normalising on **read** rescues the ones already sitting in a user's archive,
    /// written by a build that had the drift. Only the second is exercised here — the state is
    /// planted through the codec at 01:00, the way a real upgrade would find it — and without the
    /// read-side normalisation every one of these days reads as uncovered.
    ///
    /// This test exists because the first version of it did not: a fixture that goes through the
    /// scan gets canonical days from the write-side fix and can never observe the read-side one. The
    /// mutation survived, which is the only reason anybody noticed.
    @Test
    func coverageThatWasPersistedOffMidnightIsStillCounted() async throws {
        let defaults = Self.makeDefaults()
        let calendar = Calendar.current

        // Twelve days of August 2026 recorded at 01:00 local instead of midnight — exactly what a
        // day-by-day walk across a midnight daylight-saving change leaves behind.
        var state = AnalyticsCacheState()
        var drifted: Set<Date> = []
        for day in 1...12 {
            drifted.insert(Self.localInstant(day, hour: 1))
        }
        state.coveredDays = drifted

        // One real bucket so the fold has something to price; its day is canonical, as always.
        let bucketDay = calendar.startOfDay(for: Self.localInstant(5, hour: 10))
        state.files["/tmp/planted.jsonl"] = AnalyticsFileRecord(
            size: 1, modified: Self.localInstant(5, hour: 10), endOffset: 1,
            buckets: [
                AnalyticsBucketKey(
                    day: bucketDay, hour: 10, model: "claude-sonnet-4",
                    project: "p", session: "s1"):
                    AnalyticsBucketTotals(
                        inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                        firstTimestamp: Self.localInstant(5, hour: 10)),
            ])
        defaults.set(
            try #require(AnalyticsCacheCodec.encode(state)),
            forKey: CostScanner.analyticsCacheDefaultsKey)

        // A scanner that only ever reads the planted archive — no scan, so nothing re-records the
        // coverage and the drifted instants are the only ones in play.
        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.analytics(
            in: Self.localInstant(1, hour: 0)...calendar.startOfDay(for: Self.now), now: Self.now)

        let august = try #require(analytics.monthCoverage.first { Self.isMonth($0.month, 2026, 8) })
        #expect(august.daysCovered == 12)
        #expect(august.daysInRange == 24)
        #expect(august.isComplete == false)
    }


    /// The days the archive records are canonical midnights, whatever the walk crossed to reach them.
    ///
    /// `coveredDays` is public and other views look days up in it directly, so canonicalising it at
    /// the source is what protects consumers this file does not own — the read-side rescue only ever
    /// covers `monthCoverage`. The fixture plants history in 2016 so the recording walk has to cross
    /// two Brazilian daylight-saving changes, both of which began at midnight.
    ///
    /// Honest limit: in a zone that has never moved its clocks at midnight this assertion is
    /// satisfied trivially, so it is a real gate only west of Greenwich. It is written as an
    /// invariant over the whole set rather than a comparison against a hard-coded date precisely so
    /// that it stays *true* everywhere while being *sharp* where the defect lives.
    @Test
    func everyRecordedCoverageDayIsACanonicalMidnight() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()
        let calendar = Calendar.current

        try Self.write([
            Self.line(
                messageId: "old", requestId: "r1", input: 100, output: 0,
                project: "p", session: "s1",
                instant: Self.localInstant(1, hour: 9, month: 9, year: 2016)),
            Self.line(
                messageId: "new", requestId: "r2", input: 100, output: 0,
                project: "p", session: "s2", instant: Self.localInstant(20, hour: 9)),
        ], to: dir)

        let scanner = CostScanner(pricing: Self.fallbackPricing(defaults), defaults: defaults)
        let analytics = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)

        // Control: the walk really did run and really did span the decade.
        #expect(analytics.coveredDays.count > 3_000)
        let drifted = analytics.coveredDays.filter { $0 != calendar.startOfDay(for: $0) }
        #expect(drifted.isEmpty, "\(drifted.count) recorded days are not at local midnight")
    }

    // MARK: - The zero-I/O gate still holds, with the new dimensions on

    /// Switching period must remain arithmetic, now that the fold emits more dimensions.
    ///
    /// The existing gate proves `analytics(in:)` reads nothing; it cannot notice a new dimension that
    /// quietly re-reads a file, because it does not look at the new dimensions at all. So this one
    /// asserts both halves at once: the probe count does not move **and** the new dimensions came out
    /// populated. Without that second half the gate would pass on an empty scan, which is the shape
    /// of a gate that approves an absence.
    @Test
    func rangeQueriesWithTheNewDimensionsStillTouchTheFileSystemZeroTimes() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.makeDefaults()

        var lines: [String] = []
        for day in 18...23 {
            for index in 0..<3 {
                lines.append(Self.line(
                    messageId: "m\(day)-\(index)", requestId: "r\(day)-\(index)",
                    input: 100 * (index + 1), output: 20,
                    project: "p\(index)", session: "s\(day)-\(index)",
                    instant: Self.localInstant(day, hour: 9 + index)))
            }
        }
        try Self.write(lines, to: dir)

        // `FileManager` is not `Sendable`, so the spy needs an explicit opt-out to cross into the
        // actor. Sound here: its only mutable field is guarded by its own lock.
        nonisolated(unsafe) let spy = ProbeCountingFileManager()
        let scanner = CostScanner(
            pricing: Self.fallbackPricing(defaults), defaults: defaults, fileManager: spy)
        _ = await scanner.scanAnalytics(
            directories: [dir], windowDays: Self.wideWindow, now: Self.now)
        let afterScan = spy.probes
        #expect(afterScan > 0) // control: the spy does observe the scan's own walk

        let today = Calendar.current.startOfDay(for: Self.now)
        var last: UsageAnalytics?
        for offset in 1...20 {
            let from = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            last = await scanner.analytics(in: from...today, now: Self.now)
        }

        #expect(spy.probes == afterScan)
        // The half that stops this from passing vacuously: the range door really did produce every
        // new dimension while touching nothing.
        let analytics = try #require(last)
        #expect(analytics.byDayProject.count == 18) // 6 days × 3 projects
        #expect(analytics.totalSessions == 18)
        #expect(analytics.sessionTokenBuckets.reduce(0, +) == 18)
        #expect(analytics.medianSessionTokens > 0)
        #expect(analytics.rankedProjects.count == 3)
        #expect(analytics.monthCoverage.isEmpty == false)
    }

    /// Counts file-system probes on the injected `FileManager` — `fileExists` is the gate the census
    /// must pass through on every root, so the walk cannot start without incrementing it.
    private final class ProbeCountingFileManager: FileManager, @unchecked Sendable {
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
}
