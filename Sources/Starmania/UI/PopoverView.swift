import SwiftUI
import AppKit

/// Panel state owned by the app delegate: visibility and the ⌥ key (sampled only while visible).
@MainActor
final class PanelState: ObservableObject {
    @Published var isVisible = false
    @Published var isOptionPressed = false
}

enum PanelMetrics {
    static let width: CGFloat = 300
    static let padding: CGFloat = 10
    /// Every page has the same height: the cover is square at full width.
    static let pageHeight: CGFloat = width - 2 * padding
    static let lyricsFontSize: CGFloat = 12.5
}

// MARK: - Main Popover View

/// Song title, then one page at a time: Cover, Lyrics, or Album (album rating, year, genre,
/// lookups and the album/playlist track list), the page tabs, and the song ratings at the bottom.
struct PopoverView: View {
    @ObservedObject private var music = MusicObserver.shared
    @ObservedObject private var controller = NowPlayingController.shared
    @ObservedObject private var checks = SuggestionCenter.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject var panel: PanelState

    @State private var showPlaybackControls = false
    /// Per-track override of the "prefer synced lyrics" setting; reset on track change.
    @State private var syncedOverride: Bool?

    // Album / playlist list state
    @State private var playlistTracks: [PlaylistTrackInfo] = []
    @State private var playlistIsAlbum = true
    @State private var playlistLoading = false
    @State private var playlistRequestID = UUID()

    private let width = PanelMetrics.width
    private let pad = PanelMetrics.padding
    private let pageHeight = PanelMetrics.pageHeight

    private var page: PanelPage { settings.settings.panelPage }

    var body: some View {
        VStack(spacing: 0) {
            if let track = music.currentTrack {
                trackView(track)
            } else if music.musicRunning {
                emptyState("No track playing", icon: "pause.circle", actionTitle: "Play Music") {
                    music.play()
                }
            } else {
                emptyState("Music not running", icon: "music.note", actionTitle: "Open Apple Music") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    }
                }
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)  // Size to content, don't stretch
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: music.currentTrack?.trackKey) { _, _ in
            syncedOverride = nil
            if page == .album { loadPlaylist() }
        }
        .onChange(of: panel.isVisible) { _, visible in
            if visible && page == .album { loadPlaylist() }
        }
        .onChange(of: page) { _, newPage in
            if newPage == .album { loadPlaylist() }
        }
    }

    // MARK: - Track View

    @ViewBuilder
    private func trackView(_ track: TrackInfo) -> some View {
        VStack(spacing: 0) {
        VStack(spacing: 6) {
            trackInfo(track)
                .padding(.top, pad)
                .padding(.horizontal, pad)

            if !checks.suggestions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(checks.suggestions) { suggestionCard($0) }
                }
                .padding(.horizontal, pad)
                .transition(.opacity)
            }

            Group {
                switch page {
                case .cover: artworkView(track)
                case .lyrics: lyricsPage(track)
                case .album: albumPage(track)
                }
            }
            .frame(width: width - 2 * pad, height: pageHeight)
            .overlay(alignment: .bottom) { statusBadge() }

            tabBar(track)
                .padding(.horizontal, pad)
                .padding(.bottom, 4)
        }

        // The song's own ratings: a footer strip, set apart from the page and its controls
        ratingBar(track)
            .padding(.horizontal, pad + 2)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            }
        }
        .animation(.default, value: checks.suggestions.map(\.id))
    }

    // MARK: - Rating Bar (song)

    private func ratingBar(_ track: TrackInfo) -> some View {
        HStack(spacing: 12) {
            Button(action: { music.setFavorited(!track.favorited) }) {
                Image(systemName: track.favorited ? "heart.fill" : "heart")
                    .font(.system(size: 16))
                    .foregroundStyle(track.favorited ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help("Favorite (⌃⌥F)")

            Button(action: { music.setDisliked(!track.disliked) }) {
                Image(systemName: track.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 15))
                    .foregroundStyle(track.disliked ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Dislike (⌃⌥D)")

            Spacer()

            starButtons(rating: track.rating, size: 15, spacing: 4, help: { "Rate \($0) (⌃⌥\($0))" }) { star in
                music.setRating(track.rating == star ? 0 : star)
            }
        }
    }

    private func starButtons(rating: Int, size: CGFloat, spacing: CGFloat, dimmed: Bool = false,
                             help: @escaping (Int) -> String, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { star in
                Button(action: { action(star) }) {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= rating ? Color.yellow.opacity(dimmed ? 0.5 : 1) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(help(star))
            }
        }
    }

    private func trackInfo(_ track: TrackInfo) -> some View {
        VStack(spacing: 1) {
            Text(track.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                if !track.isLocal {
                    Image(systemName: track.isCloudOnly ? "icloud" : "cloud")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(track.storageDescription)
                }
                Text(track.album.isEmpty ? track.artist : "\(track.artist) — \(track.album)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .help("\(track.name)\n\(track.artist)\n\(track.album)")
    }

    // MARK: - Suggestions

    private func suggestionCard(_ suggestion: Suggestion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: suggestion.kind))
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(suggestion.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(suggestion.applyTitle) { checks.apply(suggestion) }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button(action: { checks.dismiss(suggestion) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss — won't be suggested again")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
    }

    private func icon(for kind: Suggestion.Kind) -> String {
        switch kind {
        case .lyrics: return "quote.bubble"
        case .artwork: return "photo"
        case .syncedLyrics: return "waveform"
        case .albumStar: return "star.circle"
        case .year: return "calendar"
        case .genre: return "guitars"
        }
    }

    // MARK: - Cover Page

    private func artworkView(_ track: TrackInfo) -> some View {
        let size = pageHeight
        return ZStack {
            if let data = track.artworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        if controller.artworkLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 36))
                                .foregroundStyle(.quaternary)
                        }
                    }
            }

            if showPlaybackControls {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.4))
                    .frame(width: size, height: size)

                HStack(spacing: 26) {
                    Button(action: { music.previousTrack() }) {
                        Image(systemName: "backward.fill").font(.system(size: 20)).foregroundStyle(.white)
                    }.buttonStyle(.plain)

                    Button(action: { music.playPause() }) {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).foregroundStyle(.white)
                    }.buttonStyle(.plain)

                    Button(action: { music.nextTrack() }) {
                        Image(systemName: "forward.fill").font(.system(size: 20)).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if track.duration > 0 {
                ProgressScrubber(track: track, expanded: showPlaybackControls) { music.seek(to: $0) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, showPlaybackControls ? 8 : 6)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                showPlaybackControls = hovering
            }
        }
        .onDrag { artworkDragItem(track) }
        .contextMenu { artworkMenu(track) }
    }

    @ViewBuilder
    private func artworkMenu(_ track: TrackInfo) -> some View {
        Button("Copy Artwork", action: controller.copyArtwork)
            .disabled(track.artworkData == nil)
        Button("Fetch Artwork", action: controller.fetchArtwork)
            .disabled(controller.artworkLoading)
        Button(track.isLocal ? "Save Artwork to File" : "Save Artwork in Music", action: controller.writeArtworkToFile)
            .disabled(track.artworkData == nil || !controller.artworkUnsaved)
        Divider()
        Button("Delete Artwork", role: .destructive, action: controller.deleteArtwork)
            .disabled(track.artworkData == nil)
    }

    /// Dragging the cover gives a PNG file named after the album (to Finder, Mail, editors, …).
    private func artworkDragItem(_ track: TrackInfo) -> NSItemProvider {
        guard let data = track.artworkData, let image = NSImage(data: data) else { return NSItemProvider() }
        let name = "\(track.artist) - \(track.album)".replacingOccurrences(of: "[/:\\\\]", with: "_", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil,
           let provider = NSItemProvider(contentsOf: url) {
            provider.suggestedName = name
            return provider
        }
        return NSItemProvider(object: image)
    }

    // MARK: - Lyrics Page

    private var hasSyncedLyrics: Bool { !controller.syncedLines.isEmpty }
    private var showSynced: Bool { hasSyncedLyrics && (syncedOverride ?? settings.settings.preferSyncedLyrics) }

    private func lyricsPage(_ track: TrackInfo) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(lyricsHeaderTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if hasSyncedLyrics {
                    Button(action: { syncedOverride = !showSynced }) {
                        Image(systemName: showSynced ? "text.alignleft" : "waveform")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showSynced ? "Show plain lyrics" : "Show synced lyrics")
                }
            }

            Group {
                if controller.lyricsLoading {
                    ProgressView("Fetching...")
                        .font(.system(size: 11))
                } else if let error = controller.lyricsError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else if showSynced {
                    syncedLyricsView()
                } else if !controller.lyrics.isEmpty {
                    ScrollView {
                        Text(controller.lyrics)
                            .font(.system(size: PanelMetrics.lyricsFontSize))
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No lyrics")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .contextMenu { lyricsMenu(track) }
    }

    @ViewBuilder
    private func lyricsMenu(_ track: TrackInfo) -> some View {
        let hasLyrics = !controller.lyrics.isEmpty
        Button("Copy Lyrics") { controller.copyLyrics() }
            .disabled(!hasLyrics)
        if controller.syncedLyricsText != nil {
            Button("Copy Lyrics with Timing") { controller.copyLyrics(withTiming: true) }
        }
        Button(hasLyrics ? "Fetch Lyrics Again" : "Fetch Lyrics", action: controller.fetchLyrics)
            .disabled(controller.lyricsLoading)
        Button(track.isLocal ? "Save Lyrics to File" : "Save Lyrics in Music", action: controller.writeLyricsToFile)
            .disabled(!controller.lyricsUnsaved)
        Divider()
        Button("Delete Lyrics", role: .destructive, action: controller.deleteLyrics)
            .disabled(controller.lyricsSource != .embedded)
    }

    private var lyricsHeaderTitle: String {
        guard let source = controller.lyricsSource else { return "LYRICS" }
        let synced = hasSyncedLyrics ? ", SYNCED" : ""
        return "LYRICS (\(source.displayName.uppercased())\(synced))"
    }

    /// Time-synced lyrics: highlights the current line and keeps it centered. Empty timed
    /// lines end the highlight; they show as a stanza gap, or as nothing when they only mark line ends.
    private func syncedLyricsView() -> some View {
        let lines = controller.syncedLines
        let emptyCount = lines.filter { $0.text.isEmpty }.count
        let emptyGap: CGFloat = Double(emptyCount) >= Double(lines.count) * 0.4 ? 0 : 8

        return TimelineView(.animation(minimumInterval: 0.25, paused: !panel.isVisible)) { context in
            let time = music.currentTrack?.estimatedPosition(at: context.date) ?? 0
            let currentIndex = LRCParser.currentLineIndex(in: lines, at: time)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            if line.text.isEmpty {
                                Color.clear.frame(height: emptyGap).id(line.id)
                            } else {
                                let isCurrent = line.id == currentIndex
                                Text(line.text)
                                    .font(.system(size: PanelMetrics.lyricsFontSize, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2.5)
                                    .id(line.id)
                            }
                        }
                    }
                    .padding(.vertical, pageHeight / 2 - 20)  // Lets the first and last lines reach the center
                }
                .onChange(of: currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    if let currentIndex {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Album Page

    private func albumPage(_ track: TrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            albumHeader(track)
            albumFacts(track)
                .padding(.bottom, 6)
            playlistSection()
        }
    }

    private func albumHeader(_ track: TrackInfo) -> some View {
        HStack(spacing: 8) {
            Button(action: { music.setAlbumFavorited(!track.albumFavorited) }) {
                Image(systemName: track.albumFavorited ? "star.fill" : "star")
                    .font(.system(size: 24))
                    .foregroundStyle(track.albumFavorited ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(albumStarHelp(track))

            VStack(alignment: .leading, spacing: 1) {
                Text(track.album.isEmpty ? "No album" : track.album)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(track.albumArtist.isEmpty ? track.artist : track.albumArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            starButtons(rating: track.albumRating, size: 12, spacing: 2, dimmed: track.albumRatingComputed,
                        help: { "Rate album \($0)" }) { star in
                let isUserRating = !track.albumRatingComputed
                music.setAlbumRating(isUserRating && track.albumRating == star ? 0 : star)
            }
            .help(track.albumRatingComputed ? "Album rating (computed by Music from the song ratings)" : "Album rating")
        }
    }

    /// One line: year (with the file tag's and MusicBrainz's if they differ), then the genre and the
    /// other MusicBrainz genres to pick from, scrolling sideways, then the lookup button.
    private func albumFacts(_ track: TrackInfo) -> some View {
        let facts = checks.albumFacts
        let others = (facts?.genres ?? []).prefix(6)
            .map(GenreMatching.displayName)
            .filter { TextMatching.normalizeForMatching($0) != TextMatching.normalizeForMatching(track.genre) }
        return HStack(spacing: 5) {
            Text(track.year > 0 ? "\(track.year)" : "—")
                .font(.system(size: 11, weight: .medium))
                .help("Year")
            if let tagYear = track.fileTags?.year, tagYear != track.year {
                Text("tag \(tagYear)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("The file's tag says \(tagYear)")
            }
            if let year = facts?.year, year != track.year {
                chip("→ \(year)", selected: false) { music.setAlbumYear(year) }
                    .help("Original release year on MusicBrainz — click to set it on the whole album")
            }

            Text("·").foregroundStyle(.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if track.genre.isEmpty {
                        Text("No genre")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        chip(track.genre, selected: true) {}
                            .help("Genre")
                    }
                    ForEach(others, id: \.self) { name in
                        chip(name, selected: false) { music.setAlbumGenre(name) }
                            .help("MusicBrainz genre — click to set it on the whole album")
                    }
                }
            }

            if music.pendingEdits[track.persistentID] != nil || music.pendingEdits[track.nextPersistentID] != nil {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("The rest of the album is updated. This song and the next get the change once they're no longer playing or up next, because Music rewrites the file and would interrupt playback.")
            }

            lookupControl(facts)
        }
    }

    private func albumStarHelp(_ track: TrackInfo) -> String {
        let action = track.albumFavorited ? "Click to unstar the album" : "Click to star the album"
        guard let stats = checks.albumStats, stats.trackCount > 0 else { return action }
        let s = settings.settings
        let count = stats.qualifying(s.albumStarCriterion, minRating: s.albumStarMinRating)
        return "\(albumStarCaption(count: count, total: stats.trackCount))\n\(action)"
    }

    private func albumStarCaption(count: Int, total: Int) -> String {
        let s = settings.settings
        let what: String
        switch s.albumStarCriterion {
        case .favorited: what = "favorited"
        case .rated: what = "rated \(s.albumStarMinRating)★+"
        case .either: what = "favorited or \(s.albumStarMinRating)★+"
        }
        let auto = s.albumStarMode == .off ? "" : " · album star at \(s.albumStarThreshold)"
        return "\(count) of \(total) songs \(what)\(auto)"
    }

    @ViewBuilder
    private func lookupControl(_ facts: AlbumFacts?) -> some View {
        if checks.albumLookupLoading {
            ProgressView().controlSize(.mini)
        } else if let url = facts?.url {
            Button(action: { NSWorkspace.shared.open(url) }) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open on MusicBrainz")
        } else {
            Button(action: { checks.lookUpCurrentAlbum() }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(checks.albumLookupError ?? "Look up year and genre on MusicBrainz")
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Album / Playlist List

    private func playlistSection() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if playlistLoading && playlistTracks.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlistTracks.isEmpty {
                Text("No album or playlist available")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(playlistTracks) { track in
                                playlistRow(track)
                                    .id(track.id)
                                if track.id != playlistTracks.last?.id {
                                    Divider().padding(.leading, 6)
                                }
                            }
                        }
                        .padding(.trailing, 8)  // Gutter for the scroller
                    }
                    .onAppear { scrollToCurrent(proxy) }
                    .onChange(of: playlistTracks.first(where: \.isCurrentTrack)?.id) { _, _ in
                        scrollToCurrent(proxy)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = playlistTracks.first(where: { $0.isCurrentTrack }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo(current.id, anchor: .center)
            }
        }
    }

    private func playlistRow(_ track: PlaylistTrackInfo) -> some View {
        let isCurrent = track.isCurrentTrack
        let isFav = isCurrent ? (music.currentTrack?.favorited ?? track.favorited) : track.favorited
        let isDis = isCurrent ? (music.currentTrack?.disliked ?? track.disliked) : track.disliked
        let currentRating = isCurrent ? (music.currentTrack?.rating ?? track.rating) : track.rating
        let rowWidth = width - 2 * pad - 8 - 12  // Minus scroller gutter and row padding

        return HStack(spacing: 0) {
            // Left: song title (click to play, marquee on hover)
            Button(action: { music.playTrack(id: track.id) }) {
                MarqueeText(text: track.name, font: .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(width: rowWidth * 0.46, alignment: .leading)

            // Right: rating controls
            HStack(spacing: 2) {
                Button(action: {
                    let nextFav = !isFav
                    music.setFavorited(nextFav, trackID: track.id)
                    refreshTrackInPlaylist(track.id, favorited: nextFav, disliked: nextFav ? false : isDis)
                }) {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 12))
                        .foregroundStyle(isFav ? .pink : .secondary)
                        .frame(width: 15, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: {
                    let nextDis = !isDis
                    music.setDisliked(nextDis, trackID: track.id)
                    refreshTrackInPlaylist(track.id, favorited: nextDis ? false : isFav, disliked: nextDis)
                }) {
                    Image(systemName: isDis ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 11))
                        .foregroundStyle(isDis ? .red : .secondary)
                        .frame(width: 15, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer().frame(width: 4)

                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        let newRating = currentRating == star ? 0 : star
                        music.setRating(newRating, trackID: track.id)
                        refreshTrackInPlaylist(track.id, rating: newRating)
                    }) {
                        Image(systemName: star <= currentRating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(star <= currentRating ? .yellow : .secondary.opacity(0.45))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: rowWidth * 0.54, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    // MARK: - Status and Tabs

    /// Short confirmations ("Lyrics → File ✓") float over the bottom of the page.
    @ViewBuilder
    private func statusBadge() -> some View {
        Group {
            if let progress = controller.bulkProgress {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(progress).lineLimit(1)
                    Button("Stop") { controller.cancelBulkFetch() }
                        .buttonStyle(.borderless)
                }
            } else if let msg = controller.statusMessage {
                Text(msg)
                    .foregroundStyle(controller.statusIsError ? .red : .primary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.regularMaterial))
        .opacity(controller.bulkProgress != nil || controller.statusMessage != nil ? 1 : 0)
        .padding(.bottom, 6)
        .animation(.default, value: controller.statusMessage)
        .allowsHitTesting(controller.bulkProgress != nil)
    }

    private func tabBar(_ track: TrackInfo) -> some View {
        HStack(spacing: 6) {
            // Plain icons like the playback controls; the current page's is filled and brighter
            HStack(spacing: 0) {
                tabButton(.cover, icon: "photo", help: "Cover")
                tabButton(.lyrics, icon: "quote.bubble", help: "Lyrics")
                tabButton(.album, icon: "square.stack", help: "Album: rating, year, genre and tracks",
                          badge: checks.suggestions.contains { $0.kind.isAlbumLevel })
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                mediaButton("backward.fill", size: 11, help: "Previous") { music.previousTrack() }
                mediaButton(track.isPlaying ? "pause.fill" : "play.fill", size: 13, help: track.isPlaying ? "Pause" : "Play") { music.playPause() }
                mediaButton("forward.fill", size: 11, help: "Next") { music.nextTrack() }
            }
        }
    }

    /// The whole 28×26 pt square is clickable, not just the glyph.
    private func mediaButton(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func tabButton(_ target: PanelPage, icon: String, help: String, badge: Bool = false) -> some View {
        let selected = page == target
        return Button(action: { settings.settings.panelPage = target }) {
            Image(systemName: selected ? icon + ".fill" : icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 26)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 4).padding(.trailing, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Empty State

    private func emptyState(_ message: String, icon: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let title = actionTitle, let act = action {
                Button(action: act) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .padding(.top, 4)
            }
        }
        .frame(width: width, height: 120)
    }

    // MARK: - Playlist Helpers

    private func loadPlaylist() {
        let requestID = UUID()
        playlistRequestID = requestID
        playlistLoading = true
        Task {
            let result = await music.fetchPlaylistTracks()
            guard playlistRequestID == requestID else { return }
            playlistTracks = result.tracks
            playlistIsAlbum = result.isAlbum
            playlistLoading = false
        }
    }

    /// Optimistically update a track in the local playlist array for instant UI feedback.
    private func refreshTrackInPlaylist(_ trackId: String, favorited: Bool? = nil, disliked: Bool? = nil, rating: Int? = nil) {
        guard let idx = playlistTracks.firstIndex(where: { $0.id == trackId }) else { return }
        if let fav = favorited { playlistTracks[idx].favorited = fav }
        if let dis = disliked { playlistTracks[idx].disliked = dis }
        if let rat = rating { playlistTracks[idx].rating = rat }
    }
}

// MARK: - Marquee Text (horizontal scroll on hover)

// MARK: - Progress Scrubber

/// The song's progress, laid over the bottom of the cover: a thin line, which grows and shows
/// the elapsed and remaining time while the pointer is over the cover. Click or drag to seek.
struct ProgressScrubber: View {
    let track: TrackInfo
    let expanded: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(track.duration, 0.1)
            let fraction = dragFraction ?? min(1, max(0, track.estimatedPosition(at: context.date) / duration))
            let barHeight: CGFloat = expanded || dragFraction != nil ? 4 : 2.5

            VStack(spacing: 2) {
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        Capsule().fill(Color.white.opacity(0.92))
                            .frame(width: width * fraction)
                    }
                    .frame(height: barHeight)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = Self.clamp($0.location.x / width) }
                            .onEnded { value in
                                onSeek(Self.clamp(value.location.x / width) * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 12)

                if expanded {
                    HStack {
                        Text(Self.format(fraction * duration))
                        Spacer()
                        Text("-" + Self.format(duration - fraction * duration))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: barHeight)
        }
        .help(expanded ? "" : "Song progress")
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    nonisolated static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MarqueeText: View {
    let text: String
    let font: NSFont

    @State private var isHovering: Bool = false
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var needsScroll: Bool { textWidth > containerWidth && containerWidth > 0 }

    var body: some View {
        GeometryReader { geo in
            let swiftFont = Font.system(size: font.pointSize, weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)

            Text(text)
                .font(swiftFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear {
                            textWidth = textGeo.size.width
                        }
                        .onChange(of: text) { _, _ in
                            textWidth = textGeo.size.width
                            offset = 0
                        }
                    }
                )
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newVal in containerWidth = newVal }
        }
        .frame(height: font.pointSize + 4)
        .clipped()
        .onHover { hovering in
            isHovering = hovering
            if hovering && needsScroll {
                let scrollDistance = textWidth - containerWidth
                withAnimation(.linear(duration: Double(scrollDistance) / 30.0)) {
                    offset = -scrollDistance
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    offset = 0
                }
            }
        }
    }
}
