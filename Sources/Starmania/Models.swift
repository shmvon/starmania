import Foundation

// MARK: - Track Info Model

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    var favorited: Bool
    var disliked: Bool
    var rating: Int  // 0-5 (0 = unrated)
    var filePath: String?  // nil for streaming tracks
    var artworkData: Data?
    var embeddedLyrics: String?  // Lyrics already in the track (from Apple Music)
    var isPlaying: Bool
    
    var isLocal: Bool { filePath != nil }
    
    /// Unique key for detecting track changes (ignoring mutable properties)
    var trackKey: String { "\(name)|\(artist)|\(album)" }
    
    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        return lhs.trackKey == rhs.trackKey &&
               lhs.favorited == rhs.favorited &&
               lhs.disliked == rhs.disliked &&
               lhs.rating == rhs.rating &&
               lhs.isPlaying == rhs.isPlaying
    }
}

// MARK: - Lyrics Result

struct LyricsResult {
    let lyrics: String
    let geniusURL: String
    let songTitle: String
    let artistName: String
}

// MARK: - Playlist Track Info

struct PlaylistTrackInfo: Identifiable {
    let id: Int              // track index in playlist (1-based)
    let name: String
    let artist: String
    var favorited: Bool
    var disliked: Bool
    var rating: Int          // 0-5
    let isCurrentTrack: Bool
}

// MARK: - App Settings

struct AppSettings: Codable {
    var geniusAPIKey: String
    var autoFetchLyrics: Bool
    var autoFetchArtwork: Bool
    var autoWriteLyrics: Bool    // Auto-write lyrics to file if empty
    var autoWriteArtwork: Bool   // Auto-write artwork to file if empty
    
    static let `default` = AppSettings(
        geniusAPIKey: "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5",
        autoFetchLyrics: false,
        autoFetchArtwork: false,
        autoWriteLyrics: false,
        autoWriteArtwork: false
    )
}
