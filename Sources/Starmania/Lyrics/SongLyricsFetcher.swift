import Foundation
import SwiftSoup

/// Fetches lyrics from SongLyrics.com using URL slug pattern and search fallback with SwiftSoup parsing.
class SongLyricsFetcher: @unchecked Sendable {
    static let shared = SongLyricsFetcher()

    private init() {}

    func fetchLyrics(title: String, artist: String) async throws -> LyricsResult {
        let cleanTitle = TextMatching.stripBrackets(title)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        // Attempt 1: Direct slug URL
        if let directResult = try? await fetchDirectSlug(artist: cleanArtist, title: cleanTitle) {
            return directResult
        }

        // Attempt 2: Search fallback
        return try await searchAndFetch(artist: cleanArtist, title: cleanTitle)
    }

    // MARK: - Direct Slug Attempt

    private func fetchDirectSlug(artist: String, title: String) async throws -> LyricsResult {
        let artistSlug = slugify(artist)
        let titleSlug = slugify(title)

        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            throw SongLyricsError.invalidQuery("Empty slug")
        }

        let urlString = "https://www.songlyrics.com/\(artistSlug)/\(titleSlug)-lyrics/"
        guard let url = URL(string: urlString) else {
            throw SongLyricsError.invalidQuery("Invalid URL: \(urlString)")
        }

        let html = try await fetchHTML(from: url)
        let lyrics = try parseLyrics(from: html, url: urlString)

        return LyricsResult(
            lyrics: lyrics,
            sourceURL: urlString,
            songTitle: title,
            artistName: artist,
            provider: .songLyrics
        )
    }

    // MARK: - Search Fallback

    private func searchAndFetch(artist: String, title: String) async throws -> LyricsResult {
        guard let searchURL = TextMatching.url("https://www.songlyrics.com/index.php", query: [
            ("section", "search"), ("searchW", "\(artist) \(title)"), ("submit", "Search")
        ]) else {
            throw SongLyricsError.invalidQuery("search")
        }

        let html = try await fetchHTML(from: searchURL)
        let doc = try SwiftSoup.parse(html)

        // Score each result by title + artist match instead of trusting the first hit
        var best: (url: String, score: Double)?
        for link in try doc.select("table.tracklist a[href*=\"-lyrics/\"]") {
            let href = try link.attr("href")
            guard !href.isEmpty else { continue }
            let linkTitle = TextMatching.stripBrackets(try link.text())
            let context = try (link.parent()?.parent()?.text() ?? "")
            let titleScore = TextMatching.wordOverlapScore(title, linkTitle)
            // The row text contains more than the artist, so only require the artist name to appear in it
            let artistFound = TextMatching.normalizeForMatching(context)
                .contains(TextMatching.normalizeForMatching(artist))
            guard titleScore >= 0.6, artistFound else { continue }
            if titleScore > (best?.score ?? 0) { best = (href, titleScore) }
        }

        guard let targetURL = best?.url, let url = URL(string: targetURL) else {
            throw SongLyricsError.noResults("No lyrics found for '\(title)' by '\(artist)' on SongLyrics.com")
        }

        let pageHTML = try await fetchHTML(from: url)
        let lyrics = try parseLyrics(from: pageHTML, url: targetURL)

        return LyricsResult(
            lyrics: lyrics,
            sourceURL: targetURL,
            songTitle: title,
            artistName: artist,
            provider: .songLyrics
        )
    }

    // MARK: - HTML Parsing & Fetching

    private func parseLyrics(from html: String, url: String) throws -> String {
        let doc = try SwiftSoup.parse(html)

        for br in try doc.select("br") {
            try br.append("\\n")
        }

        guard let lyricsEl = try doc.select("#songLyricsDiv").first() ?? doc.select(".songLyricsV14").first() else {
            throw SongLyricsError.parseError("Could not find lyrics container on page")
        }

        let rawText = try lyricsEl.text()
        var text = rawText.replacingOccurrences(of: "\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for placeholder strings
        let lower = text.lowercased()
        if lower.contains("we do not have the lyrics for") ||
           lower.contains("sorry, we have no") ||
           lower.contains("submit lyrics") && text.count < 100 {
            throw SongLyricsError.noResults("Song lyrics placeholder found")
        }

        guard !text.isEmpty else {
            throw SongLyricsError.noResults("Empty lyrics found")
        }

        return text
    }

    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SongLyricsError.networkError("HTTP status \(code)")
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SongLyricsError.parseError("Could not decode page content")
        }

        return html
    }

    // MARK: - Utilities

    private func slugify(_ text: String) -> String {
        var s = text.lowercased()
        s = s.folding(options: .diacriticInsensitive, locale: .current)
        s = s.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s
    }
}

// MARK: - Errors

enum SongLyricsError: LocalizedError {
    case invalidQuery(String)
    case noResults(String)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery(let msg): return "Invalid SongLyrics query: \(msg)"
        case .noResults(let msg): return msg
        case .parseError(let msg): return "SongLyrics parse error: \(msg)"
        case .networkError(let msg): return "SongLyrics network error: \(msg)"
        }
    }
}

