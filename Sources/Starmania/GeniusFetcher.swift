import Foundation
import SwiftSoup

/// Fetches lyrics from Genius.com using their API + HTML scraping.
class GeniusFetcher: @unchecked Sendable {
    static let shared = GeniusFetcher()
    
    private init() {}
    
    /// Search Genius for a song and scrape its lyrics.
    func fetchLyrics(title: String, artist: String, apiKey: String) async throws -> LyricsResult {
        // Step 1: Search via Genius API
        let query = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
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
              let firstHit = hits.first,
              let result = firstHit["result"] as? [String: Any],
              let pageURL = result["url"] as? String,
              let songTitle = result["title"] as? String,
              let primaryArtist = result["primary_artist"] as? [String: Any],
              let artistName = primaryArtist["name"] as? String else {
            throw GeniusError.noResults("No results found for '\(title)' by '\(artist)'")
        }
        
        // Step 2: Scrape lyrics from the Genius page
        let lyrics = try await scrapeLyrics(from: pageURL)
        
        return LyricsResult(
            lyrics: lyrics,
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
        
        // Genius uses div[data-lyrics-container="true"] for lyrics
        // Try multiple selectors as fallback
        let selectors = [
            "div[data-lyrics-container=\"true\"]",
            "div.lyrics",
            "div[class*=\"Lyrics__Container\"]"
        ]
        
        for selector in selectors {
            let elements = try doc.select(selector)
            if !elements.isEmpty() {
                // Get HTML content, replace <br> with newlines, then strip tags
                var lyricsText = ""
                for element in elements {
                    // Replace <br> tags with newlines before getting text
                    let innerHtml = try element.html()
                    let withNewlines = innerHtml
                        .replacingOccurrences(of: "<br>", with: "\n")
                        .replacingOccurrences(of: "<br/>", with: "\n")
                        .replacingOccurrences(of: "<br />", with: "\n")
                    
                    // Parse the modified HTML to strip remaining tags
                    let fragment = try SwiftSoup.parse(withNewlines)
                    let text = try fragment.text()
                    
                    if !lyricsText.isEmpty { lyricsText += "\n\n" }
                    lyricsText += text
                }
                
                let cleaned = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
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
