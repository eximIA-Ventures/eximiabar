import Foundation

extension CostScanner {
    /// Stream the lines of a JSONL file starting at `offset`, invoking `onLine(lineBytes, lineStartOffset)`
    /// for each newline-terminated line, and return the absolute byte offset reached at EOF.
    ///
    /// Adapted from the reference `CostUsageJsonl.scan` (`Vendored/CostUsage/CostUsageJsonl.swift`),
    /// trimmed to Claude's needs and extended to report each line's **absolute start offset** so the
    /// scanner can dedup streaming chunks by "higher offset wins" (AC3). Reads in 256 KB chunks via a
    /// `FileHandle`; a single oversize line is capped at `maxLineBytes` (the assistant usage block
    /// sits near the line start, so the prefix is sufficient).
    ///
    /// Runs synchronously on the calling actor's executor — never the MainActor (AC13).
    @discardableResult
    static func scanLines(
        fileURL: URL,
        offset: Int64,
        maxLineBytes: Int,
        onLine: (_ line: Data, _ lineStartOffset: Int64) -> Void) throws -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var bytesRead: Int64 = 0
        // Absolute file offset where the current (in-progress) line began.
        var lineStartOffset: Int64 = startOffset

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < maxLineBytes {
                let appendCount = min(maxLineBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
        }

        func flushLine(nextLineStart: Int64) {
            if lineBytes > 0 {
                onLine(current, lineStartOffset)
            }
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            lineStartOffset = nextLineStart
        }

        while true {
            let chunk = try autoreleasepool { () -> Data in
                try handle.read(upToCount: 256 * 1024) ?? Data()
            }
            if chunk.isEmpty {
                // Final unterminated line (no trailing newline).
                flushLine(nextLineStart: startOffset + bytesRead)
                break
            }
            let chunkStartAbsolute = startOffset + bytesRead
            bytesRead += Int64(chunk.count)
            chunk.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var segmentStart = 0
                var index = 0
                while index < rawBuffer.count {
                    if base[index] == 0x0A { // '\n'
                        appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                        // The next line starts right after this newline, in absolute terms.
                        let nextLineStart = chunkStartAbsolute + Int64(index) + 1
                        flushLine(nextLineStart: nextLineStart)
                        segmentStart = index + 1
                    }
                    index += 1
                }
                if segmentStart < rawBuffer.count {
                    appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                }
            }
        }

        return startOffset + bytesRead
    }
}

extension Data {
    /// `true` when `self` contains `needle` as a contiguous byte subsequence. Used by the cost
    /// scanner's pre-filter to skip lines without JSON decoding (AC2). Mirrors the reference
    /// `Data.containsAscii`, but takes raw bytes to avoid re-encoding the needle per call.
    func containsAsciiSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard self.count >= needle.count else { return false }
        return self.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            let haystackCount = rawBuffer.count
            let first = needle[0]
            var i = 0
            let lastStart = haystackCount - needle.count
            while i <= lastStart {
                if base[i] == first {
                    var match = true
                    var j = 1
                    while j < needle.count {
                        if base[i + j] != needle[j] { match = false; break }
                        j += 1
                    }
                    if match { return true }
                }
                i += 1
            }
            return false
        }
    }
}
