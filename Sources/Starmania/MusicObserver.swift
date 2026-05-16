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
    
    // MARK: - Playback Controls
    
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
