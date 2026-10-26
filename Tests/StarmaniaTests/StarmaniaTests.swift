import Foundation
import Testing
@testable import Starmania

// MARK: - Text matching

@Test func stripBracketsRemovesSuffixes() {
    #expect(TextMatching.stripBrackets("Hey Jude (Remastered 2015)") == "Hey Jude")
    #expect(TextMatching.stripBrackets("Song [Live] (feat. X)") == "Song")
    #expect(TextMatching.stripBrackets("Plain") == "Plain")
}

@Test func normalizeFoldsDiacriticsAndPunctuation() {
    #expect(TextMatching.normalizeForMatching("Beyoncé") == "beyonce")
    #expect(TextMatching.normalizeForMatching("The Beatles") == "beatles")
    #expect(TextMatching.normalizeForMatching("Simon & Garfunkel") == "simon and garfunkel")
    #expect(TextMatching.normalizeForMatching("AC/DC") == "ac dc")
}

@Test func wordOverlapScores() {
    #expect(TextMatching.wordOverlapScore("Simon & Garfunkel", "Simon and Garfunkel") == 1.0)
    #expect(TextMatching.wordOverlapScore("Abel", "Totally Different") == 0.0)
    #expect(TextMatching.wordOverlapScore("", "x") == 0.0)
    let partial = TextMatching.wordOverlapScore("Hey Jude", "Hey Jude Live")
    #expect(partial > 0.5 && partial < 1.0)
}

@Test func queryEncodingKeepsReservedCharacters() throws {
    let url = try #require(TextMatching.url("https://example.com/search", query: [("q", "Simon & Garfunkel + #1=hit")]))
    let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
    #expect(item?.value == "Simon & Garfunkel + #1=hit")
    #expect(url.absoluteString.contains("%26"))
    #expect(url.absoluteString.contains("%2B"))
    #expect(!url.absoluteString.contains("#"))
}

// MARK: - Lyrics providers

@Test func providerOrderPutsPreferredFirst() {
    #expect(LyricsService.providerOrder(for: .auto) == [.lrclib, .songLyrics, .genius])
    #expect(LyricsService.providerOrder(for: .genius).first == .genius)
    #expect(LyricsService.providerOrder(for: .songLyrics).first == .songLyrics)
    for option in LyricsProviderOption.allCases {
        #expect(Set(LyricsService.providerOrder(for: option)).count == 3)
    }
}

// MARK: - Synced lyrics

@Test func lrcParsingSortsAndExpandsTimestamps() {
    let lrc = """
    [ar:Someone]
    [00:12.50] First line
    [00:05.00][01:00.00] Chorus
    [00:20.00]
    """
    let lines = LRCParser.parse(lrc)
    #expect(lines.map(\.text) == ["Chorus", "First line", "", "Chorus"])
    #expect(lines.map(\.time) == [5.0, 12.5, 20.0, 60.0])
    #expect(lines.map(\.id) == [0, 1, 2, 3])
}

@Test func currentLineIndexTracksTime() {
    let lines = LRCParser.parse("[00:01.00]a\n[00:03.00]b\n[00:05.00]c")
    #expect(LRCParser.currentLineIndex(in: lines, at: 0.5) == nil)
    #expect(LRCParser.currentLineIndex(in: lines, at: 1.0) == 0)
    #expect(LRCParser.currentLineIndex(in: lines, at: 4.2) == 1)
    #expect(LRCParser.currentLineIndex(in: lines, at: 99) == 2)
}

@Test func estimatedPositionExtrapolatesWhilePlaying() {
    let start = Date()
    var track = TrackInfo(persistentID: "A", name: "n", artist: "a", album: "b", favorited: false,
                          disliked: false, rating: 0, filePath: nil, artworkData: nil, embeddedLyrics: nil,
                          isPlaying: true, position: 10, positionDate: start, duration: 12)
    #expect(track.estimatedPosition(at: start.addingTimeInterval(1)) == 11)
    #expect(track.estimatedPosition(at: start.addingTimeInterval(5)) == 12)  // Clamped to duration
    track.isPlaying = false
    #expect(track.estimatedPosition(at: start.addingTimeInterval(5)) == 10)
}

// MARK: - AppleScript output parsing

private let US = "\u{1F}"
private let RS = "\u{1E}"

@Test func parsesPollOutput() throws {
    let output = ["playing", "ABC123", "Song", "Artist", "Album", "true", "false", "80",
                  "/Music/song.mp3", "12,5", "200.0"].joined(separator: US)
    let track = try #require(MusicObserver.parsePollOutput(output))
    #expect(track.persistentID == "ABC123")
    #expect(track.trackKey == "ABC123")
    #expect(track.favorited && !track.disliked)
    #expect(track.rating == 4)
    #expect(track.filePath == "/Music/song.mp3")
    #expect(track.isPlaying)
    #expect(track.position == 12.5)  // Comma decimal separator tolerated
    #expect(track.duration == 200)
}

@Test func pollOutputForStreamingAndStoppedStates() {
    let streaming = ["paused", "X", "S", "A", "B", "false", "false", "0", "", "0", "0"].joined(separator: US)
    #expect(MusicObserver.parsePollOutput(streaming)?.filePath == nil)
    #expect(MusicObserver.parsePollOutput(streaming)?.isPlaying == false)
    #expect(MusicObserver.parsePollOutput("stopped") == nil)
    #expect(MusicObserver.parsePollOutput("ERROR" + "oops") == nil)
}

@Test func parsesAlbumOutputSortedByDiscAndTrack() {
    func list(_ items: [String]) -> String { items.joined(separator: RS) }
    let output = [
        "album", "P2",
        list(["P3", "P1", "P2"]),
        list(["Three", "One", "Intro"]),
        list(["A", "A", "A"]),
        list(["false", "true", "false"]),
        list(["false", "false", "true"]),
        list(["60", "100", "0"]),
        list(["1", "1", "1"]),
        list(["3", "1", "2"]),
    ].joined(separator: US)

    let tracks = MusicObserver.parsePlaylistOutput(output)
    #expect(tracks.map(\.id) == ["P1", "P2", "P3"])
    #expect(tracks.map(\.rating) == [5, 0, 3])
    #expect(tracks.filter(\.isCurrentTrack).map(\.id) == ["P2"])
    #expect(tracks[0].favorited && tracks[1].disliked)
}

@Test func albumOutputIsWindowedAroundCurrentTrack() {
    let ids = (1...60).map { "P\($0)" }
    func list(_ items: [String]) -> String { items.joined(separator: RS) }
    let output = [
        "album", "P50",
        list(ids), list(ids), list(ids.map { _ in "A" }),
        list(ids.map { _ in "false" }), list(ids.map { _ in "false" }), list(ids.map { _ in "0" }),
        list(ids.map { _ in "1" }), list((1...60).map(String.init)),
    ].joined(separator: US)

    let tracks = MusicObserver.parsePlaylistOutput(output, window: 40)
    #expect(tracks.count == 40)
    #expect(tracks.contains { $0.isCurrentTrack })
    #expect(tracks.last?.id == "P60")
}

@Test func playlistOutputWithMismatchedListsIsRejected() {
    let output = ["playlist", "P1", "P1\(RS)P2", "One", "A", "false", "false", "0", "", ""].joined(separator: US)
    #expect(MusicObserver.parsePlaylistOutput(output).isEmpty)
}

@Test func parsesBulkOutput() {
    let rows = [
        ["P1", "One", "A", "B", "/x/one.mp3", "true", "1"].joined(separator: US),
        ["P2", "Two", "A", "B", "", "false", "0"].joined(separator: US),
    ]
    let tracks = MusicObserver.parseBulkOutput((["album"] + rows).joined(separator: RS))
    #expect(tracks.count == 2)
    #expect(tracks[0].hasLyrics && tracks[0].hasArtwork && tracks[0].filePath == "/x/one.mp3")
    #expect(!tracks[1].hasLyrics && !tracks[1].hasArtwork && tracks[1].filePath == nil)
    #expect(MusicObserver.parseBulkOutput("ERROR nope").isEmpty)
}

@Test func trackScriptSanitizesPersistentID() {
    let script = MusicObserver.trackScript("AB12\" & do shell script \"x", "play t")
    #expect(!script.contains("do shell script"))
    #expect(script.contains("\"AB12dec\""))  // Only hex digits survive
}

// MARK: - Artwork matching

@Test func artworkMatchRequiresArtistAndAlbum() {
    let candidates = [
        ArtworkFetcher.Candidate(artist: "Someone Else", album: "Greatest Hits", artworkURL: "a"),
        ArtworkFetcher.Candidate(artist: "Abel", album: "De Stilte Voorbij (Remastered)", artworkURL: "b"),
        ArtworkFetcher.Candidate(artist: "Abel", album: "Other Album", artworkURL: "c"),
    ]
    #expect(ArtworkFetcher.bestMatch(in: candidates, artist: "Abel", album: "De Stilte Voorbij")?.artworkURL == "b")
    #expect(ArtworkFetcher.bestMatch(in: candidates, artist: "Nobody", album: "Greatest Hits") == nil)
    #expect(ArtworkFetcher.highResURL("https://x/100x100bb.jpg") == "https://x/600x600bb.jpg")
}

// MARK: - Metadata formats

@Test func onlyMP3AndM4AAreWritable() {
    #expect(MetadataWriter.format(of: "/a/b.mp3") == .mp3)
    #expect(MetadataWriter.format(of: "/a/b.M4A") == .m4a)
    #expect(MetadataWriter.format(of: "/a/b.m4p") == nil)
    #expect(MetadataWriter.format(of: "/a/b.aac") == nil)
}

// MARK: - Settings

@Test func settingsDecodeOldConfigWithDefaults() throws {
    let json = #"{"geniusAPIKey":"k","autoFetchLyrics":true,"autoFetchArtwork":false,"autoWriteLyrics":false,"autoWriteArtwork":true}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.autoFetchLyrics && settings.autoWriteArtwork)
    #expect(settings.lyricsProvider == .auto)
    #expect(settings.ratingHotkeysEnabled)
}

@MainActor
@Test func writeQueueMergesFieldsPerPath() {
    let queue = FileWriteQueue()
    queue.enqueue(path: "/a.mp3", lyrics: "first", artwork: nil)
    queue.enqueue(path: "/a.mp3", lyrics: nil, artwork: Data([1]))
    queue.enqueue(path: "/a.mp3", lyrics: "second", artwork: nil)
    #expect(queue.pending["/a.mp3"] == FileWriteQueue.PendingWrite(lyrics: "second", artwork: Data([1])))
}

// MARK: - AppleScript syntax

/// Compiles every script against Music's dictionary, catching syntax and terminology errors.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Music.app")))
func appleScriptsCompile() throws {
    let scripts = [
        "poll": MusicObserver.pollScript,
        "playlist": MusicObserver.playlistScript,
        "bulk": MusicObserver.bulkScript,
        "track": MusicObserver.trackScript("ABCDEF0123456789", "set rating of t to 60"),
        "lyrics": MusicObserver.trackScript("ABCDEF0123456789", "set lyrics of t to \"\(MusicObserver.escapeForAppleScript("a \"quoted\" \\ line\nnext"))\""),
    ]
    for (name, source) in scripts {
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: source))
        let compiled = script.compileAndReturnError(&error)
        let message = error?[NSAppleScript.errorMessage] as? String ?? ""
        #expect(compiled, "\(name) script: \(message)")
    }
}
