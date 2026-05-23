import Foundation
import AppKit

/// Bridges Apple Music via AppleScript. Polls for current track info.
/// All AppleScript calls wrapped in try/on error for robustness.
@MainActor
class MusicObserver: ObservableObject {
    static let shared = MusicObserver()
    
    @Published var currentTrack: TrackInfo?
    @Published var musicRunning: Bool = false
    @Published var errorMessage: String?
    
    private var pollTimer: Timer?
    private var lastTrackKey: String = ""
    
    private init() {}
    
    func startPolling() {
        // Immediate first poll
        poll()
        // Then every 2 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }
    
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    // MARK: - Polling
    
    private func poll() {
        // Check if Music.app is running
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
        
        // Get player state first
        guard let state = runAppleScript("tell application \"Music\" to player state as string"),
              state == "playing" || state == "paused" else {
            currentTrack = nil
            lastTrackKey = ""
            return
        }
        
        let isPlaying = (state == "playing")
        
        // Get basic track info
        let script = """
        tell application "Music"
            try
                set t to current track
                set trackName to name of t
                set trackArtist to artist of t
                set trackAlbum to album of t
                set isFav to favorited of t
                set isDis to disliked of t
                set trackRating to rating of t
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (isFav as string) & "|||" & (isDis as string) & "|||" & (trackRating as string)
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        
        guard let result = runAppleScript(script), !result.hasPrefix("ERROR:") else {
            errorMessage = "Could not read track info"
            return
        }
        
        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 6 else { return }
        
        let name = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let favorited = parts[3].lowercased() == "true"
        let disliked = parts[4].lowercased() == "true"
        // Apple Music rating is 0-100, convert to 0-5 stars
        let rawRating = Int(parts[5]) ?? 0
        let rating = rawRating / 20
        
        // Get file path (may fail for streaming)
        let filePath = runAppleScript("""
        tell application "Music"
            try
                return POSIX path of (location of current track as text)
            on error
                return ""
            end try
        end tell
        """)
        
        let trackKey = "\(name)|\(artist)|\(album)"
        let trackChanged = (trackKey != lastTrackKey)
        
        // Get artwork and embedded lyrics if track changed
        var artworkData: Data? = nil
        var embeddedLyrics: String? = nil
        if trackChanged {
            artworkData = fetchArtworkData()
            embeddedLyrics = fetchEmbeddedLyrics()
        } else {
            artworkData = currentTrack?.artworkData
            embeddedLyrics = currentTrack?.embeddedLyrics
        }
        
        let track = TrackInfo(
            name: name,
            artist: artist,
            album: album,
            favorited: favorited,
            disliked: disliked,
            rating: rating,
            filePath: filePath?.isEmpty == true ? nil : filePath,
            artworkData: artworkData,
            embeddedLyrics: embeddedLyrics,
            isPlaying: isPlaying
        )
        
        lastTrackKey = trackKey
        self.currentTrack = track
        self.errorMessage = nil
    }
    
    // MARK: - Artwork
    
    private func fetchArtworkData() -> Data? {
        // AppleScript raw data approach: write to temp file and read back
        let tempPath = NSTemporaryDirectory() + "starmania_artwork.tmp"
        let writeScript = """
        tell application "Music"
            try
                set artData to raw data of artwork 1 of current track
                set filePath to POSIX file "\(tempPath)"
                set fileRef to open for access filePath with write permission
                set eof fileRef to 0
                write artData to fileRef
                close access fileRef
                return "OK"
            on error errMsg
                try
                    close access filePath
                end try
                return "ERROR:" & errMsg
            end try
        end tell
        """
        
        if let result = runAppleScript(writeScript), result == "OK" {
            let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath))
            try? FileManager.default.removeItem(atPath: tempPath)
            return data
        }
        
        return nil
    }
    
    // MARK: - Embedded Lyrics
    
    private func fetchEmbeddedLyrics() -> String? {
        let result = runAppleScript("""
        tell application "Music"
            try
                set lyr to lyrics of current track
                if lyr is missing value then
                    return ""
                end if
                return lyr
            on error
                return ""
            end try
        end tell
        """)
        
        guard let lyrics = result, !lyrics.isEmpty else { return nil }
        return lyrics
    }
    // MARK: - Update Artwork from External Fetch
    
    func updateArtwork(_ data: Data) {
        currentTrack?.artworkData = data
    }
    
    // MARK: - Write Back to Apple Music
    
    func setFavorited(_ value: Bool) {
        let _ = runAppleScript("""
        tell application "Music"
            try
                set favorited of current track to \(value)
            end try
        end tell
        """)
        poll()
    }
    
    func setDisliked(_ value: Bool) {
        let _ = runAppleScript("""
        tell application "Music"
            try
                set disliked of current track to \(value)
            end try
        end tell
        """)
        poll()
    }
    
    func setRating(_ stars: Int) {
        // Apple Music rating is 0-100, where each star = 20
        let ratingValue = stars * 20
        let _ = runAppleScript("""
        tell application "Music"
            try
                set rating of current track to \(ratingValue)
            end try
        end tell
        """)
        poll()
    }
    
    func setLyrics(_ lyrics: String) {
        // Escape quotes and backslashes for AppleScript string
        let escaped = lyrics
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let _ = runAppleScript("""
        tell application "Music"
            try
                set lyrics of current track to "\(escaped)"
            end try
        end tell
        """)
        
        // Update local state without waiting for poll
        currentTrack?.embeddedLyrics = lyrics
        poll()
    }
    
    func deleteArtwork() {
        let _ = runAppleScript("""
        tell application "Music"
            try
                delete artworks of current track
            end try
        end tell
        """)
        currentTrack?.artworkData = nil
        poll()
    }
    
    // MARK: - Playback Controls
    
    func play() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        let _ = runAppleScript("tell application \"Music\" to play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.poll()
        }
    }
    
    func playPause() {
        let _ = runAppleScript("tell application \"Music\" to playpause")
        // Quick re-poll to update play state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.poll()
        }
    }
    
    func nextTrack() {
        let _ = runAppleScript("tell application \"Music\" to next track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }
    
    func previousTrack() {
        let _ = runAppleScript("tell application \"Music\" to previous track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }
    
    // MARK: - Playlist / Album Track List
    
    /// Fetch up to 40 tracks from the current playlist/album, centered on the current track.
    func fetchPlaylistTracks() -> [PlaylistTrackInfo] {
        // Step 1: Get track count and current track index
        // Try to identify if we are playing an album or playlist, using fast checks
        let infoScript = """
        tell application "Music"
            try
                set ct to current track
                set ctName to name of ct
                set ctArtist to artist of ct
                
                -- Check if playing an album from the main library playlist
                try
                    set plName to name of current playlist
                    if plName is "Music" or plName is "Library" then
                        set ctAlbum to album of ct
                        set ctArtist to artist of ct
                        if ctAlbum is not "" then
                            set trackList to (every track of current playlist whose album is ctAlbum and artist is ctArtist)
                            set total to count of trackList
                            set idx to 0
                            repeat with i from 1 to total
                                set t to item i of trackList
                                if name of t is ctName then
                                    set idx to i
                                    exit repeat
                                end if
                            end repeat
                            if idx > 0 then
                                return (idx as string) & "|||" & (total as string) & "|||album"
                            end if
                        end if
                    end if
                end try

                -- Try current playlist next (standard playlist)
                try
                    set src to current playlist
                    set total to count of tracks of src
                    set idx to index of ct
                    -- Fast O(1) verification: check if track at this index matches ctName and ctArtist
                    set verified to false
                    try
                        set t to track idx of src
                        if name of t is ctName and artist of t is ctArtist then
                            set verified to true
                        end if
                    end try
                    if verified then
                        return (idx as string) & "|||" & (total as string) & "|||playlist"
                    else if total < 100 then
                        -- Only loop if playlist is small
                        set foundIdx to 0
                        repeat with i from 1 to total
                            set t to track i of src
                            if name of t is ctName and artist of t is ctArtist then
                                set foundIdx to i
                                exit repeat
                            end if
                        end repeat
                        if foundIdx > 0 then
                            return (foundIdx as string) & "|||" & (total as string) & "|||playlist"
                        end if
                    end if
                end try
                
                -- Fallback: container of current track
                try
                    set src to container of ct
                    set total to count of tracks of src
                    set idx to index of ct
                    return (idx as string) & "|||" & (total as string) & "|||container"
                end try
                
                return "ERROR"
            on error errMsg
                return "ERROR"
            end try
        end tell
        """
        
        guard let info = runAppleScript(infoScript), info != "ERROR" else {
            print("[Starmania] Playlist info script returned ERROR or nil")
            return []
        }
        
        let parts = info.components(separatedBy: "|||")
        guard parts.count >= 3,
              let currentIndex = Int(parts[0]),
              let totalTracks = Int(parts[1]) else {
            print("[Starmania] Could not parse playlist info: \(info)")
            return []
        }
        
        let sourceType = parts[2]  // "album", "playlist", or "container"
        
        // Calculate window: up to 40 tracks centered on current track
        let windowSize = 40
        var startIndex: Int
        var endIndex: Int
        
        if totalTracks <= windowSize {
            startIndex = 1
            endIndex = totalTracks
        } else {
            let halfWindow = windowSize / 2
            startIndex = max(1, currentIndex - halfWindow)
            endIndex = startIndex + windowSize - 1
            if endIndex > totalTracks {
                endIndex = totalTracks
                startIndex = max(1, endIndex - windowSize + 1)
            }
        }
        
        // Step 2: Fetch track data for the window
        let fetchScript: String
        if sourceType == "album" {
            fetchScript = """
            tell application "Music"
                try
                    set ct to current track
                    set ctName to name of ct
                    set ctArtist to artist of ct
                    set ctAlbum to album of ct
                    set trackList to (every track of current playlist whose album is ctAlbum and artist is ctArtist)
                    set trackListWindow to items \(startIndex) thru \(endIndex) of trackList
                    set output to ""
                    repeat with t in trackListWindow
                        set trackName to name of t
                        set trackArtist to artist of t
                        set isFav to favorited of t
                        set isDis to disliked of t
                        set trackRating to rating of t
                        set trackIdx to index of t
                        set isCurrent to (trackName = ctName and trackArtist = ctArtist) as string
                        set trackLine to trackName & "|||" & trackArtist & "|||" & (isFav as string) & "|||" & (isDis as string) & "|||" & (trackRating as string) & "|||" & (trackIdx as string) & "|||" & isCurrent
                        if output is "" then
                            set output to trackLine
                        else
                            set output to output & "^^^" & trackLine
                        end if
                    end repeat
                    return output
                on error errMsg
                    return "ERROR:" & errMsg
                end try
            end tell
            """
        } else {
            let sourceRef = sourceType == "playlist" ? "current playlist" : "container of current track"
            fetchScript = """
            tell application "Music"
                try
                    set ct to current track
                    set ctName to name of ct
                    set ctArtist to artist of ct
                    set src to \(sourceRef)
                    set trackListWindow to tracks \(startIndex) thru \(endIndex) of src
                    set output to ""
                    repeat with t in trackListWindow
                        set trackName to name of t
                        set trackArtist to artist of t
                        set isFav to favorited of t
                        set isDis to disliked of t
                        set trackRating to rating of t
                        set trackIdx to index of t
                        set isCurrent to (trackName = ctName and trackArtist = ctArtist) as string
                        set trackLine to trackName & "|||" & trackArtist & "|||" & (isFav as string) & "|||" & (isDis as string) & "|||" & (trackRating as string) & "|||" & (trackIdx as string) & "|||" & isCurrent
                        if output is "" then
                            set output to trackLine
                        else
                            set output to output & "^^^" & trackLine
                        end if
                    end repeat
                    return output
                on error errMsg
                    return "ERROR:" & errMsg
                end try
            end tell
            """
        }
        
        guard let result = runAppleScript(fetchScript), !result.hasPrefix("ERROR:") else {
            print("[Starmania] Playlist fetch script failed")
            return []
        }
        
        let lines = result.components(separatedBy: "^^^")
        var tracks: [PlaylistTrackInfo] = []
        
        for line in lines {
            let fields = line.components(separatedBy: "|||")
            guard fields.count >= 7 else { continue }
            
            let name = fields[0]
            let artist = fields[1]
            let favorited = fields[2].lowercased() == "true"
            let disliked = fields[3].lowercased() == "true"
            let rawRating = Int(fields[4]) ?? 0
            let rating = rawRating / 20
            let trackIndex = Int(fields[5]) ?? 0
            let isCurrent = fields[6].lowercased() == "true"
            
            tracks.append(PlaylistTrackInfo(
                id: trackIndex,
                name: name,
                artist: artist,
                favorited: favorited,
                disliked: disliked,
                rating: rating,
                isCurrentTrack: isCurrent
            ))
        }
        
        print("[Starmania] Loaded \(tracks.count) playlist tracks via \(sourceType)")
        return tracks
    }
    
    /// Play a specific track by its index in the current playlist/album container.
    func playTrackAtIndex(_ index: Int) {
        let _ = runAppleScript("""
        tell application "Music"
            try
                play track \(index) of current playlist
            on error
                try
                    set src to container of current track
                    play track \(index) of src
                end try
            end try
        end tell
        """)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }
    
    /// Set favorited for a specific track by index in the current playlist container.
    func setFavoritedForTrack(atIndex index: Int, value: Bool) {
        let _ = runAppleScript("""
        tell application "Music"
            try
                set favorited of track \(index) of current playlist to \(value)
            on error
                try
                    set src to container of current track
                    set favorited of track \(index) of src to \(value)
                end try
            end try
        end tell
        """)
        if currentTrack != nil {
            poll()
        }
    }
    
    /// Set disliked for a specific track by index in the current playlist container.
    func setDislikedForTrack(atIndex index: Int, value: Bool) {
        let _ = runAppleScript("""
        tell application "Music"
            try
                set disliked of track \(index) of current playlist to \(value)
            on error
                try
                    set src to container of current track
                    set disliked of track \(index) of src to \(value)
                end try
            end try
        end tell
        """)
        if currentTrack != nil {
            poll()
        }
    }
    
    /// Set rating for a specific track by index in the current playlist container.
    func setRatingForTrack(atIndex index: Int, stars: Int) {
        let ratingValue = stars * 20
        let _ = runAppleScript("""
        tell application "Music"
            try
                set rating of track \(index) of current playlist to \(ratingValue)
            on error
                try
                    set src to container of current track
                    set rating of track \(index) of src to \(ratingValue)
                end try
            end try
        end tell
        """)
        if currentTrack != nil {
            poll()
        }
    }
    
    // MARK: - AppleScript Runner
    
    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        
        if let error = error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            // Don't spam logs for expected errors (Music not playing, etc.)
            if !errorMsg.contains("Can't get current track") {
                print("[Starmania] AppleScript error: \(errorMsg)")
            }
            return nil
        }
        
        return result?.stringValue
    }
}
