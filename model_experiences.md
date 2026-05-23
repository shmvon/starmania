# Assessment: Auto-Write Lyrics to File (ID3 Tag) Not Working

## Brief Summary

- Initial assessment: the auto-write toggle was not being honored in the lyrics fetch flow, and the low-level file metadata writer had originally been stubbed out.
- Follow-up assessment: even after wiring the toggle into the fetch path, automatic behavior could still diverge from the manual "Write Lyrics" path because the async fetch/write sequence depended on mutable current-track state.
- Steps taken: refactored the lyrics flow in `PopoverView.swift` so fetches are tied to the track they started for, stale requests are ignored when the track changes, and automatic writes call the same `writeLyricsToFile(...)` path as the manual button.
- Final adjustment: removed an extra guard that blocked auto-write based on existing file-tag detection, because it made automatic writes stricter than the intended product behavior.
- Verification note: source changes were applied, but full runtime verification was limited by a local Swift toolchain/SDK mismatch in the environment.

## Follow-Up Summary

- Root cause refinement: the remaining auto-write failure was caused by logic that still treated automatic writes differently from manual writes. In particular, fetched lyrics were only auto-written when low-level file-tag inspection claimed the file had no lyrics, which could suppress the write entirely even though the manual button worked.
- Behavior correction: removed the auto-write gate based on `MetadataWriter.checkExistingMetadata(...)` for fetched lyrics, and removed the extra path that auto-wrote embedded Apple Music lyrics on track change. The feature now matches the intended rule more closely: fetch only when the song has no lyrics or when explicitly requested, and auto-write only the fetched lyrics when that setting is enabled.
- UI adjustment: the lyrics-box gear icon was made permanently visible by moving the lyrics header outside the lyrics-content conditional branches, so settings remain accessible whether lyrics are loaded, missing, loading, or in an error state.
- Build verification: local build products in `.build` were cleared while keeping package checkouts, then a fresh build was completed successfully using a temporary scratch path in `/private/tmp` to avoid a Google Drive-backed `build.db` I/O issue.

## Playback Interruption Summary

- New finding: the remaining playback bug was caused by rewriting the currently selected audio file while Apple Music was actively using it. That explained both symptoms: auto-written lyrics stopping the next song a couple of seconds after it started, and manual file writes causing the current track to disappear entirely.
- Fix applied: lyrics are still written to Apple Music immediately, but the on-disk lyrics tag write is now deferred whenever the target file is the current active track. Deferred writes are flushed as soon as the track changes or no track is active, which avoids interrupting playback while still keeping the file metadata in sync.
- Root cause refinement: the interruption still persisted because local-track writes were also calling `music.setLyrics(...)` on the active track before the deferred file logic ran. That Apple Music metadata update itself was enough to drop playback and clear the current track.
- Final playback fix: local tracks now use the file write path only, while `music.setLyrics(...)` is retained only for non-local tracks. The UI state is updated locally so the app still reflects the lyrics change immediately without asking Music.app to rewrite the currently playing item.

## App Overview

**Starmania** — A macOS menu-bar app (SwiftUI + Swift) that polls Apple Music for the currently playing track, fetches lyrics from Genius, and writes lyrics/artwork back to the song's metadata (Apple Music database + file ID3 tags).

## The Bug Report

> "The app has an option to automatically write the fetched lyrics to the file (ID3Tag). However, this doesn't work. Everything else works fine."

Confirmed: manual "Write Lyrics" button works, manual "Fetch Lyrics" works, auto-fetch works. Only the **auto-write** feature fails.

## Root Causes Found

### Bug 1: `autoWriteLyrics` setting was never checked (trigger missing)

**File:** `Sources/Starmania/PopoverView.swift`

The settings menu (`Starmania.swift:259`) has a toggle `"Auto-write Lyrics to File"` that toggles `SettingsManager.shared.settings.autoWriteLyrics`, and the value is persisted. However, **no code ever read this flag**. After fetching lyrics (via Genius), the code path never asked "should I auto-write these lyrics?".

The original flow (`onTrackChanged` → `fetchLyrics`) was:
1. `onTrackChanged()` detected no embedded lyrics
2. Called `fetchLyrics()` (which creates an unstructured `Task`)
3. `fetchLyrics()`'s internal `Task` called Genius API, set `self.lyrics = result.lyrics`
4. Returned — **no auto-write check anywhere**

The `autoWriteLyrics` flag was a dead toggle — turning it on had zero effect.

### Bug 2: `writeID3` / `writeMP4` were empty stubs (write implementation missing)

**File:** `Sources/Starmania/MetadataWriter.swift`

The `writeToFile()` method dispatches to `writeID3()` for `.mp3` and `writeMP4()` for `.m4a`/`.aac`. Both were:

```swift
private func writeID3(filePath: String, lyrics: String?, artworkData: Data?) throws {
    print("[Starmania] ID3 writing not yet implemented")  // ← STUB
}

private func writeMP4(filePath: String, lyrics: String?, artworkData: Data?) throws {
    print("[Starmania] MP4 writing not yet implemented")  // ← STUB
}
```

Even if auto-write was triggered, the file on disk was never modified. The `ID3TagEditor` package (version 4.6.0) was declared in `Package.swift` but **never imported or used**.

Similarly, `checkExistingMetadata()` was a stub returning `(false, false)`.

## Fix Applied

### Fix 1: Refactored fetch flow to include auto-write (PopoverView.swift)

The original `fetchLyrics()` was a single function that both:
- Was called from the "Fetch Lyrics" button
- Was called from `onTrackChanged()` (auto-fetch path)

It created its own unstructured `Task` internally, so `onTrackChanged` could not coordinate "fetch complete → auto-write" timing.

**Refactored into three pieces:**

```swift
// (1) Auto-path: onTrackChanged detects no lyrics, starts a Task that:
//     - await fetchLyrics(title:artist:) → Bool
//     - then checks autoWriteLyrics → writeLyricsToFile(track)
private func onTrackChanged() {
    ...
    if settings.settings.autoFetchLyrics && settings.hasGeniusKey {
        Task {
            let ok = await fetchLyrics(title: ..., artist: ...)
            if ok, settings.settings.autoWriteLyrics, let track = music.currentTrack {
                writeLyricsToFile(track)
            }
        }
    }
}

// (2) Manual button path: same pattern
private func fetchLyrics() {  // called by "Fetch Lyrics" button
    ...
    Task {
        let ok = await fetchLyrics(title: track.name, artist: track.artist)
        if ok, settings.settings.autoWriteLyrics, let track = music.currentTrack {
            writeLyricsToFile(track)
        }
    }
}

// (3) Shared async implementation
private func fetchLyrics(title: String, artist: String) async -> Bool {
    // Does the Genius API call
    // Sets @State on MainActor
    // Returns true on success
}
```

**Key design:** The auto-write check now runs in the **same sequential `Task`** as the fetch — immediately after `await` returns. No timing ambiguity, no coordination problem.

### Fix 2: Implemented ID3/MP4 writing (MetadataWriter.swift)

`writeID3` — now uses the `ID3TagEditor` library:
- Reads existing ID3 tag (preserves all existing metadata)
- Removes old lyrics/artwork frames
- Adds new `unsynchronizedLyrics(.eng)` and `attachedPicture(.frontCover)` frames
- Writes back via `editor.write(tag:to:)`

```swift
let editor = ID3TagEditor()
let existingTag = try? editor.read(from: filePath)
var frames = existingTag?.frames ?? [:]

// Set/remove lyrics + artwork frames as needed

let tag = ID32v3TagBuilder().title(frame: ...).build()
tag.frames = frames
try editor.write(tag: tag, to: filePath)
```

`writeMP4` — uses AVFoundation `AVAssetExportSession` with passthrough:
- Preserves existing metadata (filters out old lyrics/cover art)
- Adds new `iTunesMetadataLyrics` and `iTunesMetadataCoverArt` items
- Exports to temp file, replaces original

`checkExistingMetadata` — also implemented for both formats (reads tag/metadata).

## Files Modified

| File | Lines Changed | What |
|---|---|---|
| `Sources/Starmania/PopoverView.swift` | 395–469 | Refactored `onTrackChanged`, `fetchLyrics()` into 3-method async flow; added `autoWriteLyrics` check in both auto and manual paths |
| `Sources/Starmania/MetadataWriter.swift` | Entirely rewritten (67–222) | Implemented `writeID3`, `writeMP4`, `checkID3Metadata`, `checkMP4Metadata`, plus helpers |

## Questions / Unknowns

1. **Does the auto-write now actually work end-to-end?** The user reports the previous fix attempt still didn't work. The current refactoring (moving auto-write into the same `Task` as the fetch, making it a proper sequential async flow) should resolve timing/coordination issues, but needs testing.

2. **Does `ID32v3TagBuilder.build()` produce a tag whose `frames` can be replaced via `tag.frames = ...`?** The `ID3Tag` initializer is internal (not public), so we build a dummy tag and reassign its `frames` property (which is `public lazy var`). The write method uses `tag.frames` to construct the binary ID3 data, so this should work.

3. **`AVAssetExportSession` with passthrough + metadata** — this should work for M4A files but depends on the codec being compatible with passthrough. It may fail for some files.
