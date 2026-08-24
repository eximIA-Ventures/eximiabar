import Foundation
import Testing
@testable import ClaudeBarCore

/// Tests for ``ZIPWriter`` (EXB-6.1).
///
/// The container is checked against `/usr/bin/unzip`, not against this writer's own reading of its own
/// bytes. A self-consistent reader would happily accept a self-consistently wrong archive.
struct ZIPWriterTests {
    // MARK: - CRC-32

    /// The canonical CRC-32 check value: `"123456789"` → `0xCBF43926`.
    ///
    /// A published vector, so this fails if the polynomial, the initial value or the final inversion
    /// is wrong — none of which the round-trip tests below would catch, since `unzip` compares our CRC
    /// against our own bytes.
    @Test
    func crc32MatchesThePublishedCheckValue() {
        #expect(ZIPWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    /// CRC of nothing is zero — the boundary the empty-entry path relies on.
    @Test
    func crc32OfEmptyDataIsZero() {
        #expect(ZIPWriter.crc32(Data()) == 0)
    }

    // MARK: - The container, judged by Info-ZIP

    /// AC2: the archive passes `unzip -t`, and every payload comes back byte-identical through
    /// `unzip -p` — Info-ZIP decompressing, not us.
    @Test
    func archivePassesSystemUnzipAndRoundTrips() throws {
        let entries = [
            ZIPEntry(path: "a.txt", text: String(repeating: "compressible ", count: 200)),
            ZIPEntry(path: "nested/dir/b.xml", text: "<?xml version=\"1.0\"?><root><child/></root>"),
            ZIPEntry(path: "c.bin", payload: Data((0..<2048).map { UInt8($0 % 251) })),
        ]
        let archive = ZIPWriter.archive(entries)
        let url = ExportTestSupport.temporaryDirectory().appendingPathComponent("round-trip.zip")
        try archive.write(to: url)

        let test = try ExportTestSupport.run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "unzip -t rejected the archive: \(test.standardOutput)\(test.standardError)")
        #expect(test.standardOutput.contains("No errors detected"))

        // Extracted to disk rather than read off stdout: `c.bin` is not valid UTF-8, and comparing it
        // through a String would report a difference the archive does not have.
        let extracted = try ExportTestSupport.extract(url)
        for entry in entries {
            let file = extracted.appendingPathComponent(entry.path)
            let bytes = try Data(contentsOf: file)
            #expect(bytes == entry.payload, "payload differs for \(entry.path)")
        }
    }

    /// AC5: an empty entry and a one-byte entry are the two cases where `compression_encode_buffer`
    /// returns 0, and where a missing STORED fallback would produce an archive that is corrupt in
    /// silence. Both must survive Info-ZIP.
    @Test
    func emptyAndSingleByteEntriesSurvive() throws {
        let entries = [
            ZIPEntry(path: "empty.txt", payload: Data()),
            ZIPEntry(path: "one.txt", payload: Data([0x41])),
        ]
        let url = ExportTestSupport.temporaryDirectory().appendingPathComponent("edges.zip")
        try ZIPWriter.archive(entries).write(to: url)

        let test = try ExportTestSupport.run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "unzip -t rejected the archive: \(test.standardOutput)\(test.standardError)")

        let listing = try ExportTestSupport.run("/usr/bin/unzip", ["-l", url.path])
        #expect(listing.standardOutput.contains("empty.txt"))
        #expect(listing.standardOutput.contains("one.txt"))

        let one = try ExportTestSupport.run("/usr/bin/unzip", ["-p", url.path, "one.txt"])
        #expect(one.standardOutput == "A")
    }

    /// The STORED fallback, asserted at the guard itself.
    ///
    /// Note on what this does and does not prove: with the writer's `source.count + 512` buffer, an
    /// incompressible payload does not make the encoder return 0 — it returns a size **larger** than
    /// the input (64 random bytes deflate to 69). So removing this guard yields a valid but bloated
    /// archive, which `unzip -t` accepts; measured, not assumed. This test is therefore the only thing
    /// that kills that mutation, and the container round-trip below does not.
    @Test
    func deflateRefusesEmptyAndIncompressiblePayloads() {
        #expect(ZIPWriter.deflate(Data()) == nil)

        // Deterministic pseudo-random bytes: high entropy, so DEFLATE cannot beat the original size.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let noisy = Data((0..<64).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(state & 0xFF)
        })
        #expect(ZIPWriter.deflate(noisy) == nil)

        // And the compressible case still compresses, or the guard above would be vacuous.
        let repetitive = Data(String(repeating: "aaaabbbb", count: 200).utf8)
        let compressed = ZIPWriter.deflate(repetitive)
        #expect(compressed != nil)
        #expect((compressed?.count ?? .max) < repetitive.count)
    }

    // MARK: - Determinism

    /// AC3: the same entries always produce the same bytes.
    ///
    /// This is only true because the DOS date/time fields are written as zero. Swapping them for a real
    /// modification time would leave every other test green and break exactly this one.
    @Test
    func sameInputProducesTheSameBytes() {
        let entries = [
            ZIPEntry(path: "one.xml", text: "<a/>"),
            ZIPEntry(path: "two.txt", text: String(repeating: "x", count: 5_000)),
        ]
        let first = ZIPWriter.archive(entries)
        let second = ZIPWriter.archive(entries)
        #expect(ExportTestSupport.sha256(first) == ExportTestSupport.sha256(second))
        #expect(first == second)
    }

    /// The determinism has a named cause, so it is asserted at the cause too: both timestamp fields of
    /// the local header are zero. Bytes 10–13 of a local header are mod-time and mod-date.
    @Test
    func localHeaderTimestampsAreZeroed() {
        let archive = ZIPWriter.archive([ZIPEntry(path: "a", text: "b")])
        #expect(archive[10] == 0)
        #expect(archive[11] == 0)
        #expect(archive[12] == 0)
        #expect(archive[13] == 0)
    }

    /// Order is preserved verbatim — the writer never sorts, so callers control the archive layout and
    /// therefore its hash.
    @Test
    func entryOrderIsPreserved() throws {
        let url = ExportTestSupport.temporaryDirectory().appendingPathComponent("ordered.zip")
        try ZIPWriter.archive([
            ZIPEntry(path: "zebra.txt", text: "z"),
            ZIPEntry(path: "alpha.txt", text: "a"),
        ]).write(to: url)
        let listing = try ExportTestSupport.run("/usr/bin/unzip", ["-l", url.path])
        let zebra = try #require(listing.standardOutput.range(of: "zebra.txt"))
        let alpha = try #require(listing.standardOutput.range(of: "alpha.txt"))
        #expect(zebra.lowerBound < alpha.lowerBound)
    }

    // MARK: - Invariant I2

    /// AC6: nothing in the export engine launches a subprocess. Asserted over the whole directory, not
    /// just `ZIPWriter.swift`, because the point is the boundary and not the file.
    @Test
    func exportEngineLaunchesNoSubprocess() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ClaudeBarCore/Export")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.isEmpty, "the export engine directory should not be empty")
        for name in names where name.hasSuffix(".swift") {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!source.contains("Process("), "\(name) launches a subprocess")
            #expect(!source.contains("NSTask"), "\(name) launches a subprocess")
        }
    }
}
