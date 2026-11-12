import Foundation
import AppKit

/// Bridges Apple Music via AppleScript. Listens for Music's player notifications and
/// polls as a fallback. All AppleScript runs off the main thread via `AppleScriptRunner`.
@MainActor
class MusicObserver: ObservableObject {
    static let shared = MusicObserver()

    @Published var currentTrack: TrackInfo?
    @Published var musicRunning: Bool = false
    @Published var errorMessage: String?
    /// Bumped after every write to Music finishes, so album counts can be refreshed.
    @Published private(set) var writeTick = 0

    private let runner = AppleScriptRunner.shared
    private var pollTimer: Timer?
    private var playerInfoObserver: NSObjectProtocol?
    private var lastTrackKey: String = ""
    private var pollInFlight = false
    private var pollQueued = false
    /// Bumped on every local edit, so a poll that started before the edit doesn't overwrite it.
    private var editGeneration = 0
    /// Year/genre edits for the playing song and the one after it. Music rewrites a song's file
    /// when these change, which interrupts the playing song — or, for the next song, which Music
    /// has already loaded for gapless playback, stops playback at the transition. So they wait
    /// until neither is playing or up next.
    @Published private(set) var pendingEdits: [String: PendingEdit] = [:]

    struct PendingEdit: Equatable {
        var year: Int?
        var genre: String?

        var isEmpty: Bool { year == nil && genre == nil }

        var scriptBody: String {
            var lines: [String] = []
            if let year { lines.append("if year of t is not \(year) then set year of t to \(year)") }
            if let genre {
                let g = MusicObserver.escapeForAppleScript(genre)
                lines.append("if genre of t is not \"\(g)\" then set genre of t to \"\(g)\"")
            }
            // AppleScript ignores case by default, so "rock" → "Rock" would look unchanged
            guard !lines.isEmpty else { return "" }
            return "considering case\n" + lines.joined(separator: "\n") + "\nend considering"
        }
    }

    /// Seconds after a song starts before files of other songs are written (crossfade, gapless).
    nonisolated static let writeDelayAfterTrackChange: Double = 4

    /// Fallback poll interval; track changes arrive instantly via the player notification.
    private let pollInterval: TimeInterval = 4.0

    private init() {}

    func startPolling() {
        requestPoll()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in
                MusicObserver.shared.requestPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Music posts this on every play/pause/track change
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MusicObserver.shared.requestPoll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            playerInfoObserver = nil
        }
    }

    // MARK: - Polling

    /// Coalesces poll requests: at most one poll runs at a time, plus one queued.
    func requestPoll() {
        if pollInFlight {
            pollQueued = true
            return
        }
        pollInFlight = true
        Task {
            await poll()
            pollInFlight = false
            if pollQueued {
                pollQueued = false
                requestPoll()
            }
        }
    }

    private func poll() async {
        // Check if Music.app is running (talking to it would launch it otherwise)
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Music"
        }

        if !running {
            musicRunning = false
            currentTrack = nil
            lastTrackKey = ""
            errorMessage = nil
            return
        }

        musicRunning = true
        let generation = editGeneration

        guard let output = await runner.run(Self.pollScript, cache: true) else {
            errorMessage = "Could not read track info"
            return
        }

        guard let polled = Self.parsePollOutput(output) else {
            if output.hasPrefix("ERROR") {
                errorMessage = "Could not read track info"
            } else {
                // Stopped or not playing: nothing is playing or preloaded, so waiting edits can go now
                if !pendingEdits.isEmpty { Task { await flushPendingEdits() } }
                currentTrack = nil
                lastTrackKey = ""
                errorMessage = nil
            }
            return
        }

        let trackChanged = (polled.trackKey != lastTrackKey)

        // Get artwork and embedded lyrics only when the track changed
        var artworkData = currentTrack?.artworkData
        var embeddedLyrics = currentTrack?.embeddedLyrics
        var fileTags = currentTrack?.fileTags
        if trackChanged {
            artworkData = await runner.runData(Self.trackScript(polled.persistentID, "return raw data of artwork 1 of t"))
            // The file's own tag is the source of truth; Music's copy is the fallback
            fileTags = nil
            if let path = polled.filePath {
                fileTags = await MetadataWriter.shared.readTags(filePath: path)
            }
            embeddedLyrics = fileTags?.lyrics
            if embeddedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                embeddedLyrics = await fetchEmbeddedLyrics(persistentID: polled.persistentID)
            }
        }

        var track = polled
        track.artworkData = artworkData
        track.embeddedLyrics = embeddedLyrics
        track.fileTags = fileTags

        // Edits waiting for this track to stop playing: show them already
        if let pending = pendingEdits[track.persistentID] {
            if let year = pending.year { track.year = year }
            if let genre = pending.genre { track.genre = genre }
        }

        // A local edit happened while this poll was in flight: keep the optimistic values
        if generation != editGeneration, !trackChanged, let current = currentTrack {
            track.favorited = current.favorited
            track.disliked = current.disliked
            track.rating = current.rating
            track.albumFavorited = current.albumFavorited
            track.albumRating = current.albumRating
            track.albumRatingComputed = current.albumRatingComputed
            track.year = current.year
            track.genre = current.genre
        }

        if trackChanged { schedulePendingEdits(except: [track.persistentID, track.nextPersistentID]) }
        lastTrackKey = track.trackKey
        self.currentTrack = track
        self.errorMessage = nil
    }

    nonisolated private static let US = "\u{1F}"  // Field separator
    nonisolated private static let RS = "\u{1E}"  // Record separator

    nonisolated static let pollScript = """
    tell application "Music"
        try
            set US to character id 31
            set pState to player state as string
            if pState is not "playing" and pState is not "paused" then return pState
            set t to current track
            set loc to ""
            try
                set loc to POSIX path of (location of t as text)
            end try
            set pos to 0
            try
                set pos to player position
            end try
            set dur to 0
            try
                set dur to duration of t
            end try
            set aa to ""
            try
                set aa to album artist of t
            end try
            set yr to 0
            try
                set yr to year of t
            end try
            set gn to ""
            try
                set gn to genre of t
            end try
            set aFav to false
            try
                set aFav to album favorited of t
            end try
            set aRat to 0
            set aKind to "computed"
            try
                set aRat to album rating of t
                set aKind to album rating kind of t as string
            end try
            set nPID to ""
            set nLoc to ""
            try
                set cpl to current playlist
                set ci to index of t
                if persistent ID of track ci of cpl is (persistent ID of t) then
                    set nt to track (ci + 1) of cpl
                    set nPID to persistent ID of nt
                    try
                        set nLoc to POSIX path of (location of nt as text)
                    end try
                end if
            end try
            return pState & US & (persistent ID of t) & US & (name of t) & US & (artist of t) & US & (album of t) & US & (favorited of t as string) & US & (disliked of t as string) & US & (rating of t as string) & US & loc & US & (pos as string) & US & (dur as string) & US & aa & US & (yr as string) & US & gn & US & (aFav as string) & US & (aRat as string) & US & aKind & US & nPID & US & nLoc
        on error errMsg
            return "ERROR" & errMsg
        end try
    end tell
    """

    /// Parse the poll script's output. Returns nil when nothing is playing or on error.
    nonisolated static func parsePollOutput(_ output: String) -> TrackInfo? {
        let parts = output.components(separatedBy: US)
        guard parts.count >= 11, parts[0] == "playing" || parts[0] == "paused" else { return nil }

        let rawRating = Int(parts[7]) ?? 0
        var track = TrackInfo(
            persistentID: parts[1],
            name: parts[2],
            artist: parts[3],
            album: parts[4],
            favorited: parts[5].lowercased() == "true",
            disliked: parts[6].lowercased() == "true",
            rating: rawRating / 20,  // Apple Music rating is 0-100
            filePath: parts[8].isEmpty ? nil : parts[8],
            artworkData: nil,
            embeddedLyrics: nil,
            isPlaying: parts[0] == "playing",
            position: parseNumber(parts[9]),
            positionDate: Date(),
            duration: parseNumber(parts[10])
        )
        if parts.count >= 17 {
            track.albumArtist = parts[11]
            track.year = Int(parts[12]) ?? 0
            track.genre = parts[13]
            track.albumFavorited = parts[14].lowercased() == "true"
            track.albumRating = (Int(parts[15]) ?? 0) / 20
            track.albumRatingComputed = parts[16] != "user"
        }
        if parts.count >= 19 {
            track.nextPersistentID = parts[17]
            track.nextFilePath = parts[18].isEmpty ? nil : parts[18]
        }
        return track
    }

    nonisolated private static func parseNumber(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func fetchEmbeddedLyrics(persistentID: String) async -> String? {
        let result = await runner.run(Self.trackScript(persistentID, """
            set lyr to lyrics of t
            if lyr is missing value then return ""
            return lyr
            """))
        guard let lyrics = result, !lyrics.isEmpty else { return nil }
        return lyrics
    }

    // MARK: - Track-addressed Scripts

    /// Build a script that resolves the track with `persistentID` as `t` and runs `body`.
    /// Looks in the current playlist first (so `play t` keeps the playlist context), then the library.
    nonisolated static func trackScript(_ persistentID: String, _ body: String) -> String {
        let pid = persistentID.filter { $0.isHexDigit }  // Persistent IDs are hex; prevents script injection
        return """
        tell application "Music"
            try
                set matches to {}
                try
                    set matches to (every track of current playlist whose persistent ID is "\(pid)")
                end try
                if matches is {} then
                    set matches to (every track of library playlist 1 whose persistent ID is "\(pid)")
                end if
                if matches is {} then return ""
                set t to item 1 of matches
                \(body)
            on error errMsg
                return ""
            end try
        end tell
        """
    }

    nonisolated static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run a write script, then re-poll so the UI reflects what Music actually stored.
    private func runWrite(_ script: String, repollAfter delay: Double = 0) {
        editGeneration += 1
        Task {
            _ = await runner.run(script)
            writeTick += 1
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            requestPoll()
        }
    }

    private func resolvedID(_ trackID: String?) -> String? {
        trackID ?? currentTrack?.persistentID
    }

    private func isCurrent(_ trackID: String?) -> Bool {
        trackID == nil || trackID == currentTrack?.persistentID
    }

    // MARK: - Update Artwork from External Fetch

    func updateArtwork(_ data: Data) {
        currentTrack?.artworkData = data
    }

    // MARK: - Write Back to Apple Music

    /// Set favorited for the given track (nil = current track).
    func setFavorited(_ value: Bool, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        if isCurrent(trackID) {
            currentTrack?.favorited = value
            if value { currentTrack?.disliked = false }
        }
        runWrite(Self.trackScript(pid, "set favorited of t to \(value)"))
    }

    /// Set disliked for the given track (nil = current track).
    func setDisliked(_ value: Bool, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        if isCurrent(trackID) {
            currentTrack?.disliked = value
            if value { currentTrack?.favorited = false }
        }
        runWrite(Self.trackScript(pid, "set disliked of t to \(value)"))
    }

    /// Set the star rating (0-5) for the given track (nil = current track).
    func setRating(_ stars: Int, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        let stars = max(0, min(5, stars))
        if isCurrent(trackID) {
            currentTrack?.rating = stars
        }
        // Apple Music rating is 0-100, where each star = 20
        runWrite(Self.trackScript(pid, "set rating of t to \(stars * 20)"))
    }

    /// Store lyrics in Music's own database (used for streaming tracks).
    func setLyrics(_ lyrics: String, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        if isCurrent(trackID) {
            currentTrack?.embeddedLyrics = lyrics.isEmpty ? nil : lyrics
        }
        runWrite(Self.trackScript(pid, "set lyrics of t to \"\(Self.escapeForAppleScript(lyrics))\""))
    }

    /// Star (favorite) the album of the given track; Music stores this per album.
    func setAlbumFavorited(_ value: Bool, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        if isCurrent(trackID) { currentTrack?.albumFavorited = value }
        runWrite(Self.trackScript(pid, "set album favorited of t to \(value)"))
    }

    /// Set the album rating (0 = let Music compute it from the track ratings).
    func setAlbumRating(_ stars: Int, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        let stars = max(0, min(5, stars))
        if isCurrent(trackID) {
            currentTrack?.albumRating = stars
            currentTrack?.albumRatingComputed = stars == 0
        }
        runWrite(Self.trackScript(pid, "set album rating of t to \(stars * 20)"))
    }

    /// Set the year on every track of the album. Music writes it into each local file's tags,
    /// so tracks that already have it are skipped and the playing track waits (see `pendingEdits`).
    func setAlbumYear(_ year: Int, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        let year = max(0, year)
        if isCurrent(trackID) { currentTrack?.year = year }
        editAlbum(of: pid, property: "year", value: "\(year)", pending: { $0.year = year }, clear: { $0.year = nil })
    }

    /// Set the genre on every track of the album (same deferral as the year).
    func setAlbumGenre(_ genre: String, trackID: String? = nil) {
        guard let pid = resolvedID(trackID) else { return }
        if isCurrent(trackID) { currentTrack?.genre = genre }
        editAlbum(of: pid, property: "genre", value: "\"\(Self.escapeForAppleScript(genre))\"",
                  pending: { $0.genre = genre }, clear: { $0.genre = nil })
    }

    private func editAlbum(of pid: String, property: String, value: String,
                           pending: @escaping (inout PendingEdit) -> Void,
                           clear: @escaping (inout PendingEdit) -> Void) {
        let protected = [currentTrack?.persistentID ?? "", currentTrack?.nextPersistentID ?? ""].filter { !$0.isEmpty }
        let script = Self.trackScript(pid, Self.albumTracksBody(property: property, value: value, skipping: protected))
        editGeneration += 1
        Task {
            // The script returns the album tracks it skipped; they get the edit later
            let output = await runner.run(script) ?? ""
            let skipped = Self.parseSkipped(output)
            for pid in skipped {
                pending(&pendingEdits[pid, default: PendingEdit()])
            }
            // A protected track that already has the new value mustn't get an older waiting one
            for pid in protected where output.hasPrefix("ok") && !skipped.contains(pid) {
                guard var edit = pendingEdits[pid] else { continue }
                clear(&edit)
                pendingEdits[pid] = edit.isEmpty ? nil : edit
            }
            writeTick += 1
            requestPoll()
        }
    }

    nonisolated static func parseSkipped(_ output: String) -> [String] {
        let parts = output.components(separatedBy: US)
        guard parts.count == 2, parts[0] == "ok" else { return [] }
        return parts[1].components(separatedBy: RS).filter { !$0.isEmpty }
    }

    /// Script body (inside `trackScript`) that sets `property` to `value` on each track of
    /// `t`'s album that doesn't have it yet, except the tracks in `skipping`. Returns
    /// "ok" US followed by the skipped album tracks that still need the edit (RS-separated).
    nonisolated static func albumTracksBody(property: String, value: String, skipping: [String]) -> String {
        let skip = skipping.map { "\"" + $0.filter { $0.isHexDigit } + "\"" }.joined(separator: ", ")
        return """
        \(albumSpecBody)
                set US to character id 31
                set RS to character id 30
                set ts to contents of spec
                if ts is {} then set ts to {t}
                set skipList to {\(skip)}
                set skipped to {}
                repeat with x in ts
                    try
                        considering case
                            set differs to (\(property) of x is not \(value))
                        end considering
                        if differs then
                            set xPID to persistent ID of x
                            if skipList contains xPID then
                                set end of skipped to xPID
                            else
                                set \(property) of x to \(value)
                            end if
                        end if
                    end try
                end repeat
                set AppleScript's text item delimiters to RS
                return "ok" & US & (skipped as text)
        """
    }

    /// Apply the edits waiting for tracks that are no longer playing, a few seconds after the
    /// new song started, so Music isn't rewriting files during the transition.
    private func schedulePendingEdits(except protected: [String]) {
        let ready = pendingEdits.filter { !protected.contains($0.key) }
        guard !ready.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(Self.writeDelayAfterTrackChange))
            let nowProtected = [currentTrack?.persistentID, currentTrack?.nextPersistentID]
            for (pid, edit) in ready where !nowProtected.contains(pid) {
                guard pendingEdits[pid] == edit else { continue }  // Changed meanwhile; next change applies it
                pendingEdits.removeValue(forKey: pid)
                _ = await runner.run(Self.trackScript(pid, edit.scriptBody))
            }
        }
    }

    /// Apply every waiting edit, even for the playing track. Called on quit.
    func flushPendingEdits() async {
        let all = pendingEdits
        pendingEdits.removeAll()
        for (pid, edit) in all {
            _ = await runner.run(Self.trackScript(pid, edit.scriptBody))
        }
    }

    /// Resolves `spec`, the library tracks on the same album (same album artist, or artist) as `t`.
    nonisolated private static let albumSpecBody = """
                set al to album of t
                set aa to ""
                try
                    set aa to album artist of t
                end try
                if aa is "" then set aa to artist of t
                set spec to a reference to (every track of library playlist 1 whose album is al and (album artist is aa or artist is aa))
        """

    // MARK: - Album Counts

    struct AlbumStats: Equatable {
        let trackCount: Int
        let favoritedCount: Int
        let ratings: [Int]     // 0-5 per track
        let favorited: [Bool]

        func qualifying(_ criterion: AlbumStarCriterion, minRating: Int) -> Int {
            zip(favorited, ratings).filter { fav, rating in
                switch criterion {
                case .favorited: return fav
                case .rated: return rating >= minRating
                case .either: return fav || rating >= minRating
                }
            }.count
        }
    }

    nonisolated static func albumStatsScript(_ persistentID: String) -> String {
        trackScript(persistentID, """
            set US to character id 31
            set RS to character id 30
            \(albumSpecBody)
                    set AppleScript's text item delimiters to RS
                    return "ok" & US & ((favorited of spec) as text) & US & ((rating of spec) as text)
            """)
    }

    /// Favorites and ratings of every library track on the album of the given track.
    func fetchAlbumStats(trackID: String) async -> AlbumStats? {
        guard let output = await runner.run(Self.albumStatsScript(trackID), cache: false) else { return nil }
        return Self.parseAlbumStats(output)
    }

    nonisolated static func parseAlbumStats(_ output: String) -> AlbumStats? {
        let parts = output.components(separatedBy: US)
        guard parts.count >= 3, parts[0] == "ok" else { return nil }
        let favs = parts[1].isEmpty ? [] : parts[1].components(separatedBy: RS).map { $0.lowercased() == "true" }
        let ratings = parts[2].isEmpty ? [] : parts[2].components(separatedBy: RS).map { (Int($0) ?? 0) / 20 }
        guard favs.count == ratings.count else { return nil }
        return AlbumStats(trackCount: favs.count, favoritedCount: favs.filter { $0 }.count, ratings: ratings, favorited: favs)
    }

    func deleteArtwork() {
        guard let pid = currentTrack?.persistentID else { return }
        currentTrack?.artworkData = nil
        runWrite(Self.trackScript(pid, "delete artworks of t"))
    }

    // MARK: - Playback Controls

    func play() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        runWrite("""
        tell application "Music"
            try
                set stateBeforePlay to player state
                if stateBeforePlay is paused then
                    playpause
                else if stateBeforePlay is stopped then
                    set playedSelectedTrack to false
                    try
                        set selectedTracks to selection
                        if (count of selectedTracks) > 0 then
                            play (item 1 of selectedTracks)
                            set playedSelectedTrack to true
                        end if
                    end try
                    if playedSelectedTrack is false then
                        playpause
                    end if
                else
                    play
                end if
            on error
                try
                    playpause
                end try
            end try
        end tell
        """, repollAfter: 0.3)
    }

    func playPause() {
        currentTrack?.isPlaying.toggle()
        runWrite("tell application \"Music\" to playpause", repollAfter: 0.2)
    }

    /// Jump to a position in the playing song (seconds).
    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTrack?.position = target
        currentTrack?.positionDate = Date()
        runWrite("tell application \"Music\" to set player position to \(String(format: "%.2f", target))", repollAfter: 0.3)
    }

    func nextTrack() {
        runWrite("tell application \"Music\" to next track", repollAfter: 0.3)
    }

    func previousTrack() {
        runWrite("tell application \"Music\" to previous track", repollAfter: 0.3)
    }

    /// Play a specific track (by persistent ID) within the current playlist.
    func playTrack(id: String) {
        runWrite(Self.trackScript(id, "play t"), repollAfter: 0.3)
    }

    // MARK: - Playlist / Album Track List

    /// AppleScript prefix that resolves `mode` ("album" or "playlist") and `spec`, a reference
    /// to up to `window` tracks around the current one. Album mode applies when playing from
    /// the library, where "current playlist" is the whole library.
    nonisolated private static func sourceScript(window: Int, body: String) -> String {
        """
        tell application "Music"
            try
                set US to character id 31
                set RS to character id 30
                set ct to current track
                set ctPID to persistent ID of ct
                set isLib to false
                try
                    set k to special kind of current playlist as string
                    if k is "Library" or k is "Music" then set isLib to true
                end try
                if not isLib then
                    try
                        if name of current playlist is in {"Music", "Library", "Muziek", "Bibliotheek", "Musique", "Bibliothèque", "Musik", "Mediathek", "Música", "Biblioteca"} then set isLib to true
                    end try
                end if
                set ctAlbum to album of ct
                if isLib and ctAlbum is not "" then
                    set mode to "album"
                    set aa to ""
                    try
                        set aa to album artist of ct
                    end try
                    if aa is "" then set aa to artist of ct
                    set spec to a reference to (every track of current playlist whose album is ctAlbum and (album artist is aa or artist is aa))
                else
                    set mode to "playlist"
                    set src to current playlist
                    set total to count of tracks of src
                    if total is 0 then return "ERROR empty"
                    set idx to 0
                    try
                        set i0 to index of ct
                        if persistent ID of track i0 of src is ctPID then set idx to i0
                    end try
                    if idx is 0 and total ≤ 5000 then
                        set allPIDs to persistent ID of every track of src
                        repeat with i from 1 to count of allPIDs
                            if item i of allPIDs is ctPID then
                                set idx to i
                                exit repeat
                            end if
                        end repeat
                    end if
                    if idx is 0 then set idx to 1
                    set s to idx - \(window / 2)
                    if s < 1 then set s to 1
                    set e to s + \(window - 1)
                    if e > total then
                        set e to total
                        set s to e - \(window - 1)
                        if s < 1 then set s to 1
                    end if
                    set spec to a reference to (tracks s thru e of src)
                end if
                set AppleScript's text item delimiters to RS
                \(body)
            on error errMsg
                return "ERROR" & errMsg
            end try
        end tell
        """
    }

    nonisolated static let playlistScript = sourceScript(window: 40, body: """
        return mode & US & ctPID & US & ((persistent ID of spec) as text) & US & ((name of spec) as text) & US & ((artist of spec) as text) & US & ((favorited of spec) as text) & US & ((disliked of spec) as text) & US & ((rating of spec) as text) & US & ((disc number of spec) as text) & US & ((track number of spec) as text)
        """)

    /// Fetch up to 40 tracks from the current playlist/album, centered on the current track.
    /// `isAlbum` is true when playing from the library, so the list is the current album.
    func fetchPlaylistTracks() async -> (isAlbum: Bool, tracks: [PlaylistTrackInfo]) {
        guard let output = await runner.run(Self.playlistScript, cache: true) else { return (false, []) }
        let tracks = Self.parsePlaylistOutput(output)
        if tracks.isEmpty {
            print("[Starmania] Could not load playlist: \(output.prefix(200))")
        }
        return (output.hasPrefix("album"), tracks)
    }

    nonisolated static func parsePlaylistOutput(_ output: String, window: Int = 40) -> [PlaylistTrackInfo] {
        let parts = output.components(separatedBy: US)
        guard parts.count >= 10, parts[0] == "album" || parts[0] == "playlist" else { return [] }

        let currentID = parts[1]
        let lists = parts[2...].map { $0.components(separatedBy: RS) }
        let (ids, names, artists, favs, dislikes, ratings, discs, numbers) =
            (lists[0], lists[1], lists[2], lists[3], lists[4], lists[5], lists[6], lists[7])
        let count = ids.count
        guard count > 0, [names, artists, favs, dislikes, ratings].allSatisfy({ $0.count == count }) else { return [] }

        var rows: [(track: PlaylistTrackInfo, disc: Int, number: Int)] = (0..<count).map { i in
            let track = PlaylistTrackInfo(
                id: ids[i],
                name: names[i],
                artist: artists[i],
                favorited: favs[i].lowercased() == "true",
                disliked: dislikes[i].lowercased() == "true",
                rating: (Int(ratings[i]) ?? 0) / 20,
                isCurrentTrack: ids[i] == currentID
            )
            let disc = discs.count == count ? Int(discs[i]) ?? 0 : 0
            let number = numbers.count == count ? Int(numbers[i]) ?? 0 : 0
            return (track, disc, number)
        }

        guard parts[0] == "album" else { return rows.map(\.track) }

        // Albums: sort by disc/track number and window around the current track
        rows.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        let tracks = rows.map(\.track)
        guard tracks.count > window else { return tracks }
        let currentIndex = tracks.firstIndex(where: \.isCurrentTrack) ?? 0
        var start = max(0, currentIndex - window / 2)
        let end = min(tracks.count, start + window)
        start = max(0, end - window)
        return Array(tracks[start..<end])
    }

    // MARK: - Bulk Candidates

    struct BulkTrack: Equatable {
        let persistentID: String
        let name: String
        let artist: String
        let album: String
        let filePath: String?
        let hasLyrics: Bool
        let hasArtwork: Bool
    }

    nonisolated static let bulkScript = sourceScript(window: 200, body: """
        set out to {}
        set trackList to contents of spec
        repeat with t in trackList
            try
                set loc to ""
                try
                    set loc to POSIX path of (location of t as text)
                end try
                set hasLyr to "false"
                try
                    set lyr to lyrics of t
                    if lyr is not missing value and lyr is not "" then set hasLyr to "true"
                end try
                set artCount to 0
                try
                    set artCount to count of artworks of t
                end try
                set end of out to (persistent ID of t) & US & (name of t) & US & (artist of t) & US & (album of t) & US & loc & US & hasLyr & US & (artCount as string)
            end try
        end repeat
        return mode & RS & (out as text)
        """)

    /// Tracks of the current album (or up to 200 of the current playlist) with what they're missing.
    func fetchBulkTracks() async -> [BulkTrack] {
        guard let output = await runner.run(Self.bulkScript, cache: true) else { return [] }
        return Self.parseBulkOutput(output)
    }

    nonisolated static func parseBulkOutput(_ output: String) -> [BulkTrack] {
        let records = output.components(separatedBy: RS)
        guard let mode = records.first, mode == "album" || mode == "playlist" else { return [] }
        return records.dropFirst().compactMap { record in
            let f = record.components(separatedBy: US)
            guard f.count >= 7 else { return nil }
            return BulkTrack(
                persistentID: f[0],
                name: f[1],
                artist: f[2],
                album: f[3],
                filePath: f[4].isEmpty ? nil : f[4],
                hasLyrics: f[5] == "true",
                hasArtwork: (Int(f[6]) ?? 0) > 0
            )
        }
    }
}
