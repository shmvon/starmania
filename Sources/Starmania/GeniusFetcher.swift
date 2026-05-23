import Foundation
import SwiftSoup

/// Fetches lyrics from Genius.com using their API + HTML scraping.
class GeniusFetcher: @unchecked Sendable {
    static let shared = GeniusFetcher()
    
    private init() {}
    
    /// Search Genius for a song and scrape its lyrics.
    func fetchLyrics(title: String, artist: String, apiKey: String) async throws -> LyricsResult {
        // Step 1: Search via Genius API
        let cleanTitle = title.replacingOccurrences(of: "'", with: " ")
                              .replacingOccurrences(of: "‘", with: " ")
                              .replacingOccurrences(of: "’", with: " ")
                              .replacingOccurrences(of: "-", with: " ")
        let cleanArtist = artist.replacingOccurrences(of: "'", with: " ")
        
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
        
        let keywords = ["traduzion", "translati", "traducción", "traduction", "übersetzung"]
        var filteredHits = hits.filter { hit in
            guard let result = hit["result"] as? [String: Any] else { return false }
            let hitTitle = (result["title"] as? String)?.lowercased() ?? ""
            let hitFullTitle = (result["full_title"] as? String)?.lowercased() ?? ""
            let artistName = ((result["primary_artist"] as? [String: Any])?["name"] as? String)?.lowercased() ?? ""
            
            let combined = "\(hitTitle) \(hitFullTitle) \(artistName)"
            return !keywords.contains { combined.contains($0) }
        }
        
        if filteredHits.isEmpty {
            filteredHits = hits
        }
        
        // Ensure artist matches
        let searchArtist = artist.lowercased()
        let artistMatchedHits = filteredHits.filter { hit in
            guard let result = hit["result"] as? [String: Any],
                  let artistName = ((result["primary_artist"] as? [String: Any])?["name"] as? String)?.lowercased() else { return false }
            return artistName.contains(searchArtist) || searchArtist.contains(artistName)
        }
        
        if !artistMatchedHits.isEmpty {
            filteredHits = artistMatchedHits
        }
        
        // Ensure title roughly matches (ignoring quotes and spaces)
        let cleanSearchTitle = title.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: " ", with: "")
            
        let titleMatchedHits = filteredHits.filter { hit in
            guard let result = hit["result"] as? [String: Any],
                  let hitTitle = (result["title"] as? String)?.lowercased()
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "‘", with: "")
                    .replacingOccurrences(of: "’", with: "")
                    .replacingOccurrences(of: " ", with: "") else { return false }
            return hitTitle.contains(cleanSearchTitle) || cleanSearchTitle.contains(hitTitle)
        }
        
        if !titleMatchedHits.isEmpty {
            filteredHits = titleMatchedHits
        }
        
        let bestHit = filteredHits.min { a, b in
            let titleA = (a["result"] as? [String: Any])?["title"] as? String ?? ""
            let titleB = (b["result"] as? [String: Any])?["title"] as? String ?? ""
            return abs(titleA.count - title.count) < abs(titleB.count - title.count)
        }
        
        guard let firstHit = bestHit,
              let result = firstHit["result"] as? [String: Any],
              let pageURL = result["url"] as? String,
              let songTitle = result["title"] as? String,
              let primaryArtist = result["primary_artist"] as? [String: Any],
              let artistName = primaryArtist["name"] as? String else {
            throw GeniusError.noResults("No results found for '\(title)' by '\(artist)'")
        }
        
        // Step 2: Scrape lyrics from the Genius page
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
