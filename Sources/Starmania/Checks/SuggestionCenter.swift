import Foundation
import Combine

/// A change Starmania proposes for the track or album that's playing.
struct Suggestion: Identifiable {
    enum Kind: String { case syncedLyrics, albumStar, year, genre }

    /// Stable across launches (kind + track or album + proposed value), so a dismissal sticks.
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let applyTitle: String
    let apply: @MainActor () -> Void
}

/// Runs the checks for the current track only — never across the library. Each check's setting
/// decides whether a finding is ignored, offered as a suggestion (the menu bar icon pulses),
/// or applied straight away.
@MainActor
final class SuggestionCenter: ObservableObject {
    static let shared = SuggestionCenter()

    @Published private(set) var suggestions: [Suggestion] = []

    // Album facts for the Album page
    @Published private(set) var albumFacts: AlbumFacts?
    @Published private(set) var albumLookupLoading = false
    @Published private(set) var albumLookupError: String?
    @Published private(set) var albumStats: MusicObserver.AlbumStats?

    private let music = MusicObserver.shared
    private let settings = SettingsManager.shared
    private let dismissed = DismissedStore()
    private var cancellables = Set<AnyCancellable>()
    private var currentAlbumKey = ""
    private var lookupTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    private init() {}

    func start() {
        music.$currentTrack
            .removeDuplicates { $0?.albumKey == $1?.albumKey }
            .sink { [weak self] track in self?.albumChanged(track) }
            .store(in: &cancellables)

        // Re-evaluate when Music's values change (a rating, a write finishing) or a setting changes
        music.$currentTrack
            .removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateAlbumChecks() }
            .store(in: &cancellables)

        music.$writeTick
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAlbumStats() }
            .store(in: &cancellables)

        settings.$settings
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.suggestions.removeAll { !self.isEnabled($0.kind) }
                if self.albumFacts == nil, self.wantsLookup, let track = self.music.currentTrack {
                    self.lookUpAlbum(for: track)
                }
                self.evaluateAlbumChecks()
            }
            .store(in: &cancellables)
    }

    // MARK: - Suggestions

    /// Offer a suggestion: applied right away in Automate mode, listed in Propose mode.
    func offer(_ suggestion: Suggestion) {
        let mode = self.mode(for: suggestion.kind)
        guard mode != .off, !dismissed.contains(suggestion.id) else { return }
        if mode == .automate {
            suggestions.removeAll { $0.kind == suggestion.kind }
            suggestion.apply()
            dismissed.insert(suggestion.id)  // Don't re-apply if the user reverts it
            NowPlayingController.shared.showStatus("\(suggestion.title) ✓")
            return
        }
        suggestions.removeAll { $0.kind == suggestion.kind }
        suggestions.append(suggestion)
    }

    func withdraw(_ kind: Suggestion.Kind) {
        suggestions.removeAll { $0.kind == kind }
    }

    func apply(_ suggestion: Suggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        suggestion.apply()
    }

    func dismiss(_ suggestion: Suggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        dismissed.insert(suggestion.id)
    }

    private func mode(for kind: Suggestion.Kind) -> CheckMode {
        let s = settings.settings
        switch kind {
        case .syncedLyrics: return s.syncedLyricsUpgrade
        case .albumStar: return s.albumStarMode
        case .year: return s.yearCheck
        case .genre: return s.genreCheck
        }
    }

    private func isEnabled(_ kind: Suggestion.Kind) -> Bool { mode(for: kind) != .off }

    private var wantsLookup: Bool {
        settings.settings.yearCheck != .off || settings.settings.genreCheck != .off
    }

    // MARK: - Album

    private func albumChanged(_ track: TrackInfo?) {
        lookupTask?.cancel()
        statsTask?.cancel()
        suggestions.removeAll { $0.kind != .syncedLyrics }
        albumFacts = nil
        albumStats = nil
        albumLookupError = nil
        albumLookupLoading = false
        currentAlbumKey = track?.albumKey ?? ""

        guard let track, !track.album.isEmpty else { return }
        refreshAlbumStats()
        if wantsLookup { lookUpAlbum(for: track) }
    }

    /// Look the current album up on MusicBrainz (automatic when a year/genre check is on).
    func lookUpCurrentAlbum() {
        guard let track = music.currentTrack, !track.album.isEmpty else { return }
        lookUpAlbum(for: track)
    }

    private func lookUpAlbum(for track: TrackInfo) {
        lookupTask?.cancel()
        let albumKey = track.albumKey
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        albumLookupLoading = true
        albumLookupError = nil

        lookupTask = Task {
            do {
                let facts = try await MusicBrainzClient.shared.lookupAlbum(artist: artist, album: track.album)
                guard !Task.isCancelled, albumKey == currentAlbumKey else { return }
                albumFacts = facts
                albumLookupError = facts == nil ? "Not found on MusicBrainz" : nil
            } catch {
                guard !Task.isCancelled, albumKey == currentAlbumKey else { return }
                albumLookupError = error.localizedDescription
            }
            albumLookupLoading = false
            evaluateAlbumChecks()
        }
    }

    private func refreshAlbumStats() {
        guard let track = music.currentTrack, !track.album.isEmpty else { return }
        let albumKey = track.albumKey
        statsTask?.cancel()
        statsTask = Task {
            let stats = await music.fetchAlbumStats(trackID: track.persistentID)
            guard !Task.isCancelled, albumKey == currentAlbumKey else { return }
            albumStats = stats
            evaluateAlbumChecks()
        }
    }

    private func evaluateAlbumChecks() {
        guard let track = music.currentTrack, track.albumKey == currentAlbumKey else { return }
        evaluateAlbumStar(track)
        evaluateYear(track)
        evaluateGenre(track)
    }

    private func evaluateAlbumStar(_ track: TrackInfo) {
        let s = settings.settings
        guard let stats = albumStats else { return }
        let count = stats.qualifying(s.albumStarCriterion, minRating: s.albumStarMinRating)
        // Only ever adds the star; never removes one
        guard !track.albumFavorited, Self.shouldStarAlbum(qualifying: count, threshold: s.albumStarThreshold) else {
            withdraw(.albumStar)
            return
        }
        let trackID = track.persistentID
        let what = s.albumStarCriterion == .rated ? "rated \(s.albumStarMinRating)★ or more" : "favorited"
        offer(Suggestion(
            id: "albumStar|\(track.albumKey)",
            kind: .albumStar,
            title: "Star this album",
            detail: "\(count) of \(stats.trackCount) songs \(what)",
            applyTitle: "Star",
            apply: { MusicObserver.shared.setAlbumFavorited(true, trackID: trackID) }
        ))
    }

    private func evaluateYear(_ track: TrackInfo) {
        guard let year = albumFacts?.year, Self.yearDiffers(music: track.year, reference: year) else {
            withdraw(.year)
            return
        }
        let trackID = track.persistentID
        let current = track.year > 0 ? "\(track.year)" : "none"
        offer(Suggestion(
            id: "year|\(track.albumKey)|\(year)",
            kind: .year,
            title: "Set year to \(year)",
            detail: "Music: \(current) · MusicBrainz: \(year) (original release)",
            applyTitle: "Set",
            apply: { MusicObserver.shared.setAlbumYear(year, trackID: trackID) }
        ))
    }

    private func evaluateGenre(_ track: TrackInfo) {
        guard let genres = albumFacts?.genres, let top = genres.first,
              !GenreMatching.agrees(track.genre, with: genres) else {
            withdraw(.genre)
            return
        }
        let genre = GenreMatching.displayName(top)
        let trackID = track.persistentID
        let current = track.genre.isEmpty ? "none" : track.genre
        offer(Suggestion(
            id: "genre|\(track.albumKey)|\(top.lowercased())",
            kind: .genre,
            title: "Set genre to \(genre)",
            detail: "Music: \(current) · MusicBrainz: \(genres.prefix(3).joined(separator: ", "))",
            applyTitle: "Set",
            apply: { MusicObserver.shared.setAlbumGenre(genre, trackID: trackID) }
        ))
    }

    // MARK: - Rules

    nonisolated static func shouldStarAlbum(qualifying: Int, threshold: Int) -> Bool {
        qualifying >= max(1, threshold)
    }

    nonisolated static func yearDiffers(music: Int, reference: Int) -> Bool {
        reference > 0 && music != reference
    }
}

// MARK: - Dismissed Suggestions

/// Remembers dismissed suggestions in Application Support, so they don't come back.
@MainActor
final class DismissedStore {
    private var ids: Set<String>
    private let url: URL?
    private let limit = 5000

    init(url: URL? = DismissedStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(list)
        } else {
            ids = []
        }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func insert(_ id: String) {
        guard ids.insert(id).inserted else { return }
        if ids.count > limit { ids.remove(ids.first!) }
        if let url, let data = try? JSONEncoder().encode(ids.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Starmania")
            .appendingPathComponent("dismissed.json")
    }
}
