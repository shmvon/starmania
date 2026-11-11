# Changelog

All notable changes to Starmania. Versions follow `MAJOR.MINOR` (with `.PATCH` for small fixes):
a new major version changes how the app works, a minor one adds features, a patch only fixes things.

## [3.0] — 2026-11-11

### Added
- Timed (LRC) lyrics in file tags are detected and shown highlighted line by line; `[offset:]` is supported.
- Plain lyrics can be upgraded to a timed version from LRCLIB / Lyrica, only when at least 75% of the words match.
- Album page: big star to favorite the album, album rating, year and genre, and the album/playlist tracks.
- Year and genre check against MusicBrainz (original release year, community genres), applied to the whole album.
- Automatic album star once enough songs are favorited or rated highly (configurable count and rule).
- Each check can be Off, Propose (pulsing icon, suggestion cards with Apply / Dismiss) or Automate.
- `build.sh --no-dialog / --install / --suffix / --zip`; `test.sh`; `VERSION` file; this changelog.

### Changed
- The panel shows one page at a time (Cover, Lyrics, Album) under the song ratings, so it's much shorter.
- Panel width 300 pt; lyrics at 12.5 pt.
- Lyrics and year are read from the file's own tags for local tracks.
- Genius moved to Settings → Advanced; the lyrics provider menu moved to the Settings window.
- Sources are grouped in folders (App, Music, Lyrics, Metadata, Checks, UI, Shared).
- `build.sh` picks a working SDK on any Mac instead of a fixed one, and stamps the version and build number.

## [2.0] — 2026-10-26

### Added
- Multi-provider lyrics (LRCLIB / Lyrica, SongLyrics.com, Genius) with validated matches.
- Synced lyrics from LRCLIB, global rating shortcuts, Settings window, launch at login.
- Bulk fetch of missing lyrics and artwork for the current album or playlist.

### Changed
- All Music scripting moved off the main thread; tracks are identified by persistent ID.
- File writes for the playing song are deferred until the song changes.

## [1.0] — 2026-05-23

First version: menu bar rating icon, favorite / dislike / 5-star rating, artwork and Genius lyrics,
album/playlist list.

[3.0]: https://github.com/shmvon/starmania/releases/tag/v3.0
[2.0]: https://github.com/shmvon/starmania/releases/tag/v2.0
[1.0]: https://github.com/shmvon/starmania/releases/tag/v1.0
