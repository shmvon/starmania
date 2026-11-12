# Changelog

All notable changes to Starmania. Versions follow `MAJOR.MINOR` (with `.PATCH` for small fixes):
a new major version changes how the app works, a minor one adds features, a patch only fixes things.

## [3.0.2] — 2026-11-12

### Fixed
- Year and genre changes that only differ in capitalisation ("dream pop" → "Dream Pop") were never written to Music.
- Year and genre changes waiting for the playing or next song are now written as soon as playback stops
  (not only on quit), and an older waiting value can no longer overwrite a newer one.

### Added
- A thin progress line over the bottom of the cover; hover to see elapsed and remaining time, click or drag to seek.
- Right-click the menu bar icon: favorite, dislike and rating of the playing song, with their shortcuts.
- A small clock on the Album page's year/genre line while a change is waiting for the playing or next song.

### Changed
- The song's favorite, dislike and rating are a tinted footer strip, set apart from the page controls.
- More space between the year/genre line and the track list.

## [3.0.1] — 2026-11-11

### Fixed
- The panel didn't open (it was sized 0 × 0).
- Playback stopped after a song ended or after setting the year or genre: Music rewrites a file whenever
  these change, so the playing song's changes now wait until the next song has played a few seconds,
  and songs that already have the value are skipped.
- Playback buttons only responded to clicks right on the symbol.
- Playback could stop at the end of a song, with Next not responding, after the album's tags changed:
  the next song, which Music loads early for gapless playback, is now left alone like the playing one.

### Changed
- Fetch / Write / Copy buttons removed: missing lyrics and artwork are now checks (Off / Propose / Automate);
  copy, fetch again, save and delete are in the right-click menu of the cover and lyrics.
- The cover can be dragged out as a PNG file.
- Alternative genres sit next to the current genre.
- No gear button (right-click the menu bar icon) and no dot next to the menu bar star.
- Song ratings moved to the bottom of the panel; a small gap between the menu bar and the panel.
- Page tabs are plain icons like the playback controls; the current page is filled.
- Album page is more compact: year and genres on one line (genres scroll sideways), no headings,
  checkmarks or divider; the "N of M songs favorited" count is the album star's tooltip.

### Added
- A shortcut to show the panel (Settings → Shortcuts).

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

[3.0.1]: https://github.com/shmvon/starmania/releases/tag/v3.0.1
[3.0]: https://github.com/shmvon/starmania/releases/tag/v3.0
[2.0]: https://github.com/shmvon/starmania/releases/tag/v2.0
[1.0]: https://github.com/shmvon/starmania/releases/tag/v1.0
