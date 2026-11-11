import Foundation

/// Fetches lyrics from LRCLIB (and optional custom Lyrica server instance).
class LrclibFetcher: @unchecked Sendable {
    static let shared = LrclibFetcher()

    private init() {}

    private let userAgent = "Starmania/3.0 ( https://github.com/shmvon/starmania )"

    func fetchLyrics(title: String, artist: String, album: String? = nil, lyricaBaseURL: String = "") async throws -> LyricsResult {
        let cleanTitle = TextMatching.stripBrackets(title)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        // Attempt Lyrica server if configured
        if !lyricaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let lyricaResult = try? await fetchFromLyrica(baseURL: lyricaBaseURL, title: cleanTitle, artist: cleanArtist) {
                return lyricaResult
            }
        }

        // Direct LRCLIB attempt 1: exact get
        if let directResult = try? await fetchFromLrclibGet(title: cleanTitle, artist: cleanArtist, album: album) {
            return directResult
        }

        // Direct LRCLIB attempt 2: search
        return try await fetchFromLrclibSearch(title: cleanTitle, artist: cleanArtist)
    }

    // MARK: - Lyrica Instance

    private func fetchFromLyrica(baseURL: String, title: String, artist: String) async throws -> LyricsResult {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }

        guard let url = TextMatching.url("\(base)/lyrics/", query: [("artist", artist), ("song", title)]) else {
            throw LrclibError.invalidURL("\(base)/lyrics/")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LrclibError.networkError("Lyrica returned non-200")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LrclibError.parseError("Invalid Lyrica JSON")
        }

        let lyricsText = ((json["lyrics"] as? String) ?? (json["plainLyrics"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyricsText.isEmpty else {
            throw LrclibError.noResults("No lyrics in Lyrica response")
        }

        return LyricsResult(
            lyrics: lyricsText,
            syncedLyrics: nonEmpty(json["syncedLyrics"] as? String),
            sourceURL: url.absoluteString,
            songTitle: title,
            artistName: artist,
            provider: .lyrica
        )
    }

    // MARK: - LRCLIB API

    private func fetchFromLrclibGet(title: String, artist: String, album: String?) async throws -> LyricsResult {
        var query = [("artist_name", artist), ("track_name", title)]
        if let album = album, !album.isEmpty {
            query.append(("album_name", album))
        }

        guard let url = TextMatching.url("https://lrclib.net/api/get", query: query) else {
            throw LrclibError.invalidURL("lrclib get")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LrclibError.noResults("Track not found on LRCLIB")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LrclibError.parseError("Invalid JSON from LRCLIB")
        }
        return try makeResult(from: json, originalTitle: title, originalArtist: artist)
    }

    private func fetchFromLrclibSearch(title: String, artist: String) async throws -> LyricsResult {
        guard let url = TextMatching.url("https://lrclib.net/api/search", query: [("track_name", title), ("artist_name", artist)]) else {
            throw LrclibError.invalidURL("lrclib search")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LrclibError.noResults("No search results on LRCLIB")
        }

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else {
            throw LrclibError.noResults("No matching search hits on LRCLIB")
        }

        // Only accept hits whose artist and title actually match, best match first
        let scored: [(item: [String: Any], score: Double)] = list.compactMap { item in
            let hitArtist = (item["artistName"] as? String) ?? ""
            let hitTitle = TextMatching.stripBrackets((item["trackName"] as? String) ?? "")
            let artistScore = TextMatching.wordOverlapScore(artist, hitArtist)
            let titleScore = TextMatching.wordOverlapScore(title, hitTitle)
            guard artistScore >= 0.5, titleScore >= 0.5 else { return nil }
            return (item, artistScore * 0.45 + titleScore * 0.55)
        }

        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            if let result = try? makeResult(from: candidate.item, originalTitle: title, originalArtist: artist) {
                return result
            }
        }

        throw LrclibError.noResults("No matching lyrics in LRCLIB search results")
    }

    private func makeResult(from json: [String: Any], originalTitle: String, originalArtist: String) throws -> LyricsResult {
        if let instrumental = json["instrumental"] as? Bool, instrumental {
            throw LrclibError.noResults("Track is instrumental")
        }

        let synced = nonEmpty(json["syncedLyrics"] as? String)
        var lyricsText = (json["plainLyrics"] as? String) ?? ""
        if lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let synced {
            // If plain lyrics is empty, derive them from the synced lyrics
            lyricsText = LRCParser.parse(synced).map(\.text).joined(separator: "\n")
        }

        lyricsText = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyricsText.isEmpty else {
            throw LrclibError.noResults("No lyrics found in LRCLIB response")
        }

        let songName = (json["trackName"] as? String) ?? originalTitle
        let artistName = (json["artistName"] as? String) ?? originalArtist
        let sourceURL = (json["id"] as? Int).map { "https://lrclib.net/api/get/\($0)" } ?? "https://lrclib.net"

        return LyricsResult(
            lyrics: lyricsText,
            syncedLyrics: synced,
            sourceURL: sourceURL,
            songTitle: songName,
            artistName: artistName,
            provider: .lrclib
        )
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// MARK: - Errors

enum LrclibError: LocalizedError {
    case invalidURL(String)
    case noResults(String)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let msg): return "Invalid LRCLIB URL: \(msg)"
        case .noResults(let msg): return msg
        case .parseError(let msg): return "LRCLIB parse error: \(msg)"
        case .networkError(let msg): return "LRCLIB network error: \(msg)"
        }
    }
}
