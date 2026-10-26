# Starmania ★

A macOS menu bar app for managing Apple Music song metadata — star ratings, favorites, artwork, and lyrics.

## Features

- **Menu bar icon** showing the current track's state: solid/hollow star for favorite, rating number top-right, × for dislike
- **Floating panel** (click the icon):
  - ♡ Favorite and 👎 Dislike toggles, ★★★★★ 5-star rating — written back to Apple Music
  - Album artwork with hover playback controls (previous / play-pause / next)
  - Lyrics: embedded, or fetched from LRCLIB, SongLyrics.com or Genius
  - **Synced lyrics** from LRCLIB: the current line is highlighted and kept centered as the song plays (toggle with the waveform button)
  - Playlist/album view (list button): up to 40 tracks around the current one, each with its own favorite, dislike and rating controls; click a title to play it
  - Fetch / write / copy lyrics and artwork; hold ⌥ to turn Write into Delete
- **Global shortcuts**: ⌃⌥1–5 rate the current track, ⌃⌥0 clears the rating, ⌃⌥F toggles favorite, ⌃⌥D toggles dislike
- **Bulk fetch**: fill in missing lyrics and artwork for the whole current album or playlist (up to 200 tracks) from the settings menu
- **Settings** (⌥-click or right-click the icon, or the gear in the panel):
  - Auto-fetch lyrics / artwork when a track has none
  - Auto-write fetched lyrics / artwork to the file
  - Preferred lyrics provider, optional Lyrica server, Genius API key
  - Global shortcuts and launch at login (Settings… window)

Writes to the file of the track that is currently playing are queued until the track changes (rewriting a playing file can interrupt playback). Anything still queued is written when you quit.

Tag writing supports `.mp3` (ID3) and `.m4a` (MPEG-4) files. Lyrics for streaming tracks are stored in Apple Music's own library.

## Requirements

- macOS 14.0+ on Apple silicon
- Xcode Command Line Tools with Swift 6
- A [Genius API](https://genius.com/api-clients) client access token is optional — a default one is pre-configured

## Build & Run

```bash
./build.sh
```

The script asks for an optional name suffix and whether to install into `/Applications`, builds a release binary, assembles and ad-hoc signs `Starmania.app`, and registers it with Launch Services. Pass `--clean` to flush the build cache first.

The first launch asks for permission to control Music (System Settings → Privacy & Security → Automation).

## Tests

```bash
swift test --disable-sandbox --build-path /private/tmp/Starmania_build -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

With only the Command Line Tools installed, the extra flags point SwiftPM at the Swift Testing macro plugin and keep the build out of synced folders. Set `SDKROOT` to the same SDK `build.sh` uses if the default SDK fails to find SwiftUI's macros.

The tests cover text matching and query encoding, provider order, LRC parsing, AppleScript output parsing, artwork matching and settings decoding, and compile every AppleScript against Music's dictionary.

## Genius API Setup (Optional)

Starmania comes pre-configured with a default Genius API key. If you reach the rate limit or prefer to use your own:

1. Go to [genius.com/api-clients](https://genius.com/api-clients)
2. Create a new API client (use `https://github.com/shmvon/starmania` as app URL)
3. Copy the **Client Access Token**
4. Open **Settings…** from the Starmania menu and paste it into the Genius API key field

## Architecture

- **Swift Package Manager** executable with a SwiftUI + AppKit hybrid UI
- `MusicObserver` talks to Music via AppleScript on a background queue (`AppleScriptRunner`), listens for Music's `com.apple.Music.playerInfo` notification and polls every 4 s as a fallback; tracks are identified by Music's persistent ID
- `NowPlayingController` owns lyrics/artwork state, auto-fetch, bulk fetch and the deferred file-write queue
- Lyrics providers: `LrclibFetcher` (LRCLIB / Lyrica, with synced lyrics), `SongLyricsFetcher`, `GeniusFetcher`, coordinated by `LyricsService`; artwork from the iTunes Search API via `ArtworkFetcher`
- `MetadataWriter` writes ID3 (via [ID3TagEditor](https://github.com/chicio/ID3TagEditor)) and MPEG-4 tags; HTML scraping via [SwiftSoup](https://github.com/scinfu/SwiftSoup)
- Non-sandboxed for file system access (needed for tag writing)

## License

MIT
