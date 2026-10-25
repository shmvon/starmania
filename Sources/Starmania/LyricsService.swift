import Foundation

/// Coordinates multi-provider lyrics retrieval:
/// 1. Embedded tags (handled in PopoverView / MusicObserver)
/// 2. Configurable providers: Genius, SongLyrics.com, Lyrica / LRCLIB
class LyricsService: @unchecked Sendable {
    static let shared = LyricsService()

    private init() {}

    func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        geniusAPIKey: String = "",
        lyricaBaseURL: String = "",
        preferredProvider: LyricsProviderOption = .auto
    ) async throws -> LyricsResult {
        var errors: [String] = []

        let fetchGenius: () async throws -> LyricsResult = {
            guard !geniusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LyricsServiceError.allProvidersFailed("No Genius API key")
            }
            return try await GeniusFetcher.shared.fetchLyrics(
                title: title,
                artist: artist,
                apiKey: geniusAPIKey
            )
        }

        let fetchSongLyrics: () async throws -> LyricsResult = {
            try await SongLyricsFetcher.shared.fetchLyrics(title: title, artist: artist)
        }

        let fetchLrclib: () async throws -> LyricsResult = {
            try await LrclibFetcher.shared.fetchLyrics(
                title: title,
                artist: artist,
                album: album,
                lyricaBaseURL: lyricaBaseURL
            )
        }

        // Determine execution order based on user preference
        var providers: [(name: String, action: () async throws -> LyricsResult)] = []

        switch preferredProvider {
        case .genius:
            providers = [
                ("Genius", fetchGenius),
                ("SongLyrics", fetchSongLyrics),
                ("LRCLIB", fetchLrclib)
            ]
        case .songLyrics:
            providers = [
                ("SongLyrics", fetchSongLyrics),
                ("LRCLIB", fetchLrclib),
                ("Genius", fetchGenius)
            ]
        case .lrclib:
            providers = [
                ("LRCLIB", fetchLrclib),
                ("SongLyrics", fetchSongLyrics),
                ("Genius", fetchGenius)
            ]
        case .auto:
            providers = [
                ("SongLyrics", fetchSongLyrics),
                ("LRCLIB", fetchLrclib),
                ("Genius", fetchGenius)
            ]
        }

        for provider in providers {
            do {
                return try await provider.action()
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        throw LyricsServiceError.allProvidersFailed(errors.joined(separator: "; "))
    }
}

enum LyricsServiceError: LocalizedError {
    case allProvidersFailed(String)

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let details):
            return "No lyrics found (\(details))"
        }
    }
}
