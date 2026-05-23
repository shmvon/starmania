import Foundation
import SwiftSoup

/// Fetches lyrics from Genius.com using their API + HTML scraping.
class GeniusFetcher: @unchecked Sendable {
    static let shared = GeniusFetcher()
    
    private init() {}
    
    // MARK: - Public API
    
    /// Search Genius for a song and scrape its lyrics.
    func fetchLyrics(title: String, artist: String, apiKey: String) async throws -> LyricsResult {
        // Step 1: Clean the title — strip bracketed/parenthesized suffixes
        let coreTitle = stripBrackets(title)
        let cleanTitle = coreTitle
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\u{2018}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let cleanArtist = artist
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\u{2018}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: " ")
        
        let query = "\(cleanArtist) \(cleanTitle)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = URL(string: "https://api.genius.com/search?q=\(query)")!
        
        var request = URLRequest(url: searchURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GeniusError.apiError("Search failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Parse search results
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseDict = json["response"] as? [String: Any],
              let hits = responseDict["hits"] as? [[String: Any]],
              !hits.isEmpty else {
            throw GeniusError.noResults("No results found for '\(title)' by '\(artist)'")
        }
        
        // Step 2: Filter to song-type hits only
        var candidates = hits.filter { hit in
            (hit["type"] as? String) == "song"
        }
        
        if candidates.isEmpty {
            throw GeniusError.noResults("No song results found for '\(title)' by '\(artist)'")
        }
        
        // Step 3: Filter out translations
        let translationKeywords = ["traduzion", "translati", "traducción", "traduction", "übersetzung"]
        candidates = candidates.filter { hit in
            guard let result = hit["result"] as? [String: Any] else { return false }
            let hitTitle = (result["title"] as? String)?.lowercased() ?? ""
            let hitFullTitle = (result["full_title"] as? String)?.lowercased() ?? ""
            let combined = "\(hitTitle) \(hitFullTitle)"
            return !translationKeywords.contains { combined.contains($0) }
        }
        
        if candidates.isEmpty {
            throw GeniusError.noResults("No matching results for '\(title)' by '\(artist)'")
        }
        
        // Step 4: Filter to hits with complete lyrics
        let lyricsFilteredCandidates = candidates.filter { hit in
            guard let result = hit["result"] as? [String: Any] else { return false }
            let lyricsState = result["lyrics_state"] as? String
            return lyricsState == "complete"
        }
        if !lyricsFilteredCandidates.isEmpty {
            candidates = lyricsFilteredCandidates
        }
        
        // Step 5: Score each candidate by artist + title match quality
        let normalizedArtist = normalizeForMatching(artist)
        let normalizedTitle = normalizeForMatching(coreTitle)
        
        var scored: [(hit: [String: Any], score: Double)] = candidates.compactMap { hit in
            guard let result = hit["result"] as? [String: Any],
                  let primaryArtist = result["primary_artist"] as? [String: Any],
                  let hitArtistName = primaryArtist["name"] as? String,
                  let hitTitle = result["title"] as? String else { return nil }
            
            let normalizedHitArtist = normalizeForMatching(hitArtistName)
            let normalizedHitTitle = normalizeForMatching(stripBrackets(hitTitle))
            
            let artistScore = wordOverlapScore(normalizedArtist, normalizedHitArtist)
            let titleScore = wordOverlapScore(normalizedTitle, normalizedHitTitle)
            
            // Artist must match reasonably well (at least 50% word overlap)
            guard artistScore >= 0.5 else { return nil }
            // Title must match reasonably well (at least 40% word overlap)
            guard titleScore >= 0.4 else { return nil }
            
            // Combined score: weight artist slightly more
            let combined = artistScore * 0.45 + titleScore * 0.55
            return (hit, combined)
        }
        
        if scored.isEmpty {
            throw GeniusError.noResults("No matching song found for '\(title)' by '\(artist)'")
        }
        
        // Sort by score descending, then by title-length closeness as tiebreaker
        scored.sort { a, b in
            if abs(a.score - b.score) > 0.01 {
                return a.score > b.score
            }
            let titleA = ((a.hit["result"] as? [String: Any])?["title"] as? String) ?? ""
            let titleB = ((b.hit["result"] as? [String: Any])?["title"] as? String) ?? ""
            return abs(titleA.count - coreTitle.count) < abs(titleB.count - coreTitle.count)
        }
        
        guard let bestHit = scored.first?.hit,
              let result = bestHit["result"] as? [String: Any],
              let pageURL = result["url"] as? String,
              let songTitle = result["title"] as? String,
              let primaryArtist = result["primary_artist"] as? [String: Any],
              let artistName = primaryArtist["name"] as? String else {
            throw GeniusError.noResults("No results found for '\(title)' by '\(artist)'")
        }
        
        // Step 6: Scrape lyrics from the Genius page
        let rawLyrics = try await scrapeLyrics(from: pageURL)
        
        // Format the lyrics exactly as requested
        let formattedLyrics = """
        \(artistName) - \(songTitle)
        
        \(rawLyrics)
        
        Lyrics: \(pageURL)
        """
        
        return LyricsResult(
            lyrics: formattedLyrics,
            geniusURL: pageURL,
            songTitle: songTitle,
            artistName: artistName
        )
    }
    
    // MARK: - Text Normalization
    
    /// Strip bracketed/parenthesized suffixes: "(Remastered 2017)", "[Deluxe Edition]", "(feat. X)", etc.
    private func stripBrackets(_ text: String) -> String {
        // Remove all (...) and [...] groups
        let stripped = text.replacingOccurrences(
            of: "[\\(\\[].*?[\\)\\]]",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Normalize text for fuzzy matching: lowercase, strip diacritics, strip punctuation, collapse spaces
    private func normalizeForMatching(_ text: String) -> String {
        var s = text.lowercased()
        // Strip diacritics
        s = s.folding(options: .diacriticInsensitive, locale: .current)
        // Remove "the " prefix
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        // Remove punctuation and extra whitespace
        s = s.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
    
    /// Compute word overlap score between two normalized strings (0.0 – 1.0).
    /// Returns the average of (fraction of a's words found in b) and (fraction of b's words found in a).
    private func wordOverlapScore(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.split(separator: " ").map(String.init))
        let wordsB = Set(b.split(separator: " ").map(String.init))
        
        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0.0 }
        
        let aInB = Double(wordsA.filter { wordsB.contains($0) }.count) / Double(wordsA.count)
        let bInA = Double(wordsB.filter { wordsA.contains($0) }.count) / Double(wordsB.count)
        
        return (aInB + bInA) / 2.0
    }
    
    // MARK: - Lyrics Scraping
    
    /// Scrape lyrics text from a Genius song page URL.
    private func scrapeLyrics(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw GeniusError.invalidURL(urlString)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Set a browser-like User-Agent to avoid being blocked
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw GeniusError.parseError("Could not decode page HTML")
        }
        
        let doc = try SwiftSoup.parse(html)
        
        // Preserve newlines before calling .text()
        for br in try doc.select("br") {
            try br.append("\\n")
        }
        for div in try doc.select("div") {
            try div.append("\\n")
        }
        for p in try doc.select("p") {
            try p.prepend("\\n\\n")
        }
        
        // Genius uses div[data-lyrics-container="true"] for lyrics
        let selectors = [
            "div[data-lyrics-container=\"true\"]",
            "div.lyrics",
            "div[class*=\"Lyrics__Container\"]"
        ]
        
        for selector in selectors {
            let elements = try doc.select(selector)
            if !elements.isEmpty() {
                var lyricsText = ""
                for element in elements {
                    let text = try element.text()
                    if !lyricsText.isEmpty { lyricsText += "\\n" }
                    lyricsText += text
                }
                
                // Convert literal \n markers back to actual newlines
                var cleaned = lyricsText.replacingOccurrences(of: "\\n", with: "\n")
                
                // Clean up spacing around newlines
                cleaned = cleaned.replacingOccurrences(of: " \n", with: "\n")
                cleaned = cleaned.replacingOccurrences(of: "\n ", with: "\n")
                
                // Remove the prefix header (e.g. "2 Contributors In Het Gras Lyrics", or "Translations...")
                // We use a regex to strip everything from the start up to the word "Lyrics" if it occurs in the first 200 characters.
                // It also strips out Genius bios that end in "Read More".
                let headerRegex = "^(?s)(?:.*?\\bLyrics\\b\\s*)?(?:.*?Read More\\s*)?"
                if let range = cleaned.range(of: headerRegex, options: [.regularExpression, .caseInsensitive]) {
                    if range.lowerBound == cleaned.startIndex {
                        // Only remove if it actually matched something substantive like Lyrics or Read More
                        let match = String(cleaned[range])
                        if match.lowercased().contains("lyrics") || match.lowercased().contains("read more") {
                            cleaned.removeSubrange(range)
                        }
                    }
                }
                
                // Fallback for simple "Contributors ... Lyrics"
                let fallbackRegex = "^(?:\\d*\\s*Contributors?\\s*|Translations.*?\\s*)?.*?Lyrics\\s*"
                if let range = cleaned.range(of: fallbackRegex, options: [.regularExpression, .caseInsensitive]) {
                    if range.lowerBound == cleaned.startIndex {
                        cleaned.removeSubrange(range)
                    }
                }
                
                // Collapse multiple newlines to a maximum of two
                cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        
        throw GeniusError.parseError("Could not find lyrics on the page")
    }
}

// MARK: - Errors

enum GeniusError: LocalizedError {
    case apiError(String)
    case noResults(String)
    case invalidURL(String)
    case parseError(String)
    
    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Genius API error: \(msg)"
        case .noResults(let msg): return msg
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
