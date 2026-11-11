import Foundation

/// Fetches album artwork from the iTunes Search API, checking that the result
/// actually matches the artist and album instead of taking the first hit.
class ArtworkFetcher: @unchecked Sendable {
    static let shared = ArtworkFetcher()

    private init() {}

    struct Candidate: Equatable {
        let artist: String
        let album: String
        let artworkURL: String
    }

    func fetchArtwork(artist: String, album: String) async throws -> Data {
        let cleanAlbum = TextMatching.stripBrackets(album)
        guard let url = TextMatching.url("https://itunes.apple.com/search", query: [
            ("term", "\(artist) \(cleanAlbum)"), ("entity", "album"), ("limit", "15")
        ]) else {
            throw ArtworkError.noResults
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw ArtworkError.noResults
        }

        let candidates = results.compactMap { r -> Candidate? in
            guard let a = r["artistName"] as? String,
                  let c = r["collectionName"] as? String,
                  let art = r["artworkUrl100"] as? String else { return nil }
            return Candidate(artist: a, album: c, artworkURL: art)
        }

        guard let best = Self.bestMatch(in: candidates, artist: artist, album: album),
              let imageURL = URL(string: Self.highResURL(best.artworkURL)) else {
            throw ArtworkError.noResults
        }

        let (imageData, response) = try await URLSession.shared.data(from: imageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !imageData.isEmpty else {
            throw ArtworkError.downloadFailed
        }
        return imageData
    }

    /// Best candidate whose artist and album both match reasonably well, or nil.
    static func bestMatch(in candidates: [Candidate], artist: String, album: String) -> Candidate? {
        let cleanAlbum = TextMatching.stripBrackets(album)
        let scored = candidates.compactMap { c -> (Candidate, Double)? in
            let artistScore = TextMatching.wordOverlapScore(artist, c.artist)
            let albumScore = TextMatching.wordOverlapScore(cleanAlbum, TextMatching.stripBrackets(c.album))
            guard artistScore >= 0.5, albumScore >= 0.5 else { return nil }
            return (c, artistScore * 0.4 + albumScore * 0.6)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// iTunes returns 100x100 thumbnails; the same URL serves larger sizes.
    static func highResURL(_ url: String) -> String {
        url.replacingOccurrences(of: "100x100", with: "600x600")
    }
}

enum ArtworkError: LocalizedError {
    case noResults
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .noResults: return "No matching artwork found"
        case .downloadFailed: return "Artwork download failed"
        }
    }
}
