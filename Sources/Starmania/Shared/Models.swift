import Foundation

// MARK: - Track Info Model

struct TrackInfo: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
    var favorited: Bool
    var disliked: Bool
    var rating: Int  // 0-5 (0 = unrated)
    var filePath: String?  // nil for streaming tracks
    var artworkData: Data?
    var embeddedLyrics: String?  // Lyrics already in the track: the file tag, else Music's copy (may be LRC)
    var isPlaying: Bool
    var position: Double = 0  // Player position in seconds at `positionDate`
    var positionDate: Date = Date()
    var duration: Double = 0
    var albumArtist: String = ""
    var year: Int = 0            // 0 = not set
    var genre: String = ""
    var albumFavorited: Bool = false
    var albumRating: Int = 0     // 0-5
    var albumRatingComputed: Bool = true  // Music derives it from the track ratings
    var fileTags: MetadataWriter.FileTags?  // Read from the file itself (local tracks)
    var nextPersistentID: String = ""      // The song after this one in the current playlist, if known
    var nextFilePath: String?

    var isLocal: Bool { filePath != nil }

    /// Identifies the album across its tracks: album artist (or artist) plus album title.
    var albumKey: String {
        let who = albumArtist.isEmpty ? artist : albumArtist
        return "\(who.lowercased())|\(album.lowercased())"
    }

    /// Unique key for detecting track changes (ignoring mutable properties).
    /// Uses Music's persistent ID so same-named tracks on one album don't collide.
    var trackKey: String {
        persistentID.isEmpty ? "\(name)|\(artist)|\(album)" : persistentID
    }

    /// Estimated playback position, extrapolated from the last poll while playing.
    func estimatedPosition(at date: Date = Date()) -> Double {
        guard isPlaying else { return position }
        let pos = position + date.timeIntervalSince(positionDate)
        return duration > 0 ? min(pos, duration) : pos
    }

    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        return lhs.trackKey == rhs.trackKey &&
               lhs.favorited == rhs.favorited &&
               lhs.disliked == rhs.disliked &&
               lhs.rating == rhs.rating &&
               lhs.isPlaying == rhs.isPlaying &&
               lhs.year == rhs.year &&
               lhs.genre == rhs.genre &&
               lhs.albumFavorited == rhs.albumFavorited &&
               lhs.albumRating == rhs.albumRating &&
               lhs.albumRatingComputed == rhs.albumRatingComputed
    }
}

// MARK: - Lyrics Result

enum LyricsProvider: String, Codable {
    case embedded
    case songLyrics
    case lrclib
    case lyrica
    case genius

    var displayName: String {
        switch self {
        case .embedded: return "Embedded"
        case .songLyrics: return "SongLyrics"
        case .lrclib: return "LRCLIB"
        case .lyrica: return "Lyrica"
        case .genius: return "Genius"
        }
    }
}

struct LyricsResult {
    /// Plain lyrics text only — no header or source footer, so it is safe to write into tags.
    let lyrics: String
    /// Time-stamped LRC lyrics, when the provider has them.
    let syncedLyrics: String?
    let sourceURL: String
    let songTitle: String
    let artistName: String
    let provider: LyricsProvider

    init(lyrics: String, syncedLyrics: String? = nil, sourceURL: String, songTitle: String, artistName: String, provider: LyricsProvider) {
        self.lyrics = lyrics
        self.syncedLyrics = syncedLyrics
        self.sourceURL = sourceURL
        self.songTitle = songTitle
        self.artistName = artistName
        self.provider = provider
    }
}

// MARK: - Playlist Track Info

struct PlaylistTrackInfo: Identifiable, Equatable {
    let id: String           // Music persistent ID
    let name: String
    let artist: String
    var favorited: Bool
    var disliked: Bool
    var rating: Int          // 0-5
    let isCurrentTrack: Bool
}

// MARK: - App Settings

/// How a check that runs while a track plays acts on what it finds.
enum CheckMode: String, Codable, CaseIterable {
    case off, propose, automate

    var title: String {
        switch self {
        case .off: return "Off"
        case .propose: return "Propose"
        case .automate: return "Automate"
        }
    }
}

/// Which songs count towards starring their album automatically.
enum AlbumStarCriterion: String, Codable, CaseIterable {
    case favorited, rated, either

    var title: String {
        switch self {
        case .favorited: return "Favorited songs"
        case .rated: return "Highly rated songs"
        case .either: return "Favorited or highly rated"
        }
    }
}

enum PanelPage: String, Codable, CaseIterable {
    case cover, lyrics, album
}

enum LyricsProviderOption: String, Codable, CaseIterable {
    case auto = "auto"
    case genius = "genius"
    case songLyrics = "songLyrics"
    case lrclib = "lrclib"

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .genius: return "Genius"
        case .songLyrics: return "SongLyrics.com"
        case .lrclib: return "LRCLIB / Lyrica"
        }
    }
}

/// A global keyboard shortcut (Carbon key code and modifier mask).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String   // e.g. "⌃⌥S"
}

struct AppSettings: Codable, Equatable {
    var geniusAPIKey: String
    var lyricaBaseURL: String = "" // Optional custom Lyrica server URL, e.g. http://localhost:9999
    var lyricsProvider: LyricsProviderOption = .auto
    var ratingHotkeysEnabled: Bool = true
    var panelHotkey: KeyCombo?

    // Missing lyrics and artwork: fetched for the playing track, then proposed or saved to the file
    var missingLyrics: CheckMode = .propose
    var missingArtwork: CheckMode = .propose

    // Synced lyrics
    var preferSyncedLyrics: Bool = true       // Show the highlighted view when timing is available
    var storeSyncedLyrics: Bool = true        // Write LRC (with timestamps) into tags, not plain text
    var syncedLyricsUpgrade: CheckMode = .propose

    // Album star
    var albumStarMode: CheckMode = .propose
    var albumStarThreshold: Int = 6           // Songs needed ("more than five")
    var albumStarCriterion: AlbumStarCriterion = .favorited
    var albumStarMinRating: Int = 4           // For the "rated" criterion

    // Year and genre, checked against MusicBrainz
    var yearCheck: CheckMode = .propose
    var genreCheck: CheckMode = .propose

    var panelPage: PanelPage = .cover

    init(geniusAPIKey: String) {
        self.geniusAPIKey = geniusAPIKey
    }

    /// Settings from 2.x used on/off toggles for fetching and writing lyrics and artwork.
    private enum LegacyKeys: String, CodingKey {
        case autoWriteLyrics, autoWriteArtwork
    }

    /// Every key is optional, so configs from older versions load with defaults for new settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = AppSettings.default
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        func legacyMode(_ key: LegacyKeys) -> CheckMode {
            ((try? legacy.decodeIfPresent(Bool.self, forKey: key)) ?? false) ? .automate : .propose
        }
        self.geniusAPIKey = value(.geniusAPIKey, "")
        self.lyricaBaseURL = value(.lyricaBaseURL, "")
        self.lyricsProvider = value(.lyricsProvider, LyricsProviderOption.auto)
        self.ratingHotkeysEnabled = value(.ratingHotkeysEnabled, true)
        self.panelHotkey = value(.panelHotkey, nil as KeyCombo?)
        self.missingLyrics = value(.missingLyrics, legacyMode(.autoWriteLyrics))
        self.missingArtwork = value(.missingArtwork, legacyMode(.autoWriteArtwork))
        self.preferSyncedLyrics = value(.preferSyncedLyrics, d.preferSyncedLyrics)
        self.storeSyncedLyrics = value(.storeSyncedLyrics, d.storeSyncedLyrics)
        self.syncedLyricsUpgrade = value(.syncedLyricsUpgrade, d.syncedLyricsUpgrade)
        self.albumStarMode = value(.albumStarMode, d.albumStarMode)
        self.albumStarThreshold = max(1, value(.albumStarThreshold, d.albumStarThreshold))
        self.albumStarCriterion = value(.albumStarCriterion, d.albumStarCriterion)
        self.albumStarMinRating = min(5, max(1, value(.albumStarMinRating, d.albumStarMinRating)))
        self.yearCheck = value(.yearCheck, d.yearCheck)
        self.genreCheck = value(.genreCheck, d.genreCheck)
        self.panelPage = value(.panelPage, d.panelPage)
    }

    static let `default` = AppSettings(
        geniusAPIKey: "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5"
    )
}
