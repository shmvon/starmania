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

enum LyricsProvider: String, Codable {
    case embedded
    case songLyrics
    case lrclib
    case lyrica
    case genius
}

struct LyricsResult {
    let lyrics: String
    let sourceURL: String
    let songTitle: String
    let artistName: String
    let provider: LyricsProvider

    var geniusURL: String { sourceURL }

    init(lyrics: String, sourceURL: String, songTitle: String, artistName: String, provider: LyricsProvider = .genius) {
        self.lyrics = lyrics
        self.sourceURL = sourceURL
        self.songTitle = songTitle
        self.artistName = artistName
        self.provider = provider
    }

    init(lyrics: String, geniusURL: String, songTitle: String, artistName: String) {
        self.lyrics = lyrics
        self.sourceURL = geniusURL
        self.songTitle = songTitle
        self.artistName = artistName
        self.provider = .genius
    }
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

enum LyricsProviderOption: String, Codable, CaseIterable {
    case auto = "auto"
    case genius = "genius"
    case songLyrics = "songLyrics"
    case lrclib = "lrclib"

    var title: String {
        switch self {
        case .auto: return "Auto (SongLyrics → LRCLIB → Genius)"
        case .genius: return "Genius"
        case .songLyrics: return "SongLyrics.com"
        case .lrclib: return "LRCLIB / Lyrica"
        }
    }
}

struct AppSettings: Codable {
    var geniusAPIKey: String
    var autoFetchLyrics: Bool
    var autoFetchArtwork: Bool
    var autoWriteLyrics: Bool    // Auto-write lyrics to file if empty
    var autoWriteArtwork: Bool   // Auto-write artwork to file if empty
    var lyricaBaseURL: String = "" // Optional custom Lyrica server URL, e.g. http://localhost:9999
    var lyricsProvider: LyricsProviderOption = .auto

    init(
        geniusAPIKey: String,
        autoFetchLyrics: Bool,
        autoFetchArtwork: Bool,
        autoWriteLyrics: Bool,
        autoWriteArtwork: Bool,
        lyricaBaseURL: String = "",
        lyricsProvider: LyricsProviderOption = .auto
    ) {
        self.geniusAPIKey = geniusAPIKey
        self.autoFetchLyrics = autoFetchLyrics
        self.autoFetchArtwork = autoFetchArtwork
        self.autoWriteLyrics = autoWriteLyrics
        self.autoWriteArtwork = autoWriteArtwork
        self.lyricaBaseURL = lyricaBaseURL
        self.lyricsProvider = lyricsProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.geniusAPIKey = try container.decodeIfPresent(String.self, forKey: .geniusAPIKey) ?? ""
        self.autoFetchLyrics = try container.decodeIfPresent(Bool.self, forKey: .autoFetchLyrics) ?? false
        self.autoFetchArtwork = try container.decodeIfPresent(Bool.self, forKey: .autoFetchArtwork) ?? false
        self.autoWriteLyrics = try container.decodeIfPresent(Bool.self, forKey: .autoWriteLyrics) ?? false
        self.autoWriteArtwork = try container.decodeIfPresent(Bool.self, forKey: .autoWriteArtwork) ?? false
        self.lyricaBaseURL = try container.decodeIfPresent(String.self, forKey: .lyricaBaseURL) ?? ""
        self.lyricsProvider = try container.decodeIfPresent(LyricsProviderOption.self, forKey: .lyricsProvider) ?? .auto
    }
    
    static let `default` = AppSettings(
        geniusAPIKey: "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5",
        autoFetchLyrics: false,
        autoFetchArtwork: false,
        autoWriteLyrics: false,
        autoWriteArtwork: false,
        lyricaBaseURL: "",
        lyricsProvider: .auto
    )
}
