# Starmania ★

A macOS menu bar app for managing Apple Music song metadata — star ratings, favorites, artwork, and lyrics.

![Starmania Icon](Sources/Starmania/Resources/AppIcon.png)

## Features

- **Menu bar icon** showing star rating (★³), favorite status (solid/empty), and dislike indicator (●)
- **Interactive popover** with:
  - ♡ Favorite and 👎 Dislike toggles (writes back to Apple Music)
  - ★★★★★ 5-star rating (writes back to Apple Music)
  - Album artwork with hover playback controls (prev/play-pause/next)
  - Scrollable lyrics display (embedded or fetched from Genius)
- **Lyrics** — reads embedded lyrics from song files, fetches from Genius.com API
- **Artwork** — fetches high-res artwork from iTunes Search API
- **Write to ID3** — writes lyrics and artwork to local song file tags
- **Copy to clipboard** — copy lyrics as text or artwork as image
- **Settings** (⌥-click or right-click the icon):
  - Auto-fetch lyrics / artwork
  - Auto-write lyrics / artwork to file
  - Genius API key management

## Requirements

- macOS 14.0+
- Swift 5.9+
- A [Genius API](https://genius.com/api-clients) client access token (optional, a default one is pre-configured for lyrics fetching)

## Build & Run

```bash
# Clone
git clone https://github.com/shmvon/starmania.git
cd starmania

# Build
swift build

# Package into .app bundle
mkdir -p Starmania.app/Contents/MacOS Starmania.app/Contents/Resources
cp .build/debug/Starmania Starmania.app/Contents/MacOS/
cp Info.plist Starmania.app/Contents/

# Run
open Starmania.app
```

## Genius API Setup (Optional)

Starmania comes pre-configured with a default Genius API key. If you reach the rate limit or prefer to use your own:

1. Go to [genius.com/api-clients](https://genius.com/api-clients)
2. Create a new API client (use `https://github.com/shmvon/starmania` as app URL)
3. Copy the **Client Access Token**
4. Click the gear icon (⚙) in the Starmania lyrics panel → "Set API Key..." → paste

## Architecture

- **Swift Package Manager** executable with SwiftUI + AppKit hybrid
- Non-sandboxed for full file system access (needed for ID3 tag writing)
- AppleScript bridge for Apple Music communication
- Dependencies: [ID3TagEditor](https://github.com/chicio/ID3TagEditor), [SwiftSoup](https://github.com/scinfu/SwiftSoup)

## License

MIT
