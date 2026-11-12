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
    // 2.x auto-write on → Automate; off → Propose
    #expect(settings.missingLyrics == .propose && settings.missingArtwork == .automate)
    #expect(settings.lyricsProvider == .auto)
    #expect(settings.ratingHotkeysEnabled)
    #expect(settings.panelHotkey == nil)
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
        "albumStats": MusicObserver.albumStatsScript("ABCDEF0123456789"),
        "albumYear": MusicObserver.trackScript("ABCDEF0123456789", MusicObserver.albumTracksBody(property: "year", value: "2005", skipping: ["0123", "4567"])),
        "albumGenre": MusicObserver.trackScript("ABCDEF0123456789", MusicObserver.albumTracksBody(property: "genre", value: "\"Indie Rock\"", skipping: [])),
        "pendingEdit": MusicObserver.trackScript("ABCDEF0123456789", MusicObserver.PendingEdit(year: 2005, genre: "Rock \"n\" Roll").scriptBody),
        "albumStar": MusicObserver.trackScript("ABCDEF0123456789", "set album favorited of t to true"),
        "albumRating": MusicObserver.trackScript("ABCDEF0123456789", "set album rating of t to 80"),
    ]
    for (name, source) in scripts {
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: source))
        let compiled = script.compileAndReturnError(&error)
        let message = error?[NSAppleScript.errorMessage] as? String ?? ""
        #expect(compiled, "\(name) script: \(message)")
    }
}

// MARK: - 3.0: Synced lyrics in tags

/// Lyrics as stored in the tag of Adam Green's "All Hell Breaks Loose": every line is timed,
/// and empty timed lines close each line.
private let adamGreenLRC = """
[00:13.00] Walls start closing in around you
[00:14.15]
[00:16.40] Second line of the verse
[00:18.00]
[00:20.10] Third line here
[00:21.50]
"""

@Test func detectsTimedLyricsInATag() {
    #expect(LRCParser.isSynced(adamGreenLRC))
    #expect(!LRCParser.isSynced("Walls start closing in\n[Chorus]\nSomething else\nAnd more"))
    #expect(!LRCParser.isSynced("[00:01.00] only\n[00:02.00] two"))  // Too few timed lines
    #expect(LRCParser.isSynced("[ar:Adam Green]\n[ti:Song]\n" + adamGreenLRC))  // Metadata ignored
}

@Test func plainTextDropsLineEndMarkers() {
    #expect(LRCParser.plainText(adamGreenLRC) == "Walls start closing in around you\nSecond line of the verse\nThird line here")
    let lines = LRCParser.parse(adamGreenLRC)
    #expect(lines.count == 6)
    #expect(lines[1].text.isEmpty && lines[1].time == 14.15)
}

@Test func plainTextKeepsStanzaBreaks() {
    let lrc = "[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n[00:04.00]\n[00:05.00]d\n[00:06.00]e\n[00:07.00]f"
    #expect(LRCParser.plainText(lrc) == "a\nb\nc\n\nd\ne\nf")
}

@Test func lrcOffsetShiftsLinesEarlier() {
    let lines = LRCParser.parse("[offset:+500]\n[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
    #expect(lines.map(\.time) == [9.5, 19.5, 29.5])
    #expect(LRCParser.parse("[offset:-1000]\n[00:10.00]a").first?.time == 11)
}

@Test func similarityAcceptsTimingOnlyChanges() {
    let plain = "Walls start closing in around you\nSecond line of the verse\nThird line here"
    #expect(LyricsSimilarity.score(plain, adamGreenLRC) == 1.0)
    // A few words differ: still the same lyrics
    let edited = "Walls start closing in around you\nSecond line of this verse\nThird line right here"
    #expect(LyricsSimilarity.score(edited, adamGreenLRC) >= NowPlayingController.syncedMatchThreshold)
    // Different song
    #expect(LyricsSimilarity.score("Hey Jude don't make it bad take a sad song", adamGreenLRC) < 0.75)
    #expect(LyricsSimilarity.score("", adamGreenLRC) == 0)
    // Section labels aren't counted as words
    #expect(LyricsSimilarity.score("[Verse 1]\n" + plain, plain) == 1.0)
}

// MARK: - 3.0: Album checks

@Test func parsesExtendedPollOutput() throws {
    let output = ["playing", "ABC", "Song", "Artist", "Album", "false", "false", "60", "", "1", "200",
                  "Album Artist", "2008", "Rock", "true", "80", "user"].joined(separator: US)
    let track = try #require(MusicObserver.parsePollOutput(output))
    #expect(track.albumArtist == "Album Artist" && track.year == 2008 && track.genre == "Rock")
    #expect(track.albumFavorited && track.albumRating == 4 && !track.albumRatingComputed)
    #expect(track.albumKey == "album artist|album")
}

@Test func albumStatsCountByCriterion() throws {
    let output = ["ok", ["true", "false", "true", "false"].joined(separator: RS),
                  ["0", "80", "100", "40"].joined(separator: RS)].joined(separator: US)
    let stats = try #require(MusicObserver.parseAlbumStats(output))
    #expect(stats.trackCount == 4 && stats.favoritedCount == 2)
    #expect(stats.qualifying(.favorited, minRating: 4) == 2)
    #expect(stats.qualifying(.rated, minRating: 4) == 2)
    #expect(stats.qualifying(.either, minRating: 4) == 3)
    #expect(stats.qualifying(.rated, minRating: 5) == 1)
    #expect(MusicObserver.parseAlbumStats("") == nil)
    #expect(MusicObserver.parseAlbumStats(["ok", "", ""].joined(separator: US))?.trackCount == 0)
}

@Test func albumStarThreshold() {
    #expect(!SuggestionCenter.shouldStarAlbum(qualifying: 5, threshold: 6))  // "More than five"
    #expect(SuggestionCenter.shouldStarAlbum(qualifying: 6, threshold: 6))
    #expect(SuggestionCenter.shouldStarAlbum(qualifying: 1, threshold: 0))   // Threshold is at least 1
    #expect(!SuggestionCenter.shouldStarAlbum(qualifying: 0, threshold: 0))
}

@Test func yearComparison() {
    #expect(SuggestionCenter.yearDiffers(music: 2008, reference: 2005))
    #expect(SuggestionCenter.yearDiffers(music: 0, reference: 2005))
    #expect(!SuggestionCenter.yearDiffers(music: 2005, reference: 2005))
    #expect(!SuggestionCenter.yearDiffers(music: 2008, reference: 0))
    #expect(MetadataWriter.year(fromDate: "2005-01-10") == 2005)
    #expect(MetadataWriter.year(fromDate: "2005-01-10T08:00:00Z") == 2005)
    #expect(MetadataWriter.year(fromDate: "1999") == 1999)
    #expect(MetadataWriter.year(fromDate: "") == nil)
    #expect(MetadataWriter.year(fromDate: "05") == nil)
}

@Test func musicBrainzSearchResultsAreMatched() throws {
    let json: [[String: Any]] = [
        ["id": "single", "title": "Gemstones", "primary-type": "Single", "first-release-date": "2004-11",
         "artist-credit": [["name": "Adam Green", "artist": ["id": "ag"]]]],
        ["id": "album", "title": "Gemstones", "primary-type": "Album", "first-release-date": "2005-01-10",
         "artist-credit": [["name": "Adam Green", "artist": ["id": "ag"]]],
         "tags": [["name": "rock", "count": 2], ["name": "anti-folk", "count": 1], ["name": "singer-songwriter", "count": 2]]],
        ["id": "other", "title": "Gemstones", "primary-type": "Album", "first-release-date": "1990",
         "artist-credit": [["name": "Someone Else"]]],
    ]
    let candidates = json.compactMap(MusicBrainzClient.candidate)
    let best = try #require(MusicBrainzClient.bestMatch(in: candidates, artist: "Adam Green", album: "Gemstones (Deluxe)"))
    #expect(best.id == "album")
    #expect(best.year == 2005)
    #expect(best.genres == ["rock", "singer-songwriter", "anti-folk"])  // Most votes first, ties in order
    #expect(best.artistID == "ag")
    #expect(MusicBrainzClient.bestMatch(in: candidates, artist: "Nobody", album: "Gemstones") == nil)
    #expect(MusicBrainzClient.luceneEscape("Say \"Hi\"") == "Say \\\"Hi\\\"")
}

@Test func genreNamesAndAgreement() {
    #expect(GenreMatching.displayName("singer-songwriter") == "Singer-Songwriter")
    #expect(GenreMatching.displayName("alternative rock") == "Alternative Rock")
    #expect(GenreMatching.agrees("Indie Rock", with: ["rock", "indie rock"]))
    #expect(!GenreMatching.agrees("Alternative", with: ["rock", "indie rock"]))
    #expect(!GenreMatching.agrees("", with: ["rock"]))
    #expect(!GenreMatching.agrees("Folk", with: ["a", "b", "c", "d", "e", "folk"]))  // Only the top 5 count
}

@MainActor
@Test func dismissedSuggestionsPersist() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dismissed-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = DismissedStore(url: url)
    #expect(!store.contains("year|a|2005"))
    store.insert("year|a|2005")
    #expect(DismissedStore(url: url).contains("year|a|2005"))
}

@Test func oldConfigGetsNewCheckDefaults() throws {
    let json = #"{"geniusAPIKey":"k","autoFetchLyrics":true,"autoFetchArtwork":false,"autoWriteLyrics":false,"autoWriteArtwork":true,"lyricsProvider":"bogus"}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.lyricsProvider == .auto)  // Unknown values fall back instead of failing
    #expect(settings.syncedLyricsUpgrade == .propose && settings.albumStarMode == .propose)
    #expect(settings.albumStarThreshold == 6 && settings.albumStarCriterion == .favorited)
    #expect(settings.yearCheck == .propose && settings.genreCheck == .propose)
    #expect(settings.panelPage == .cover && settings.preferSyncedLyrics)
}

// MARK: - 3.0.1

@Test func albumEditsSkipPlayingAndNextTracksAndUnchangedValues() {
    let body = MusicObserver.albumTracksBody(property: "year", value: "2005", skipping: ["AB12\" & x", "CD34"])
    #expect(body.contains("set skipList to {\"AB12\", \"CD34\"}"))  // Only hex survives
    #expect(body.contains("considering case"))  // "rock" → "Rock" must count as a change
    #expect(body.contains("set differs to (year of x is not 2005)"))
    #expect(MusicObserver.parseSkipped("ok" + US + "AB12" + RS + "CD34") == ["AB12", "CD34"])
    #expect(MusicObserver.parseSkipped("ok" + US) == [])
    #expect(MusicObserver.parseSkipped("") == [])
}

@Test func pollOutputCarriesTheNextTrack() throws {
    let output = ["playing", "ABC", "Song", "Artist", "Album", "false", "false", "60", "/a.m4a", "1", "200",
                  "AA", "2008", "Rock", "false", "0", "computed", "DEF", "/b.m4a"].joined(separator: US)
    let track = try #require(MusicObserver.parsePollOutput(output))
    #expect(track.nextPersistentID == "DEF" && track.nextFilePath == "/b.m4a")
}

@Test func pendingEditScript() {
    let edit = MusicObserver.PendingEdit(year: 2005, genre: "Say \"Hi\"")
    #expect(edit.scriptBody.contains("set year of t to 2005"))
    #expect(edit.scriptBody.contains("set genre of t to \"Say \\\"Hi\\\"\""))
    #expect(MusicObserver.PendingEdit(year: nil, genre: nil).scriptBody.isEmpty)
    #expect(edit.scriptBody.hasPrefix("considering case"))
}

@Test func progressTimeFormat() {
    #expect(ProgressScrubber.format(0) == "0:00")
    #expect(ProgressScrubber.format(65.4) == "1:05")
    #expect(ProgressScrubber.format(3725) == "1:02:05")
}

@Test func shortcutNames() {
    #expect(HotkeyManager.displayString(modifiers: [.control, .option], key: "S") == "⌃⌥S")
    #expect(HotkeyManager.displayString(modifiers: [.command, .shift], key: "L") == "⇧⌘L")
    #expect(HotkeyManager.keyName(keyCode: 49, characters: " ") == "Space")
    #expect(HotkeyManager.keyName(keyCode: 1, characters: "s") == "S")
    #expect(HotkeyManager.carbonModifiers([.control, .option]) == UInt32(0x1000 | 0x0800))
}

@Test func panelHotkeyRoundTrips() throws {
    var settings = AppSettings.default
    settings.panelHotkey = KeyCombo(keyCode: 1, modifiers: 0x1800, display: "⌃⌥S")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
}
