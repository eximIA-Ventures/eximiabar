import Compression
import Foundation

/// One file inside the archive. `path` is the full in-archive path with forward slashes
/// (e.g. `xl/worksheets/sheet1.xml`); `payload` is the uncompressed bytes.
public struct ZIPEntry: Sendable, Equatable {
    /// In-archive path, forward-slash separated, never leading with `/`.
    public let path: String
    /// The uncompressed content.
    public let payload: Data

    public init(path: String, payload: Data) {
        self.path = path
        self.payload = payload
    }

    /// Convenience for the XML parts, which are always UTF-8 text.
    public init(path: String, text: String) {
        self.init(path: path, payload: Data(text.utf8))
    }
}

/// Writes a ZIP archive in pure Swift — no `Process`, no `/usr/bin/zip`, no external dependency.
///
/// **Why this exists (EXB-6.1).** An `.xlsx` is a ZIP container, and the two obvious ways to make one
/// are both rejected by this project's invariants: a third-party library would be the first external
/// dependency in `Package.swift`, and shelling out to `/usr/bin/zip` would launch a subprocess (I2)
/// and force a temporary directory of loose files. Writing the container by hand costs ~120 lines and
/// removes both problems.
///
/// **Determinism is a feature, not an accident.** The DOS date/time fields of every header are written
/// as zero on purpose, so the same input always produces the same bytes and a sha256 can be asserted
/// in a test. A real modification time would silently break that.
///
/// Only the two features an `.xlsx` needs are implemented: STORED (method 0) and DEFLATE (method 8),
/// no ZIP64, no encryption, no data descriptors. Files above 4 GiB are out of scope by construction.
public enum ZIPWriter {
    // MARK: - Public API

    /// Packs `entries` into a ZIP archive, preserving the given order.
    ///
    /// Entries are emitted in the order received; the central directory repeats that order. Callers
    /// that need a stable archive must therefore pass a stable order — this writer never sorts.
    public static func archive(_ entries: [ZIPEntry]) -> Data {
        var local = Data()
        var central = Data()
        var count = 0

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.payload)
            let compressed = deflate(entry.payload)
            let method: UInt16 = compressed == nil ? Method.stored : Method.deflate
            let body = compressed ?? entry.payload
            let offset = UInt32(local.count)

            // ---- local file header ----
            local.appendLE32(Signature.localHeader)
            local.appendLE16(versionNeeded)
            local.appendLE16(0) // general purpose flags
            local.appendLE16(method)
            local.appendLE16(0) // modification time — zeroed for determinism
            local.appendLE16(0) // modification date — zeroed for determinism
            local.appendLE32(crc)
            local.appendLE32(UInt32(body.count))
            local.appendLE32(UInt32(entry.payload.count))
            local.appendLE16(UInt16(name.count))
            local.appendLE16(0) // extra field length
            local.append(name)
            local.append(body)

            // ---- central directory header ----
            central.appendLE32(Signature.centralHeader)
            central.appendLE16(versionMadeBy)
            central.appendLE16(versionNeeded)
            central.appendLE16(0) // general purpose flags
            central.appendLE16(method)
            central.appendLE16(0) // modification time — zeroed for determinism
            central.appendLE16(0) // modification date — zeroed for determinism
            central.appendLE32(crc)
            central.appendLE32(UInt32(body.count))
            central.appendLE32(UInt32(entry.payload.count))
            central.appendLE16(UInt16(name.count))
            central.appendLE16(0) // extra field length
            central.appendLE16(0) // file comment length
            central.appendLE16(0) // disk number start
            central.appendLE16(0) // internal file attributes
            central.appendLE32(0) // external file attributes
            central.appendLE32(offset)
            central.append(name)

            count += 1
        }

        let centralOffset = UInt32(local.count)
        var out = local
        out.append(central)

        // ---- end of central directory ----
        out.appendLE32(Signature.endOfCentralDirectory)
        out.appendLE16(0) // this disk number
        out.appendLE16(0) // disk with the central directory
        out.appendLE16(UInt16(count))
        out.appendLE16(UInt16(count))
        out.appendLE32(UInt32(central.count))
        out.appendLE32(centralOffset)
        out.appendLE16(0) // comment length
        return out
    }

    // MARK: - CRC-32 (IEEE 802.3)

    /// The standard IEEE polynomial table, built once at first use.
    ///
    /// A `static let` of a `Sendable` element type is safe under Swift 6 strict concurrency: it is
    /// immutable and initialised exactly once by the runtime.
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// CRC-32 of `data`, as the ZIP format defines it.
    ///
    /// **Computed over the UNCOMPRESSED payload**, never over the deflated body — getting this
    /// backwards produces an archive that `unzip -t` rejects with a CRC error per entry.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - DEFLATE

    /// Raw DEFLATE (RFC 1951) of `source`, or `nil` when the entry should be STORED instead.
    ///
    /// `COMPRESSION_ZLIB` in Apple's `Compression` emits **raw** DEFLATE, not the zlib wrapper —
    /// verified by round-tripping through Python's `zlib.decompressobj(-15)`. That is exactly ZIP
    /// method 8, which is what makes the whole no-dependency approach work.
    ///
    /// Returning `nil` covers two different situations, and it is worth naming which is which because
    /// they were measured on this machine rather than assumed:
    ///
    /// - `written == 0` — the encoder refused, and 0 is indistinguishable from "compressed to nothing".
    ///   Writing that as a DEFLATE body produces an archive that is corrupt in silence. Reproduced by
    ///   shrinking the destination buffer: a 1-byte payload into a 1-byte buffer returns 0.
    /// - `written >= source.count` — the encoder succeeded but the result is **bigger** than the input,
    ///   which is what actually happens with the generous buffer below: a 1-byte payload deflates to 3
    ///   bytes, and 64 random bytes to 69. That archive is valid, only larger than it needs to be.
    ///
    /// So with `source.count + 512` of slack the first case does not arise for small entries; the guard
    /// keeps it anyway, because the buffer size is an implementation detail and 0 is the documented
    /// failure return.
    static func deflate(_ source: Data) -> Data? {
        guard !source.isEmpty else { return nil }
        var destination = [UInt8](repeating: 0, count: source.count + 512)
        let written = source.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &destination, destination.count,
                base, source.count,
                nil, COMPRESSION_ZLIB
            )
        }
        // 0 → the encoder refused; >= source.count → compression would grow the entry. Both mean STORED.
        guard written > 0, written < source.count else { return nil }
        return Data(destination[0..<written])
    }

    // MARK: - Constants

    private enum Signature {
        static let localHeader: UInt32 = 0x0403_4B50
        static let centralHeader: UInt32 = 0x0201_4B50
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    }

    private enum Method {
        static let stored: UInt16 = 0
        static let deflate: UInt16 = 8
    }

    /// 2.0 — the minimum that understands DEFLATE.
    private static let versionNeeded: UInt16 = 20
    private static let versionMadeBy: UInt16 = 20
}

// MARK: - Little-endian appenders

extension Data {
    /// Appends `value` as two little-endian bytes.
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    /// Appends `value` as four little-endian bytes.
    mutating func appendLE32(_ value: UInt32) {
        for shift in stride(from: UInt32(0), to: 32, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
}
