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
public enum ClaudeStatusProbe: Sendable {
    /// Parse the raw `/usage` buffer into `(session, weekly)` utilization percentages (0–100).
    ///
    /// Returns `nil` only when no session percentage can be recovered by either the label-based or
    /// the positional path. When the weekly value is missing the session value is still returned and
    /// `weekly` defaults to `0` (a present-but-empty weekly window renders a 0% bar downstream).
    public static func parseUsage(rawOutput: String) -> (session: Double, weekly: Double)? {
        let clean = Self.stripANSICodes(rawOutput)
        guard !clean.isEmpty else { return nil }

        let lines = clean.components(separatedBy: .newlines)
        let normalizedLines = lines.map(Self.normalizedForLabelSearch)

        let sessionUtil = Self.utilization(
            forLabel: "current session",
            lines: lines,
            normalizedLines: normalizedLines)
        var weeklyUtil = Self.utilization(
            forLabel: "current week",
            lines: lines,
            normalizedLines: normalizedLines)

        // Positional fallback (AC10): if labels did not resolve, take the first two `\d+%` values in
        // the raw buffer as session / weekly utilization respectively.
        if sessionUtil == nil || weeklyUtil == nil {
            let ordered = Self.orderedUtilizations(in: lines)
            let session = sessionUtil ?? ordered[safe: 0]
            let weekly = weeklyUtil ?? sessionUtil.map { _ in ordered[safe: 1] } ?? ordered[safe: 1]
            guard let session else { return nil }
            return (session: session, weekly: weekly ?? 0)
        }

        guard let sessionUtil else { return nil }
        if weeklyUtil == nil { weeklyUtil = 0 }
        return (session: sessionUtil, weekly: weeklyUtil ?? 0)
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
        let modelTokens = ["opus", "sonnet", "haiku", "default"]
        return modelTokens.contains(where: lower.contains)
    }

    // MARK: - Positional fallback

    /// All percentages in the buffer, in order, normalized to utilization. Used when labels move or
    /// were renamed (AC10).
    private static func orderedUtilizations(in lines: [String]) -> [Double] {
        lines.compactMap(Self.utilizationFromLine)
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
