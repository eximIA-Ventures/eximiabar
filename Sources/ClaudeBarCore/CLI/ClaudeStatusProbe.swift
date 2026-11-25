import Foundation

/// Pure, process-free parser for the `claude` CLI `/usage` TUI panel (AC3d–AC3e, AC10, AC11).
///
/// The only entry point that downstream code uses is ``parseUsage(rawOutput:)``, a pure function
/// that takes the raw terminal buffer captured from the PTY and returns
/// `(session, weekly)` as **utilization percentages** (percent USED, 0–100) — matching
/// `RateWindow.utilization` semantics, where `remaining == 100 - utilization`.
///
/// Parsing is label-driven first (find `"Current session"` / `"Current week"`, read the `\d+%`
/// on/after that label), with a positional fallback (first two `\d+%` in the buffer) when the TUI
/// layout changes (AC10). The percent-direction heuristic mirrors
/// `_reference_codexbar/.../ClaudeStatusProbe.swift:337-360` — a value labelled "left"/"remaining"
/// is remaining (so `utilization = 100 - value`), while "used"/"spent" is utilization verbatim.
public struct ClaudeUsageReading: Sendable, Equatable {
    public let session: Double
    public let weekly: Double
    /// `true` when at least one value came from the positional fallback rather than a label.
    public let isPositional: Bool
}

public enum ClaudeStatusProbe: Sendable {
    /// Parse the raw `/usage` buffer into `(session, weekly)` utilization percentages (0–100).
    ///
    /// Thin wrapper over ``parseUsageReading(rawOutput:)`` kept for existing callers.
    public static func parseUsage(rawOutput: String) -> (session: Double, weekly: Double)? {
        guard let reading = Self.parseUsageReading(rawOutput: rawOutput) else { return nil }
        return (session: reading.session, weekly: reading.weekly)
    }

    /// Most percent-bearing lines the positional fallback will trust (EXB-6.1 AC1.2). Past this,
    /// "the first two" is a guess about a layout we no longer recognise, not a reading.
    static let maxPositionalCandidates = 4

    /// Parse the raw `/usage` buffer, reporting whether the positional fallback was used.
    ///
    /// Label-driven first. The positional fallback (EXB-6.1 AC1) is now gated: every value it uses
    /// must be a **raw** 0–100 (a `140%` is a misread, not a full meter), the buffer may carry at most
    /// ``maxPositionalCandidates`` percent lines, and it needs at least two of them unless the
    /// session label already resolved.
    public static func parseUsageReading(rawOutput: String) -> ClaudeUsageReading? {
        let clean = Self.stripANSICodes(rawOutput)
        guard !clean.isEmpty else { return nil }

        let lines = clean.components(separatedBy: .newlines)
        let normalizedLines = lines.map(Self.normalizedForLabelSearch)

        let sessionUtil = Self.utilization(
            forLabel: "current session",
            lines: lines,
            normalizedLines: normalizedLines)
        let weeklyUtil = Self.utilization(
            forLabel: "current week",
            lines: lines,
            normalizedLines: normalizedLines)

        if let sessionUtil, let weeklyUtil {
            return ClaudeUsageReading(session: sessionUtil, weekly: weeklyUtil, isPositional: false)
        }

        // A session label with no weekly label and no other percent line is a session-only panel
        // (enterprise): labelled, not positional.
        let candidates = lines.filter { Self.rawPercent(in: $0) != nil && !Self.isLikelyStatusContextLine($0) }
        if let sessionUtil, candidates.count <= 1 {
            return ClaudeUsageReading(session: sessionUtil, weekly: 0, isPositional: false)
        }

        // Positional fallback, gated (EXB-6.1 AC1.1/AC1.2).
        guard candidates.count <= Self.maxPositionalCandidates else { return nil }
        guard candidates.allSatisfy({ (Self.rawPercent(in: $0) ?? -1) >= 0 && (Self.rawPercent(in: $0) ?? 101) <= 100 })
        else { return nil }
        let ordered = candidates.compactMap(Self.utilizationFromLine)
        if let sessionUtil {
            guard let weekly = ordered.dropFirst().first else {
                return ClaudeUsageReading(session: sessionUtil, weekly: 0, isPositional: false)
            }
            return ClaudeUsageReading(session: sessionUtil, weekly: weekly, isPositional: true)
        }
        guard ordered.count >= 2 else { return nil }
        return ClaudeUsageReading(session: ordered[0], weekly: ordered[1], isPositional: true)
    }

    /// The unclamped number in front of the first `%` on `line`, or `nil` when there is none.
    static func rawPercent(in line: String) -> Double? {
        let pattern = #"([0-9]{1,4}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              let valRange = Range(match.range(at: 1), in: line)
        else { return nil }
        return Double(line[valRange])
    }

    // MARK: - Label-based extraction

    /// Finds the first line containing `label` (normalized) and reads a percentage from a small
    /// window starting at that line. Returns the value as **utilization** (percent used).
    private static func utilization(
        forLabel label: String,
        lines: [String],
        normalizedLines: [String]) -> Double?
    {
        let needle = Self.normalizedForLabelSearch(label)
        for (idx, normalized) in normalizedLines.enumerated() where normalized.contains(needle) {
            // The usage panel can take a few lines to render the percent after the label.
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let util = Self.utilizationFromLine(candidate) { return util }
            }
        }
        return nil
    }

    /// Extracts a percentage from a single line and normalizes it to **utilization** (percent used).
    ///
    /// - "used" / "spent" / "consumed" → value is already utilization.
    /// - "left" / "remaining" / "available" → value is remaining → `utilization = 100 - value`.
    /// - otherwise (bare `NN%`) → assume the value is utilization (percent used). The `claude` TUI
    ///   labels the session/week meters with the percentage *used*; treating a bare value as used
    ///   keeps the positional fallback consistent.
    static func utilizationFromLine(_ line: String) -> Double? {
        if Self.isLikelyStatusContextLine(line) { return nil }

        // Optional Unicode whitespace before `%` to tolerate CLI formatting changes.
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line)
        else { return nil }

        let raw = Double(line[valRange]) ?? 0
        let clamped = max(0, min(100, raw))
        let lower = line.lowercased()
        let remainingKeywords = ["left", "remaining", "available"]
        let usedKeywords = ["used", "spent", "consumed"]
        if remainingKeywords.contains(where: lower.contains) {
            return max(0, min(100, 100 - clamped))
        }
        if usedKeywords.contains(where: lower.contains) {
            return clamped
        }
        // Bare percentage with no direction keyword → treat as utilization (percent used).
        return clamped
    }

    /// The `claude` status bar renders a `… | Opus 0% …` context meter that must not be mistaken for
    /// a usage value. Lines that look like the model context meter are skipped.
    private static func isLikelyStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        let modelTokens = ["opus", "sonnet", "haiku", "fable", "mythos", "default"]
        return modelTokens.contains(where: lower.contains)
    }

    // MARK: - Helpers

    /// Removes ANSI/VT100 escape sequences from a terminal buffer so percentages and labels can be
    /// matched against the rendered text.
    static func stripANSICodes(_ text: String) -> String {
        let patterns = [
            #"\u{1B}\[[0-9;?]*[A-Za-z]"#,   // CSI sequences (colors, cursor moves)
            #"\u{1B}\][^\u{07}]*\u{07}"#,    // OSC sequences terminated by BEL
            #"\u{1B}[@-Z\\-_]"#,             // 2-byte escapes
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Lowercased alphanumeric-only form for resilient label matching (ignores spacing/punctuation).
    static func normalizedForLabelSearch(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}

private extension Array {
    /// Bounds-checked subscript — returns `nil` instead of trapping.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
