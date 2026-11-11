# Starmania ★

A macOS menu bar app for Apple Music: rate and favorite songs, star albums, and keep lyrics, artwork, years and genres right — for the song that's playing.

## Features

- **Menu bar icon** showing the current song: solid/hollow star for favorite, rating top-right, × for dislike. A gentle pulse means a suggestion is waiting.
- **Floating panel** (click the icon, or your shortcut): the song, one page at a time, and the song's favorite, dislike and rating at the bottom:
  - **Cover** — the artwork, with playback controls on hover. Drag it out as a PNG, or right-click to copy, fetch again, save to the file or delete.
  - **Lyrics** — embedded, or fetched from LRCLIB, SongLyrics.com or Genius. Timed lyrics highlight the current line. Right-click to copy (with or without timing), fetch again, save or delete.
  - **Album** — a big star to favorite the album, the album rating, year and genre checked against MusicBrainz (other genres to pick from right next to it), and the album (or playlist) tracks with their own ratings.
  - Playback controls next to the page tabs.
- **Synced lyrics**
  - Lyrics with `[mm:ss.xx]` timestamps — in a file tag or from a provider — are shown highlighted line by line.
  - For songs with plain lyrics, Starmania looks for a timed version and offers to replace them, but only when at least 75% of the words are the same, so only the timing is added.
- **Album star**: stars an album once enough of its songs are favorited (or rated highly). The number and the rule are settings; Starmania never removes an album star.
- **Year and genre check**: compares the playing album with [MusicBrainz](https://musicbrainz.org), an open music database — the year of the first release (not a remaster's) and the genres its users voted for. Changes apply to the whole album.
- **Missing lyrics and artwork** are fetched for the playing song and saved to the file, or offered to save.
- **Propose or automate**: each check is Off, Propose (pulse + a card in the panel with Apply / Dismiss; dismissals are remembered) or Automate. Checks only run for what's playing, never across the whole library.
- **Global shortcuts**: a shortcut of your choice shows the panel; ⌃⌥1–5 rate, ⌃⌥0 clears the rating, ⌃⌥F favorite, ⌃⌥D dislike.
- **Bulk fetch** of missing lyrics and artwork for the current album or playlist (settings menu).
- **Settings**: right-click (or ⌥-click) the menu bar icon.

### Where changes are stored

| What | Local `.mp3` / `.m4a` file | Streaming track |
|---|---|---|
| Lyrics (plain or timed) | In the file's tag (ID3 `USLT` / MPEG-4 `©lyr`) | Music's library |
| Artwork | In the file's tag | — |
| Year, genre | Set in Music, which writes them into the file | Music's library |
| Ratings, favorites, album star | Music's library (Music doesn't put these in files) | Music's library |

For local files Starmania reads lyrics and year straight from the file, so it shows what the file holds even before Music notices a change.

Rewriting the file of the song that's playing interrupts playback, and rewriting the next song's file (Music loads it early for gapless playback) can stop playback at the transition — and Music rewrites a file whenever its year or genre is set, even to the same value. So changes to those two songs (lyrics, artwork, year, genre) wait until neither is playing or up next, album-wide changes skip songs that already have the value, and anything still waiting is written when you quit.

## Requirements

- macOS 14 or later
- Xcode, or just the Command Line Tools (`xcode-select --install`), with Swift 6

## Build & Run

```bash
./build.sh
```

The script asks for an optional name suffix and whether to install into `/Applications`, builds a release binary, assembles and ad-hoc signs `Starmania.app`, and registers it with Launch Services. Without the dialog:

```bash
./build.sh --no-dialog --install
```

Other options: `--suffix NAME`, `--zip` (also writes `dist/Starmania-<version>.zip`), `--clean` (flush the build cache first), `--help`.

It builds on any Mac: it tries the default SDK first and falls back to the other installed SDKs if one can't build SwiftUI (some Command Line Tools SDKs lack SwiftUI's macro plugin). The build happens in `/private/tmp/Starmania_build`, outside synced folders such as Google Drive or iCloud.

The first launch asks for permission to control Music (System Settings → Privacy & Security → Automation).

## Tests

```bash
./test.sh
```

Finds the Swift Testing plugin when only the Command Line Tools are installed and uses the same SDK fallback as `build.sh`. The tests cover lyrics timing and the 75% match, AppleScript output parsing, MusicBrainz matching, the album star rule, settings migration, and compile every AppleScript against Music's dictionary.

## Project layout

```
Starmania-gh/
├── VERSION              The version number (3.0); build.sh stamps it into the app
├── CHANGELOG.md         What changed in each version
├── build.sh, test.sh    Build the app / run the tests
├── Package.swift        Swift package; Package.resolved pins the dependency versions
├── Resources/           Info.plist and the app icon
├── Sources/Starmania/
│   ├── App/             App delegate, settings, hotkeys, lyrics/artwork controller
│   ├── Music/           AppleScript bridge to Music
│   ├── Lyrics/          Lyrics providers and LRC (timed lyrics) handling
│   ├── Metadata/        File tags, artwork and MusicBrainz lookups
│   ├── Checks/          Suggestions: synced lyrics, album star, year, genre
│   ├── UI/              Panel and settings window
│   └── Shared/          Models and text matching
├── Tests/StarmaniaTests/
└── docs/RELEASING.md    How versions and releases work
```

## Architecture

- **Swift Package Manager** executable with a SwiftUI + AppKit UI.
- `MusicObserver` talks to Music via AppleScript on a background queue. It listens for Music's `com.apple.Music.playerInfo` notification and polls every 4 s as a fallback; tracks are identified by Music's persistent ID.
- `NowPlayingController` owns lyrics and artwork, auto-fetch, bulk fetch and the deferred file-write queue.
- `SuggestionCenter` runs the checks for the playing song and album and applies or proposes changes.
- `MetadataWriter` reads and writes ID3 (via [ID3TagEditor](https://github.com/chicio/ID3TagEditor)) and MPEG-4 tags. `MusicBrainzClient` looks up albums, at most one request per second as MusicBrainz asks.
- Not sandboxed, because it writes file tags.

### Advanced: Genius

Genius is the last lyrics source in the Auto order. A key is included; if it stops working, create a client at [genius.com/api-clients](https://genius.com/api-clients) and paste its Client Access Token under Settings → Advanced.

## License

MIT — see [LICENSE](LICENSE).
