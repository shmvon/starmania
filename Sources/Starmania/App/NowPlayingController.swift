import Foundation
import AppKit
import Combine

/// Owns lyrics/artwork state and actions for the current track, independent of the panel,
/// so auto-fetch, bulk fetch and the quit-time flush work whether or not the panel is open.
@MainActor
final class NowPlayingController: ObservableObject {
    static let shared = NowPlayingController()

    /// Plain lyrics for display and copying (timestamps stripped).
    @Published private(set) var lyrics: String = ""
    /// LRC text when timing is known, else nil.
    @Published private(set) var syncedLyricsText: String?
    @Published private(set) var lyricsSource: LyricsProvider?
    @Published private(set) var syncedLines: [LyricLine] = []
    @Published private(set) var lyricsLoading = false
    @Published private(set) var lyricsError: String?
    @Published private(set) var artworkLoading = false
    /// The artwork shown was fetched and isn't in the file yet.
    @Published private(set) var artworkUnsaved = false
    /// The lyrics shown were fetched and aren't stored yet.
    var lyricsUnsaved: Bool { !lyrics.isEmpty && lyricsSource != .embedded }
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var bulkProgress: String?

    var isBulkRunning: Bool { bulkTask != nil }

    private let music = MusicObserver.shared
    private let settings = SettingsManager.shared
    private let writeQueue = FileWriteQueue()
    private var cancellables = Set<AnyCancellable>()
    private var activeLyricsRequestID = UUID()
    private var statusToken = UUID()
    private var bulkTask: Task<Void, Never>?

    private init() {}

    func start() {
        music.$currentTrack
            .removeDuplicates { $0?.trackKey == $1?.trackKey }
            .sink { [weak self] track in
                self?.onTrackChanged(track)
            }
            .store(in: &cancellables)
    }

    // MARK: - Track Changes

    private func onTrackChanged(_ track: TrackInfo?) {
        // Deferred writes for the previous track can go now that it's no longer playing,
        // after a pause so the file isn't rewritten during the transition (crossfade, gapless)
        Task {
            try? await Task.sleep(for: .seconds(MusicObserver.writeDelayAfterTrackChange))
            await flushPendingWrites(except: protectedPaths(fallback: track))
        }
        artworkUnsaved = false
        SuggestionCenter.shared.withdraw(.lyrics)
        SuggestionCenter.shared.withdraw(.artwork)

        activeLyricsRequestID = UUID()
        lyricsLoading = false
        lyricsError = nil
        clearStatus()
        SuggestionCenter.shared.withdraw(.syncedLyrics)

        guard let track else {
            setLyrics(nil, source: nil)
            return
        }

        if let embedded = normalizedLyrics(track.embeddedLyrics) {
            setLyrics(embedded, source: .embedded)
            if syncedLyricsText == nil {
                checkForSyncedLyrics(track, existing: embedded)
            }
        } else {
            setLyrics(nil, source: nil)
            if settings.settings.missingLyrics != .off {
                startLyricsFetch(for: track)
            }
        }

        if track.artworkData == nil && settings.settings.missingArtwork != .off {
            startArtworkFetch(for: track)
        }
    }

    private func isCurrent(_ track: TrackInfo) -> Bool {
        music.currentTrack?.trackKey == track.trackKey
    }

    /// Show lyrics from any source; LRC text (in a tag or from a provider) becomes synced lines.
    private func setLyrics(_ text: String?, source: LyricsProvider?) {
        let text = text ?? ""
        if LRCParser.isSynced(text) {
            syncedLyricsText = text
            syncedLines = LRCParser.parse(text)
            lyrics = LRCParser.plainText(text)
        } else {
            syncedLyricsText = nil
            syncedLines = []
            lyrics = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lyricsSource = text.isEmpty ? nil : source
    }

    /// What goes into the tag: LRC when timing is known (and the setting allows it), else plain text.
    private func textToStore(plain: String, synced: String?) -> String {
        if settings.settings.storeSyncedLyrics, let synced, LRCParser.isSynced(synced) { return synced }
        return plain
    }

    // MARK: - Lyrics

    func fetchLyrics() {
        guard let track = music.currentTrack else { return }
        startLyricsFetch(for: track)
    }

    private func startLyricsFetch(for track: TrackInfo) {
        let requestID = UUID()
        activeLyricsRequestID = requestID
        lyricsLoading = true
        lyricsError = nil
        let s = settings.settings

        Task {
            do {
                let result = try await LyricsService.shared.fetchLyrics(
                    title: track.name,
                    artist: track.artist,
                    album: track.album,
                    geniusAPIKey: s.geniusAPIKey,
                    lyricaBaseURL: s.lyricaBaseURL,
                    preferredProvider: s.lyricsProvider
                )
                guard activeLyricsRequestID == requestID, isCurrent(track) else { return }
                setLyrics(result.syncedLyrics ?? result.lyrics, source: result.provider)
                lyricsLoading = false
                offerToSaveLyrics(result, for: track)
            } catch {
                guard activeLyricsRequestID == requestID, isCurrent(track) else { return }
                lyricsError = error.localizedDescription
                lyricsLoading = false
            }
        }
    }

    /// Propose (or, in Automate mode, do) storing fetched lyrics: in the file, or in Music for streaming tracks.
    private func offerToSaveLyrics(_ result: LyricsResult, for track: TrackInfo) {
        if let path = track.filePath, MetadataWriter.format(of: path) == nil { return }
        let text = textToStore(plain: result.lyrics, synced: result.syncedLyrics)
        let timed = LRCParser.isSynced(text) ? ", with timing" : ""
        SuggestionCenter.shared.offer(Suggestion(
            id: "lyrics|\(track.trackKey)",
            kind: .lyrics,
            title: track.isLocal ? "Save lyrics to the file" : "Save lyrics in Music",
            detail: "Found on \(result.provider.displayName)\(timed)",
            applyTitle: "Save",
            apply: { NowPlayingController.shared.saveLyrics(text, to: track) }
        ))
    }

    private func saveLyrics(_ text: String, to track: TrackInfo) {
        if isCurrent(track) { lyricsSource = .embedded }
        Task { await writeLyrics(text, to: track) }
    }

    func writeLyricsToFile() {
        guard let track = music.currentTrack, !lyrics.isEmpty else { return }
        let text = textToStore(plain: lyrics, synced: syncedLyricsText)
        SuggestionCenter.shared.withdraw(.lyrics)
        saveLyrics(text, to: track)
    }

    func deleteLyrics() {
        guard let track = music.currentTrack else { return }
        SuggestionCenter.shared.withdraw(.lyrics)
        setLyrics(nil, source: nil)
        Task { await writeLyrics("", to: track) }
    }

    // MARK: - Synced Lyrics Upgrade

    /// The track has plain lyrics: look for a timed version of the same text. It is only offered
    /// when at least 75% of the words agree, so only the timing is added, not different lyrics.
    private func checkForSyncedLyrics(_ track: TrackInfo, existing: String) {
        let s = settings.settings
        guard s.syncedLyricsUpgrade != .off else { return }
        Task {
            guard let result = try? await LrclibFetcher.shared.fetchLyrics(
                title: track.name, artist: track.artist, album: track.album, lyricaBaseURL: s.lyricaBaseURL
            ), let synced = result.syncedLyrics, LRCParser.isSynced(synced), isCurrent(track),
               syncedLyricsText == nil else { return }

            let score = LyricsSimilarity.score(existing, synced)
            guard score >= Self.syncedMatchThreshold else {
                print("[Starmania] Synced lyrics rejected: only \(Int(score * 100))% match")
                return
            }
            SuggestionCenter.shared.offer(Suggestion(
                id: "syncedLyrics|\(track.trackKey)",
                kind: .syncedLyrics,
                title: "Add timing to the lyrics",
                detail: "\(result.provider.displayName) has synced lyrics, \(Int(score * 100))% the same words",
                applyTitle: "Replace",
                apply: { NowPlayingController.shared.applySyncedLyrics(synced, provider: result.provider, to: track) }
            ))
        }
    }

    nonisolated static let syncedMatchThreshold = 0.75

    private func applySyncedLyrics(_ synced: String, provider: LyricsProvider, to track: TrackInfo) {
        if isCurrent(track) { setLyrics(synced, source: provider) }
        Task { await writeLyrics(synced, to: track) }
    }

    /// Local tracks get the lyrics in the file tag; streaming tracks in Music's database.
    private func writeLyrics(_ text: String, to track: TrackInfo) async {
        let deleting = text.isEmpty
        guard let path = track.filePath else {
            music.setLyrics(text, trackID: track.persistentID)
            showStatus(deleting ? "Lyrics deleted ✓" : "Lyrics → Music ✓", isError: deleting)
            return
        }

        if isCurrent(track) {
            music.currentTrack?.embeddedLyrics = deleting ? nil : text
        }
        do {
            let deferred = try await writeOrDefer(path: path, lyrics: text, artwork: nil)
            if deferred {
                showStatus(deleting ? "Lyrics deletion queued ✓" : "Lyrics queued for file write ✓", isError: deleting)
            } else {
                showStatus(deleting ? "Lyrics deleted ✓" : "Lyrics → File ✓", isError: deleting)
            }
        } catch {
            showStatus(deleting ? "Lyrics delete failed" : "Lyrics write failed", isError: true)
        }
    }

    // MARK: - Artwork

    func fetchArtwork() {
        guard let track = music.currentTrack else { return }
        startArtworkFetch(for: track)
    }

    private func startArtworkFetch(for track: TrackInfo) {
        artworkLoading = true

        Task {
            defer { artworkLoading = false }
            do {
                let data = try await ArtworkFetcher.shared.fetchArtwork(artist: track.artist, album: track.album)
                guard isCurrent(track) else { return }
                music.updateArtwork(data)
                artworkUnsaved = true

                if let path = track.filePath, MetadataWriter.format(of: path) != nil,
                   await !MetadataWriter.shared.checkExistingMetadata(filePath: path).hasArtwork, isCurrent(track) {
                    SuggestionCenter.shared.offer(Suggestion(
                        id: "artwork|\(track.trackKey)",
                        kind: .artwork,
                        title: "Save artwork to the file",
                        detail: "Found on the iTunes Store",
                        applyTitle: "Save",
                        apply: { NowPlayingController.shared.saveArtwork(data, to: track) }
                    ))
                }
            } catch {
                guard isCurrent(track) else { return }
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func writeArtworkToFile() {
        guard let track = music.currentTrack, let data = track.artworkData else { return }
        SuggestionCenter.shared.withdraw(.artwork)
        saveArtwork(data, to: track)
    }

    private func saveArtwork(_ data: Data, to track: TrackInfo) {
        if isCurrent(track) { artworkUnsaved = false }
        Task { await writeArtwork(data, to: track) }
    }

    func deleteArtwork() {
        guard let track = music.currentTrack else { return }
        artworkUnsaved = false
        SuggestionCenter.shared.withdraw(.artwork)
        music.deleteArtwork()
        guard track.filePath != nil else {
            showStatus("Artwork deleted ✓", isError: true)
            return
        }
        Task { await writeArtwork(Data(), to: track) }
    }

    private func writeArtwork(_ data: Data, to track: TrackInfo) async {
        guard let path = track.filePath else {
            // No file on this Mac: Music's library is the only place for it
            guard !data.isEmpty else { return }
            if await music.setArtwork(data, trackID: track.persistentID) {
                showStatus("Artwork → Music ✓")
            } else {
                if isCurrent(track) { artworkUnsaved = true }
                showStatus("Music can't add artwork to a song without a file on this Mac", isError: true)
            }
            return
        }
        let deleting = data.isEmpty
        do {
            let deferred = try await writeOrDefer(path: path, lyrics: nil, artwork: data)
            if deferred {
                showStatus(deleting ? "Artwork deletion queued ✓" : "Artwork queued for file write ✓", isError: deleting)
            } else {
                showStatus(deleting ? "Artwork deleted ✓" : "Artwork → File ✓", isError: deleting)
            }
        } catch {
            showStatus("Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - File Writes

    /// Files that mustn't be rewritten now: the playing song's, and the next one's, which Music
    /// has already loaded for gapless playback.
    private func protectedPaths(fallback: TrackInfo? = nil) -> Set<String> {
        let track = music.currentTrack ?? fallback
        return Set([track?.filePath, track?.nextFilePath].compactMap { $0 })
    }

    /// Rewriting the playing (or next) song's file can interrupt playback, so those writes are
    /// queued until neither is playing or up next (or the app quits). Returns true when deferred.
    private func writeOrDefer(path: String, lyrics: String?, artwork: Data?) async throws -> Bool {
        if protectedPaths().contains(path) {
            writeQueue.enqueue(path: path, lyrics: lyrics, artwork: artwork)
            return true
        }
        try await MetadataWriter.shared.writeToFile(filePath: path, lyrics: lyrics, artworkData: artwork)
        return false
    }

    private func flushPendingWrites(except protected: Set<String>) async {
        let failures = await writeQueue.flush(except: protected)
        if failures > 0 {
            showStatus("Deferred file write failed", isError: true)
        }
    }

    /// Write everything still queued, including the playing track. Called on quit.
    func flushAllPendingWrites() async {
        bulkTask?.cancel()
        _ = await writeQueue.flush(except: [])
    }

    // MARK: - Clipboard

    /// Copy plain lyrics, or the timed LRC text when `withTiming` is set (⌥).
    func copyLyrics(withTiming: Bool = false) {
        let text = withTiming ? (syncedLyricsText ?? lyrics) : lyrics
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showStatus(withTiming && syncedLyricsText != nil ? "Synced lyrics copied ✓" : "Lyrics copied ✓")
    }

    func copyArtwork() {
        guard let data = music.currentTrack?.artworkData, let image = NSImage(data: data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        showStatus("Artwork copied ✓")
    }

    // MARK: - Bulk Fetch

    /// Fetch missing lyrics (all tracks) and artwork (local files) for the current album or playlist.
    func startBulkFetch() {
        guard bulkTask == nil else { return }
        bulkProgress = "Scanning tracks..."

        bulkTask = Task {
            defer {
                bulkTask = nil
                bulkProgress = nil
            }
            let tracks = await music.fetchBulkTracks()
            guard !tracks.isEmpty else {
                showStatus("No album or playlist to scan", isError: true)
                return
            }

            // Local files need a writable tag format; streaming tracks go into Music's database
            let needLyrics = tracks.filter { track in
                !track.hasLyrics && (track.filePath.map { MetadataWriter.format(of: $0) != nil } ?? true)
            }
            let needArtwork = tracks.filter { track in
                !track.hasArtwork && track.filePath.map { MetadataWriter.format(of: $0) != nil } == true
            }
            var lyricsWritten = 0
            var artworkWritten = 0
            let s = settings.settings

            for (i, track) in needLyrics.enumerated() {
                if Task.isCancelled { break }
                bulkProgress = "Lyrics \(i + 1)/\(needLyrics.count): \(track.name)"
                guard let result = try? await LyricsService.shared.fetchLyrics(
                    title: track.name, artist: track.artist, album: track.album,
                    geniusAPIKey: s.geniusAPIKey, lyricaBaseURL: s.lyricaBaseURL,
                    preferredProvider: s.lyricsProvider
                ) else { continue }
                let stored = textToStore(plain: result.lyrics, synced: result.syncedLyrics)

                if let path = track.filePath {
                    if (try? await writeOrDefer(path: path, lyrics: stored, artwork: nil)) != nil {
                        lyricsWritten += 1
                    }
                } else {
                    music.setLyrics(stored, trackID: track.persistentID)
                    lyricsWritten += 1
                }
                if track.persistentID == music.currentTrack?.persistentID, lyrics.isEmpty {
                    setLyrics(result.syncedLyrics ?? result.lyrics, source: result.provider)
                }
            }

            // One lookup per album
            var artworkCache: [String: Data?] = [:]
            for (i, track) in needArtwork.enumerated() {
                if Task.isCancelled { break }
                guard let path = track.filePath else { continue }
                bulkProgress = "Artwork \(i + 1)/\(needArtwork.count): \(track.name)"
                let key = "\(track.artist)|\(track.album)"
                if artworkCache[key] == nil {
                    artworkCache[key] = try? await ArtworkFetcher.shared.fetchArtwork(artist: track.artist, album: track.album)
                }
                guard let data = artworkCache[key] ?? nil else { continue }
                if (try? await writeOrDefer(path: path, lyrics: nil, artwork: data)) != nil {
                    artworkWritten += 1
                }
            }

            let prefix = Task.isCancelled ? "Stopped: " : ""
            showStatus("\(prefix)\(lyricsWritten) lyrics, \(artworkWritten) artwork written")
        }
    }

    func cancelBulkFetch() {
        bulkTask?.cancel()
    }

    // MARK: - Status

    func showStatus(_ message: String, isError: Bool = false) {
        let token = UUID()
        statusToken = token
        statusMessage = message
        statusIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusToken == token { statusMessage = nil }
        }
    }

    private func clearStatus() {
        statusToken = UUID()
        statusMessage = nil
        statusIsError = false
    }

    private func normalizedLyrics(_ lyrics: String?) -> String? {
        guard let lyrics else { return nil }
        let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Deferred File Writes

/// Writes queued per file path; later writes to the same field replace earlier ones.
@MainActor
final class FileWriteQueue {
    struct PendingWrite: Equatable {
        var lyrics: String?
        var artwork: Data?
    }

    private(set) var pending: [String: PendingWrite] = [:]

    func enqueue(path: String, lyrics: String?, artwork: Data?) {
        var write = pending[path] ?? PendingWrite()
        if let lyrics { write.lyrics = lyrics }
        if let artwork { write.artwork = artwork }
        pending[path] = write
    }

    /// Write all queued entries except the `protected` paths. Returns the number of failures;
    /// failed entries are dropped so they don't retry forever.
    func flush(except protected: Set<String>) async -> Int {
        let toFlush = pending.filter { !protected.contains($0.key) }
        var failures = 0
        for (path, write) in toFlush {
            pending.removeValue(forKey: path)
            do {
                try await MetadataWriter.shared.writeToFile(filePath: path, lyrics: write.lyrics, artworkData: write.artwork)
            } catch {
                failures += 1
                print("[Starmania] Deferred write failed for \(path): \(error.localizedDescription)")
            }
        }
        return failures
    }
}
