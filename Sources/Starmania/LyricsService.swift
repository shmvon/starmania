import Foundation

/// Coordinates multi-provider lyrics retrieval:
/// 1. Embedded tags (handled in PopoverView / MusicObserver)
/// 2. Configurable providers: LRCLIB / Lyrica, SongLyrics.com, Genius
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

        let actions: [LyricsProvider: () async throws -> LyricsResult] = [
            .genius: fetchGenius,
            .songLyrics: fetchSongLyrics,
            .lrclib: fetchLrclib
        ]
        let providers = Self.providerOrder(for: preferredProvider).map { (name: $0.displayName, action: actions[$0]!) }

        for provider in providers {
            do {
                return try await provider.action()
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        throw LyricsServiceError.allProvidersFailed(errors.joined(separator: "; "))
    }

    /// Order in which providers are tried. The preferred one goes first; "Auto" starts with
    /// LRCLIB because its API returns matched metadata (and synced lyrics), then the scrapers.
    static func providerOrder(for preference: LyricsProviderOption) -> [LyricsProvider] {
        switch preference {
        case .genius: return [.genius, .lrclib, .songLyrics]
        case .songLyrics: return [.songLyrics, .lrclib, .genius]
        case .lrclib, .auto: return [.lrclib, .songLyrics, .genius]
        }
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
