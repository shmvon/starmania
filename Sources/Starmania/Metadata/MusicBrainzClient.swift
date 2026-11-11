import Foundation

/// What MusicBrainz knows about an album (a "release group": all editions of one album).
struct AlbumFacts: Equatable, Sendable {
    let title: String
    let artist: String
    /// Year of the first release of any edition: the original year, not a remaster's.
    let year: Int?
    /// Community-voted genres, most votes first.
    let genres: [String]
    let url: URL?
}

/// Looks up original release years and genres on MusicBrainz, a free, open music database
/// edited by its users. No key needed; requests are limited to one per second and identify
/// the app in the User-Agent, as MusicBrainz asks.
actor MusicBrainzClient {
    static let shared = MusicBrainzClient()

    private let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        return "Starmania/\(version) ( https://github.com/shmvon/starmania )"
    }()
    private var lastRequest = Date.distantPast
    private var cache: [String: AlbumFacts?] = [:]

    func lookupAlbum(artist: String, album: String) async throws -> AlbumFacts? {
        let key = "\(artist.lowercased())|\(album.lowercased())"
        if let cached = cache[key] { return cached }

        let cleanAlbum = TextMatching.stripBrackets(album)
        let query = "releasegroup:\"\(Self.luceneEscape(cleanAlbum))\" AND artist:\"\(Self.luceneEscape(artist))\""
        guard let searchURL = TextMatching.url("https://musicbrainz.org/ws/2/release-group/", query: [
            ("query", query), ("fmt", "json"), ("limit", "10"),
        ]) else { return nil }

        let search = try await getJSON(searchURL)
        let candidates = (search["release-groups"] as? [[String: Any]] ?? []).compactMap(Self.candidate)
        guard let best = Self.bestMatch(in: candidates, artist: artist, album: album) else {
            cache[key] = .some(nil)
            return nil
        }

        // Search results carry free-form tags; the lookup returns the curated genre list
        var genres = best.genres
        if let lookupURL = URL(string: "https://musicbrainz.org/ws/2/release-group/\(best.id)?inc=genres&fmt=json"),
           let detail = try? await getJSON(lookupURL) {
            genres = Self.rankedNames(detail["genres"])
        }
        if genres.isEmpty, let artistID = best.artistID,
           let artistURL = URL(string: "https://musicbrainz.org/ws/2/artist/\(artistID)?inc=genres&fmt=json"),
           let detail = try? await getJSON(artistURL) {
            genres = Self.rankedNames(detail["genres"])
        }

        let facts = AlbumFacts(
            title: best.title,
            artist: best.artist,
            year: best.year,
            genres: genres,
            url: URL(string: "https://musicbrainz.org/release-group/\(best.id)")
        )
        cache[key] = facts
        return facts
    }

    // MARK: - Matching

    struct Candidate: Equatable {
        let id: String
        let title: String
        let artist: String
        let artistID: String?
        let year: Int?
        let primaryType: String?
        let genres: [String]
    }

    nonisolated static func candidate(_ json: [String: Any]) -> Candidate? {
        guard let id = json["id"] as? String, let title = json["title"] as? String else { return nil }
        let credits = json["artist-credit"] as? [[String: Any]] ?? []
        let artist = credits.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
        let artistID = (credits.first?["artist"] as? [String: Any])?["id"] as? String
        return Candidate(
            id: id,
            title: title,
            artist: artist,
            artistID: artistID,
            year: (json["first-release-date"] as? String).flatMap(MetadataWriter.year(fromDate:)),
            primaryType: json["primary-type"] as? String,
            genres: rankedNames(json["tags"])
        )
    }

    /// Best release group whose artist and title both match; albums beat singles of the same name.
    nonisolated static func bestMatch(in candidates: [Candidate], artist: String, album: String) -> Candidate? {
        let cleanAlbum = TextMatching.stripBrackets(album)
        let scored = candidates.compactMap { c -> (Candidate, Double)? in
            let artistScore = TextMatching.wordOverlapScore(artist, c.artist)
            let titleScore = TextMatching.wordOverlapScore(cleanAlbum, TextMatching.stripBrackets(c.title))
            guard artistScore >= 0.5, titleScore >= 0.6 else { return nil }
            let typeBonus = c.primaryType == "Album" ? 0.05 : 0
            return (c, artistScore * 0.4 + titleScore * 0.6 + typeBonus)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// Names from a MusicBrainz `genres`/`tags` array, most votes first (ties keep their order).
    nonisolated static func rankedNames(_ value: Any?) -> [String] {
        let items = value as? [[String: Any]] ?? []
        return items.enumerated()
            .compactMap { index, item -> (String, Int, Int)? in
                guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                return (name, item["count"] as? Int ?? 0, index)
            }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }

    nonisolated static func luceneEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - HTTP

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        // Reserve the next slot before sleeping: the actor is re-entered while this call waits
        let slot = max(Date(), lastRequest.addingTimeInterval(1.1))
        lastRequest = slot
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MusicBrainzError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicBrainzError.badResponse
        }
        return json
    }
}

enum MusicBrainzError: LocalizedError {
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(503): return "MusicBrainz is busy, try again shortly"
        case .http(let code): return "MusicBrainz returned \(code)"
        case .badResponse: return "Unexpected MusicBrainz response"
        }
    }
}

// MARK: - Genre Helpers

enum GenreMatching {
    /// MusicBrainz genres are lowercase ("singer-songwriter"); Music shows "Singer-Songwriter".
    nonisolated static func displayName(_ genre: String) -> String {
        genre.split(separator: " ", omittingEmptySubsequences: true).map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// The current genre agrees with MusicBrainz when it equals one of the top genres
    /// ("Alt Rock" ≠ "alternative rock", but "Indie Rock" = "indie rock"), ignoring case and punctuation.
    nonisolated static func agrees(_ current: String, with genres: [String], top: Int = 5) -> Bool {
        let normalized = TextMatching.normalizeForMatching(current)
        guard !normalized.isEmpty else { return false }
        return genres.prefix(top).contains { TextMatching.normalizeForMatching($0) == normalized }
    }
}
