import Foundation

// MARK: - Synced Lyrics

struct LyricLine: Equatable, Identifiable {
    let id: Int
    let time: Double  // seconds
    let text: String
}

/// Reads LRC ("[mm:ss.xx] line") lyrics, whether they come from a provider or sit in a file tag.
enum LRCParser {
    // Built per call: NSRegularExpression isn't Sendable on older SDKs, so it can't be a static let
    nonisolated private static var stampRegex: NSRegularExpression { try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]") }
    nonisolated private static var offsetRegex: NSRegularExpression { try! NSRegularExpression(pattern: "^\\s*\\[offset:\\s*([+-]?\\d+)\\s*\\]", options: .caseInsensitive) }
    nonisolated private static var metadataRegex: NSRegularExpression { try! NSRegularExpression(pattern: "^\\s*\\[[a-zA-Z#]+:[^\\]]*\\]\\s*$") }

    /// Parse LRC text into time-sorted lines. Lines with several timestamps
    /// ("[00:12.00][01:30.00] chorus") are expanded once per timestamp. `[offset:ms]` is applied:
    /// a positive offset shows lines earlier, as the LRC format specifies.
    nonisolated static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        let offset = Double(offsetMilliseconds(in: lrc)) / 1000
        let stampRegex = stampRegex

        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = stampRegex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((max(0, minutes * 60 + seconds - offset), text))
            }
        }

        return entries
            .enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }  // Stable for equal times
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.element.0, text: $0.element.element.1) }
    }

    nonisolated static func offsetMilliseconds(in lrc: String) -> Int {
        let offsetRegex = offsetRegex
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let match = offsetRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                return Int(ns.substring(with: match.range(at: 1))) ?? 0
            }
        }
        return 0
    }

    /// True when the text is LRC: at least 3 timed lines, and timed lines make up at least
    /// half of the non-empty, non-metadata lines. Plain lyrics that merely mention "[Chorus]" don't count.
    nonisolated static func isSynced(_ text: String) -> Bool {
        var timed = 0
        var other = 0
        let stampRegex = stampRegex
        let metadataRegex = metadataRegex
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            if trimmed.isEmpty || metadataRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil { continue }
            if let match = stampRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               match.range.location == 0 {
                timed += 1
            } else {
                other += 1
            }
        }
        return timed >= 3 && timed >= other
    }

    /// Lyrics text with timestamps and metadata removed. Empty timed lines are blank lines
    /// between stanzas, unless they follow most lines (then they only mark where a line ends).
    nonisolated static func plainText(_ lrc: String) -> String {
        let lines = parse(lrc)
        guard !lines.isEmpty else { return lrc.trimmingCharacters(in: .whitespacesAndNewlines) }
        let emptyCount = lines.filter { $0.text.isEmpty }.count
        let emptyMarksLineEnds = Double(emptyCount) >= Double(lines.count) * 0.4

        var output: [String] = []
        for line in lines {
            if line.text.isEmpty {
                if !emptyMarksLineEnds, let last = output.last, !last.isEmpty { output.append("") }
            } else {
                output.append(line.text)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    nonisolated static func currentLineIndex(in lines: [LyricLine], at time: Double) -> Int? {
        var result: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= time { result = i } else { break }
        }
        return result
    }
}

// MARK: - Lyrics Similarity

enum LyricsSimilarity {
    /// How much two lyrics texts agree, 0…1: twice the longest common word sequence divided
    /// by the total word count, after normalising case, accents and punctuation. Timestamps are
    /// stripped first, so LRC and plain versions of the same lyrics score 1.
    nonisolated static func score(_ a: String, _ b: String) -> Double {
        let wordsA = words(a)
        let wordsB = words(b)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let lcs = longestCommonSubsequence(wordsA, wordsB)
        return 2 * Double(lcs) / Double(wordsA.count + wordsB.count)
    }

    nonisolated static func words(_ text: String) -> [String] {
        let plain = LRCParser.isSynced(text) ? LRCParser.plainText(text) : text
        // Section labels like "[Chorus]" aren't sung words
        let unlabelled = plain.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        return TextMatching.normalizeForMatching(unlabelled).split(separator: " ").map(String.init)
    }

    nonisolated private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
