import Foundation

/// Shared text helpers for building queries and fuzzy-matching search results.
enum TextMatching {
    /// Strip bracketed/parenthesized suffixes: "(Remastered 2017)", "[Deluxe Edition]", "(feat. X)", etc.
    static func stripBrackets(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "[\\(\\[].*?[\\)\\]]",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize text for fuzzy matching: lowercase, strip diacritics, strip punctuation, collapse spaces.
    static func normalizeForMatching(_ text: String) -> String {
        var s = text.lowercased()
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        s = s.replacingOccurrences(of: "&", with: " and ")
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        s = s.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Word overlap between two strings (0.0 – 1.0): the average of the fraction of a's words
    /// found in b and the fraction of b's words found in a. Inputs are normalized first.
    static func wordOverlapScore(_ a: String, _ b: String) -> Double {
        let wordsA = Set(normalizeForMatching(a).split(separator: " ").map(String.init))
        let wordsB = Set(normalizeForMatching(b).split(separator: " ").map(String.init))

        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0.0 }

        let aInB = Double(wordsA.filter { wordsB.contains($0) }.count) / Double(wordsA.count)
        let bInA = Double(wordsB.filter { wordsA.contains($0) }.count) / Double(wordsB.count)

        return (aInB + bInA) / 2.0
    }

    /// Build a URL with properly encoded query items. Unlike `.urlQueryAllowed`, this encodes
    /// `&`, `+`, `#` and `=` inside values, so "Simon & Garfunkel" survives the round trip.
    static func url(_ base: String, query: [(String, String)]) -> URL? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" unescaped, which most servers decode as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }
}
