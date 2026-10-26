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
    var embeddedLyrics: String?  // Lyrics already in the track (from Apple Music)
    var isPlaying: Bool
    var position: Double = 0  // Player position in seconds at `positionDate`
    var positionDate: Date = Date()
    var duration: Double = 0

    var isLocal: Bool { filePath != nil }

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

// MARK: - Synced Lyrics

struct LyricLine: Equatable, Identifiable {
    let id: Int
    let time: Double  // seconds
    let text: String
}

enum LRCParser {
    /// Parse LRC text ("[mm:ss.xx] line") into time-sorted lines. Lines with several
    /// timestamps ("[00:12.00][01:30.00] chorus") are expanded once per timestamp.
    static func parse(_ lrc: String) -> [LyricLine] {
        let stampRegex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]")
        var entries: [(Double, String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = stampRegex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }

        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    static func currentLineIndex(in lines: [LyricLine], at time: Double) -> Int? {
        var result: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= time { result = i } else { break }
        }
        return result
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

enum LyricsProviderOption: String, Codable, CaseIterable {
    case auto = "auto"
    case genius = "genius"
    case songLyrics = "songLyrics"
    case lrclib = "lrclib"

    var title: String {
        switch self {
        case .auto: return "Auto (LRCLIB → SongLyrics → Genius)"
        case .genius: return "Genius"
        case .songLyrics: return "SongLyrics.com"
        case .lrclib: return "LRCLIB / Lyrica"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var geniusAPIKey: String
    var autoFetchLyrics: Bool
    var autoFetchArtwork: Bool
    var autoWriteLyrics: Bool    // Auto-write fetched lyrics to the file
    var autoWriteArtwork: Bool   // Auto-write fetched artwork to the file if it has none
    var lyricaBaseURL: String = "" // Optional custom Lyrica server URL, e.g. http://localhost:9999
    var lyricsProvider: LyricsProviderOption = .auto
    var ratingHotkeysEnabled: Bool = true

    init(
        geniusAPIKey: String,
        autoFetchLyrics: Bool,
        autoFetchArtwork: Bool,
        autoWriteLyrics: Bool,
        autoWriteArtwork: Bool,
        lyricaBaseURL: String = "",
        lyricsProvider: LyricsProviderOption = .auto,
        ratingHotkeysEnabled: Bool = true
    ) {
        self.geniusAPIKey = geniusAPIKey
        self.autoFetchLyrics = autoFetchLyrics
        self.autoFetchArtwork = autoFetchArtwork
        self.autoWriteLyrics = autoWriteLyrics
        self.autoWriteArtwork = autoWriteArtwork
        self.lyricaBaseURL = lyricaBaseURL
        self.lyricsProvider = lyricsProvider
        self.ratingHotkeysEnabled = ratingHotkeysEnabled
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
        self.ratingHotkeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .ratingHotkeysEnabled) ?? true
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
