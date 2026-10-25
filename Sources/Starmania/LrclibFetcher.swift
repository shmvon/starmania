import Foundation

/// Fetches lyrics from LRCLIB (and optional custom Lyrica server instance).
class LrclibFetcher: @unchecked Sendable {
    static let shared = LrclibFetcher()

    private init() {}

    func fetchLyrics(title: String, artist: String, album: String? = nil, lyricaBaseURL: String = "") async throws -> LyricsResult {
        let cleanTitle = stripBrackets(title)
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

        let queryArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let querySong = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(base)/lyrics/?artist=\(queryArtist)&song=\(querySong)") else {
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

        let lyricsText = (json["lyrics"] as? String) ?? (json["plainLyrics"] as? String) ?? ""
        guard !lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LrclibError.noResults("No lyrics in Lyrica response")
        }

        let formatted = """
        \(artist) - \(title)

        \(lyricsText.trimmingCharacters(in: .whitespacesAndNewlines))

        Lyrics: \(url.absoluteString)
        """

        return LyricsResult(
            lyrics: formatted,
            sourceURL: url.absoluteString,
            songTitle: title,
            artistName: artist,
            provider: .lyrica
        )
    }

    // MARK: - LRCLIB API

    private func fetchFromLrclibGet(title: String, artist: String, album: String?) async throws -> LyricsResult {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if let album = album, !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        comps.queryItems = queryItems

        guard let url = comps.url else { throw LrclibError.invalidURL("lrclib get") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Starmania/2.0 (macOS menu bar player)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LrclibError.noResults("Track not found on LRCLIB")
        }

        return try parseLrclibJSON(data, originalTitle: title, originalArtist: artist)
    }

    private func fetchFromLrclibSearch(title: String, artist: String) async throws -> LyricsResult {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "\(artist) \(title)")
        ]

        guard let url = comps.url else { throw LrclibError.invalidURL("lrclib search") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Starmania/2.0 (macOS menu bar player)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LrclibError.noResults("No search results on LRCLIB")
        }

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else {
            throw LrclibError.noResults("No matching search hits on LRCLIB")
        }

        for item in list {
            if let plain = item["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let songName = (item["trackName"] as? String) ?? title
                let artistName = (item["artistName"] as? String) ?? artist
                let formatted = """
                \(artistName) - \(songName)

                \(plain.trimmingCharacters(in: .whitespacesAndNewlines))

                Lyrics: https://lrclib.net
                """
                return LyricsResult(
                    lyrics: formatted,
                    sourceURL: "https://lrclib.net",
                    songTitle: songName,
                    artistName: artistName,
                    provider: .lrclib
                )
            }
        }

        throw LrclibError.noResults("No plain lyrics available in LRCLIB search items")
    }

    private func parseLrclibJSON(_ data: Data, originalTitle: String, originalArtist: String) throws -> LyricsResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LrclibError.parseError("Invalid JSON from LRCLIB")
        }

        if let instrumental = json["instrumental"] as? Bool, instrumental {
            throw LrclibError.noResults("Track is instrumental")
        }

        var lyricsText = (json["plainLyrics"] as? String) ?? ""
        if lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // If plain lyrics is empty, check synced lyrics and strip timestamps
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                lyricsText = synced.replacingOccurrences(of: "\\[\\d+:\\d+\\.\\d+\\]\\s*", with: "", options: .regularExpression)
            }
        }

        lyricsText = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyricsText.isEmpty else {
            throw LrclibError.noResults("No lyrics found in LRCLIB response")
        }

        let songName = (json["trackName"] as? String) ?? originalTitle
        let artistName = (json["artistName"] as? String) ?? originalArtist

        let formatted = """
        \(artistName) - \(songName)

        \(lyricsText)

        Lyrics: https://lrclib.net
        """

        return LyricsResult(
            lyrics: formatted,
            sourceURL: "https://lrclib.net",
            songTitle: songName,
            artistName: artistName,
            provider: .lrclib
        )
    }

    private func stripBrackets(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "[\\(\\[].*?[\\)\\]]",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
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

