import Foundation

// The persisted, incremental cache behind `CostScanner.scanAnalytics` (EXB-5.6).
//
// WHY A SECOND CACHE: the popover's `costScanner.aggregate` only carries `(day, model)` totals. The
// dashboard needs hour-of-day (heatmap), project, session and the cache-token split, so it used to
// re-read every byte of every in-window file on every open and on every period switch — 24 s for
// 30 d, 47 s for 90 d on a 2.1 GB history.
//
// The unit of this cache is a **bucket**: `(day, hour, model, project, session)` → token totals.
// That key is the coarsest grain that still reconstructs every analytics view exactly:
//
//   • `byDayModel`  ← fold on (day, model)          • `heatmap`     ← fold on (weekday(day), hour)
//   • `byProject`   ← fold on project               • `topSessions` ← fold on session
//   • `monthToDate` ← filter day ≥ start-of-month   • window filter ← filter on day
//
// Because the window is a *filter over days*, one warmed cache serves 7 d, 30 d and 90 d alike:
// switching period is arithmetic over ~20 k buckets, not I/O over 2 GB.
//
// Buckets hold **token counts only, never money**. Cost is derived at aggregation time from the
// live `Pricing` actor, so a price change is picked up without invalidating a single byte of cache,
// and the arithmetic is integer (deterministic) until the very last step.

// MARK: - Bucket

/// The cache's unit of accumulation. `day` is start-of-day in the user's local time zone and `hour`
/// is the local hour (0…23) — the same bucketing the analytics views use.
struct AnalyticsBucketKey: Hashable, Sendable {
    let day: Date
    let hour: Int
    let model: String
    let project: String
    let session: String
}

/// Token totals for one bucket, plus the earliest timestamp seen in it (the source of a session's
/// "first seen" date). Money is deliberately absent — see the file header.
struct AnalyticsBucketTotals: Sendable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// Earliest entry timestamp folded into this bucket; `.distantFuture` while the bucket is empty.
    var firstTimestamp = Date.distantFuture

    /// `true` once every token counter is back to zero — the bucket is then dropped so a superseded
    /// streaming chunk never leaves a ghost `(day, hour, model, project, session)` behind.
    var isEmpty: Bool {
        self.inputTokens == 0 && self.outputTokens == 0
            && self.cacheReadTokens == 0 && self.cacheWriteTokens == 0
    }

    mutating func add(_ other: AnalyticsBucketTotals) {
        self.inputTokens += other.inputTokens
        self.outputTokens += other.outputTokens
        self.cacheReadTokens += other.cacheReadTokens
        self.cacheWriteTokens += other.cacheWriteTokens
        self.firstTimestamp = Swift.min(self.firstTimestamp, other.firstTimestamp)
    }

    /// Remove a previously-added contribution (a streaming chunk superseded by a later one).
    /// `firstTimestamp` is intentionally *not* rolled back: `min` has no inverse, and the value is
    /// the session's "first seen" instant, which only ever wants the earliest observation.
    mutating func subtract(_ other: AnalyticsBucketTotals) {
        self.inputTokens -= other.inputTokens
        self.outputTokens -= other.outputTokens
        self.cacheReadTokens -= other.cacheReadTokens
        self.cacheWriteTokens -= other.cacheWriteTokens
    }
}

// MARK: - Dedup ledger

/// What one `"messageId:requestId"` contributed, so a later chunk of the same message can *replace*
/// it across scans instead of being summed on top of it.
///
/// Claude writes the same message id several times while streaming (measured on this machine: 468
/// repeats in one 96 MB log, identical usage each time, up to 2.1 MB apart). A whole-file parse
/// dedups those in a local dictionary, but an incremental parse may see chunk *n+1* in a byte range
/// read long after chunk *n* was already folded in — hence this ledger, which is the only thing that
/// makes resuming at a byte offset safe.
struct AnalyticsLedgerEntry: Sendable {
    /// Byte offset of the line that produced this contribution ("higher offset wins").
    var offset: Int64
    var bucket: AnalyticsBucketKey
    var totals: AnalyticsBucketTotals
}

// MARK: - Per-file record

/// Everything the cache knows about one JSONL file.
///
/// `size` + `modified` are the staleness check: identical to the last scan → the file is skipped
/// without opening a `FileHandle`, and its `buckets` are reused verbatim.
struct AnalyticsFileRecord: Sendable {
    /// File size at the time `endOffset` was recorded. A smaller size means truncation/rotation.
    var size: Int64
    /// Modification date at the time of the parse.
    var modified: Date
    /// Byte offset reached by the last parse — where an incremental re-scan resumes.
    var endOffset: Int64
    /// This file's own contribution. Kept per file so truncation or a forced re-read can drop
    /// exactly this file's numbers without disturbing the other 2 000.
    var buckets: [AnalyticsBucketKey: AnalyticsBucketTotals]
    /// Dedup ledger, retained only for files recent enough to still be appended to (see
    /// `CostScanner.analyticsLedgerRetentionDays`). `nil` means "cannot resume safely" — a change to
    /// such a file forces a full re-read from offset 0, which is always exact.
    var ledger: [String: AnalyticsLedgerEntry]?

    init(
        size: Int64 = 0,
        modified: Date = .distantPast,
        endOffset: Int64 = 0,
        buckets: [AnalyticsBucketKey: AnalyticsBucketTotals] = [:],
        ledger: [String: AnalyticsLedgerEntry]? = nil)
    {
        self.size = size
        self.modified = modified
        self.endOffset = endOffset
        self.buckets = buckets
        self.ledger = ledger
    }
}

/// The whole persisted cache — and, since EXB-5.7, the app's own **historical archive**.
///
/// The framing changed: exímIABar is no longer a reader of files somebody else deletes. Claude Code's
/// retention had already destroyed five months of this machine's cost history before anyone noticed,
/// and that data is gone for good. So nothing here expires with the dashboard's 90-day window — the
/// window is a *read filter* over an aggregate that only ever grows.
struct AnalyticsCacheState: Sendable {
    /// Live files: byte offset, dedup ledger, and the buckets currently attributed to each.
    /// Attribution matters while the file exists — a truncation or a forced re-read has to withdraw
    /// exactly that file's numbers before booking them again.
    var files: [String: AnalyticsFileRecord] = [:]

    /// Contributions of files that have **vanished from disk**, kept forever.
    ///
    /// Still keyed by the original path, and that is not bookkeeping vanity: if Claude Code ever
    /// recreates a log at the same path, the archived contribution has to be withdrawn before the
    /// file is parsed again, or the day would be counted twice. A flat merged pool could not do that.
    var archived: [String: [AnalyticsBucketKey: AnalyticsBucketTotals]] = [:]

    /// Days the archive can vouch for: it was watching, so *no usage* on such a day means the user
    /// really did not use Claude, not that the transcript was already gone.
    ///
    /// Grows monotonically — once vouched for, always vouched for. Days outside this set are "no
    /// data", which the dashboard draws as a gap instead of a zero.
    var coveredDays: Set<Date> = []

    /// Every bucket the archive holds, live files and vanished ones alike.
    func allBuckets() -> [[AnalyticsBucketKey: AnalyticsBucketTotals]] {
        self.files.values.map(\.buckets) + Array(self.archived.values)
    }
}

// MARK: - Persistence codec

/// Encodes / decodes `AnalyticsCacheState` for `UserDefaults`.
///
/// Model, project and session names repeat across thousands of buckets (a session id alone is 36
/// bytes), so all three are interned into tables and referenced by index. On this machine that turns
/// a multi-megabyte blob into a fraction of it, keeping the load cost of a warm open in the
/// milliseconds where it belongs.
enum AnalyticsCacheCodec {
    /// Bumped whenever the on-disk shape changes.
    ///
    /// A mismatch **never** discards the blob. It used to, which was safe only while every bucket
    /// could be rebuilt from logs still on disk — and that stops being true the moment Claude Code
    /// deletes its first transcript, silently, with no way for the code to notice it crossed the
    /// line. A future maintainer bumping this constant for a perfectly good reason would then erase
    /// unrecoverable history, which is exactly how five months were lost once already. So the reader
    /// migrates what it can and *preserves* what it cannot: see `read(_:)` and
    /// `CostScanner.preserveUnreadableArchive`.
    ///
    /// Version 2 added the archive of vanished files and the coverage set.
    static let version = 2

    /// Versions this codec knows how to bring forward. Anything else is preserved, not parsed.
    static let migratableVersions: Set<Int> = [1]

    /// The outcome of reading a persisted blob. Modelled explicitly so the caller cannot
    /// accidentally treat "I could not read this" as "there was nothing there" — the two look
    /// identical through an `Optional` and only one of them is safe to overwrite.
    enum ReadResult {
        /// Current version, decoded as-is.
        case ok(AnalyticsCacheState)
        /// An older version brought forward. Safe to overwrite the blob with the new shape.
        case migrated(AnalyticsCacheState, from: Int)
        /// Unknown version or unparseable bytes. The caller MUST preserve the original data before
        /// writing anything to that key. `version` is `nil` when not even that could be read.
        case unreadable(version: Int?)
    }

    static func encode(_ state: AnalyticsCacheState) -> Data? {
        var interner = Interner()
        var files: [FileBlob] = []
        files.reserveCapacity(state.files.count)

        // Sorted by path so the encoded blob is byte-stable for an unchanged cache.
        for path in state.files.keys.sorted() {
            guard let record = state.files[path] else { continue }
            var buckets: [BucketBlob] = []
            buckets.reserveCapacity(record.buckets.count)
            for (key, totals) in record.buckets {
                buckets.append(BucketBlob(key: key, totals: totals, interner: &interner))
            }
            var ledger: [LedgerBlob]?
            if let entries = record.ledger {
                ledger = entries.map { LedgerBlob(key: $0.key, entry: $0.value, interner: &interner) }
            }
            files.append(FileBlob(
                path: path,
                size: record.size,
                mod: record.modified.timeIntervalSince1970,
                end: record.endOffset,
                buckets: buckets,
                ledger: ledger))
        }

        var archived: [ArchivedBlob] = []
        archived.reserveCapacity(state.archived.count)
        for path in state.archived.keys.sorted() {
            guard let buckets = state.archived[path] else { continue }
            archived.append(ArchivedBlob(
                path: path,
                buckets: buckets.map { BucketBlob(key: $0.key, totals: $0.value, interner: &interner) }))
        }

        let envelope = Envelope(
            v: Self.version,
            models: interner.models.table,
            projects: interner.projects.table,
            sessions: interner.sessions.table,
            files: files,
            archived: archived,
            covered: state.coveredDays.map(\.timeIntervalSince1970).sorted())
        return try? JSONEncoder().encode(envelope)
    }

    /// Read a persisted blob, migrating an older shape when possible and refusing — without
    /// destroying anything — when not.
    static func read(_ data: Data) -> ReadResult {
        // Probe the version on its own, so a blob whose *body* this build cannot parse is still
        // identifiable rather than falling into the anonymous "corrupt" bucket.
        let probed = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.v

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .unreadable(version: probed)
        }
        if envelope.v == Self.version {
            return .ok(Self.state(from: envelope))
        }
        guard Self.migratableVersions.contains(envelope.v) else {
            // Newer than this build, or a shape nobody wrote a migration for. Hands off.
            return .unreadable(version: envelope.v)
        }
        return .migrated(Self.migrate(envelope), from: envelope.v)
    }

    /// Convenience for callers that only care about the happy path (tests, mostly). Returns `nil`
    /// for anything unreadable — which is precisely why the scanner uses `read(_:)` instead: `nil`
    /// cannot be told apart from "empty", and one of those is safe to overwrite.
    static func decode(_ data: Data) -> AnalyticsCacheState? {
        switch Self.read(data) {
        case let .ok(state): return state
        case let .migrated(state, _): return state
        case .unreadable: return nil
        }
    }

    /// Bring an older envelope forward.
    ///
    /// Version 1 had no archive of vanished files and no coverage set. The archive starts empty
    /// (nothing had been archived yet, by construction), and coverage is seeded from the days the
    /// buckets already prove were observed — conservative: those days certainly had data. The next
    /// scan's `recordCoverage` widens it to the full span.
    private static func migrate(_ envelope: Envelope) -> AnalyticsCacheState {
        var state = Self.state(from: envelope)
        if state.coveredDays.isEmpty {
            state.coveredDays = Set(state.allBuckets().flatMap { $0.keys.map(\.day) })
        }
        return state
    }

    private static func state(from envelope: Envelope) -> AnalyticsCacheState {
        var state = AnalyticsCacheState()
        state.files.reserveCapacity(envelope.files.count)
        for blob in envelope.files {
            var buckets: [AnalyticsBucketKey: AnalyticsBucketTotals] = [:]
            buckets.reserveCapacity(blob.buckets.count)
            for bucket in blob.buckets {
                guard let key = bucket.key(envelope) else { continue }
                buckets[key] = bucket.totals
            }
            var ledger: [String: AnalyticsLedgerEntry]?
            if let blobs = blob.ledger {
                var entries: [String: AnalyticsLedgerEntry] = [:]
                entries.reserveCapacity(blobs.count)
                for entry in blobs {
                    guard let key = entry.bucketKey(envelope) else { continue }
                    entries[entry.k] = AnalyticsLedgerEntry(
                        offset: entry.f,
                        bucket: key,
                        totals: entry.totals)
                }
                ledger = entries
            }
            state.files[blob.path] = AnalyticsFileRecord(
                size: blob.size,
                modified: Date(timeIntervalSince1970: blob.mod),
                endOffset: blob.end,
                buckets: buckets,
                ledger: ledger)
        }

        for blob in envelope.archived {
            var buckets: [AnalyticsBucketKey: AnalyticsBucketTotals] = [:]
            buckets.reserveCapacity(blob.buckets.count)
            for bucket in blob.buckets {
                guard let key = bucket.key(envelope) else { continue }
                buckets[key] = bucket.totals
            }
            state.archived[blob.path] = buckets
        }
        state.coveredDays = Set(envelope.covered.map { Date(timeIntervalSince1970: $0) })

        return state
    }

    // MARK: String interning

    private struct StringTable {
        private(set) var table: [String] = []
        private var index: [String: Int] = [:]

        mutating func intern(_ value: String) -> Int {
            if let existing = self.index[value] { return existing }
            let position = self.table.count
            self.table.append(value)
            self.index[value] = position
            return position
        }
    }

    private struct Interner {
        var models = StringTable()
        var projects = StringTable()
        var sessions = StringTable()
    }

    // MARK: Wire format (short keys — this blob is written on every scan)

    /// Reads only the version, so a blob this build cannot parse can still be labelled instead of
    /// being filed away anonymously.
    private struct VersionProbe: Codable {
        let v: Int
    }

    private struct Envelope: Codable {
        let v: Int
        let models: [String]
        let projects: [String]
        let sessions: [String]
        let files: [FileBlob]
        /// Absent in version 1 — decoded as empty so an old blob parses instead of being rejected.
        let archived: [ArchivedBlob]
        /// Covered days as epoch seconds, sorted. Also absent in version 1.
        let covered: [Double]

        init(
            v: Int,
            models: [String],
            projects: [String],
            sessions: [String],
            files: [FileBlob],
            archived: [ArchivedBlob],
            covered: [Double])
        {
            self.v = v
            self.models = models
            self.projects = projects
            self.sessions = sessions
            self.files = files
            self.archived = archived
            self.covered = covered
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.v = try container.decode(Int.self, forKey: .v)
            self.models = try container.decode([String].self, forKey: .models)
            self.projects = try container.decode([String].self, forKey: .projects)
            self.sessions = try container.decode([String].self, forKey: .sessions)
            self.files = try container.decode([FileBlob].self, forKey: .files)
            self.archived = try container.decodeIfPresent([ArchivedBlob].self, forKey: .archived) ?? []
            self.covered = try container.decodeIfPresent([Double].self, forKey: .covered) ?? []
        }
    }

    private struct ArchivedBlob: Codable {
        let path: String
        let buckets: [BucketBlob]
    }

    private struct FileBlob: Codable {
        let path: String
        let size: Int64
        let mod: Double
        let end: Int64
        let buckets: [BucketBlob]
        let ledger: [LedgerBlob]?
    }

    private struct BucketBlob: Codable {
        let d: Double // start-of-day, epoch seconds
        let h: Int    // local hour
        let m: Int    // model table index
        let p: Int    // project table index
        let s: Int    // session table index
        let i: Int, o: Int, r: Int, w: Int // input / output / cache-read / cache-write
        let t: Double // first timestamp, epoch seconds

        init(key: AnalyticsBucketKey, totals: AnalyticsBucketTotals, interner: inout Interner) {
            self.d = key.day.timeIntervalSince1970
            self.h = key.hour
            self.m = interner.models.intern(key.model)
            self.p = interner.projects.intern(key.project)
            self.s = interner.sessions.intern(key.session)
            self.i = totals.inputTokens
            self.o = totals.outputTokens
            self.r = totals.cacheReadTokens
            self.w = totals.cacheWriteTokens
            self.t = totals.firstTimestamp.timeIntervalSince1970
        }

        func key(_ envelope: Envelope) -> AnalyticsBucketKey? {
            guard envelope.models.indices.contains(self.m),
                  envelope.projects.indices.contains(self.p),
                  envelope.sessions.indices.contains(self.s)
            else { return nil }
            return AnalyticsBucketKey(
                day: Date(timeIntervalSince1970: self.d),
                hour: self.h,
                model: envelope.models[self.m],
                project: envelope.projects[self.p],
                session: envelope.sessions[self.s])
        }

        var totals: AnalyticsBucketTotals {
            AnalyticsBucketTotals(
                inputTokens: self.i,
                outputTokens: self.o,
                cacheReadTokens: self.r,
                cacheWriteTokens: self.w,
                firstTimestamp: Date(timeIntervalSince1970: self.t))
        }
    }

    private struct LedgerBlob: Codable {
        let k: String // "messageId:requestId"
        let f: Int64  // byte offset
        let d: Double
        let h: Int
        let m: Int, p: Int, s: Int
        let i: Int, o: Int, r: Int, w: Int
        let t: Double

        init(key: String, entry: AnalyticsLedgerEntry, interner: inout Interner) {
            self.k = key
            self.f = entry.offset
            self.d = entry.bucket.day.timeIntervalSince1970
            self.h = entry.bucket.hour
            self.m = interner.models.intern(entry.bucket.model)
            self.p = interner.projects.intern(entry.bucket.project)
            self.s = interner.sessions.intern(entry.bucket.session)
            self.i = entry.totals.inputTokens
            self.o = entry.totals.outputTokens
            self.r = entry.totals.cacheReadTokens
            self.w = entry.totals.cacheWriteTokens
            self.t = entry.totals.firstTimestamp.timeIntervalSince1970
        }

        func bucketKey(_ envelope: Envelope) -> AnalyticsBucketKey? {
            guard envelope.models.indices.contains(self.m),
                  envelope.projects.indices.contains(self.p),
                  envelope.sessions.indices.contains(self.s)
            else { return nil }
            return AnalyticsBucketKey(
                day: Date(timeIntervalSince1970: self.d),
                hour: self.h,
                model: envelope.models[self.m],
                project: envelope.projects[self.p],
                session: envelope.sessions[self.s])
        }

        var totals: AnalyticsBucketTotals {
            AnalyticsBucketTotals(
                inputTokens: self.i,
                outputTokens: self.o,
                cacheReadTokens: self.r,
                cacheWriteTokens: self.w,
                firstTimestamp: Date(timeIntervalSince1970: self.t))
        }
    }
}
