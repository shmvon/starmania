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
    static let actionRowHeight: CGFloat = 22
}

// MARK: - Main Popover View

/// Song ratings on top, then one page at a time: Cover, Lyrics, or Album (album rating,
/// year, genre, lookups and the album/playlist track list).
struct PopoverView: View {
    @ObservedObject private var music = MusicObserver.shared
    @ObservedObject private var controller = NowPlayingController.shared
    @ObservedObject private var checks = SuggestionCenter.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject var panel: PanelState
    let onShowSettingsMenu: () -> Void

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
        VStack(spacing: 6) {
            ratingBar(track)
                .padding(.top, pad)
                .padding(.horizontal, pad)

            trackInfo(track)
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
                case .lyrics: lyricsPage()
                case .album: albumPage(track)
                }
            }
            // The Album page has no action row; it takes that space so switching pages doesn't resize the panel
            .frame(width: width - 2 * pad, height: page == .album ? pageHeight + PanelMetrics.actionRowHeight + 6 : pageHeight)

            if page != .album {
                actionRow(track)
                    .frame(height: PanelMetrics.actionRowHeight)
                    .padding(.horizontal, pad)
            }

            statusLine()
                .padding(.horizontal, pad)

            tabBar(track)
                .padding(.horizontal, pad)
                .padding(.bottom, 8)
        }
        .animation(.default, value: checks.suggestions.map(\.id))
    }

    // MARK: - Rating Bar (song)

    private func ratingBar(_ track: TrackInfo) -> some View {
        HStack(spacing: 8) {
            Button(action: { music.setFavorited(!track.favorited) }) {
                Image(systemName: track.favorited ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .foregroundStyle(track.favorited ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help("Favorite (⌃⌥F)")

            Button(action: { music.setDisliked(!track.disliked) }) {
                Image(systemName: track.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 14))
                    .foregroundStyle(track.disliked ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Dislike (⌃⌥D)")

            Spacer()

            starButtons(rating: track.rating, size: 14, spacing: 3, help: { "Rate \($0) (⌃⌥\($0))" }) { star in
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
                    Image(systemName: "cloud")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Streaming")
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                showPlaybackControls = hovering
            }
        }
    }

    // MARK: - Lyrics Page

    private var hasSyncedLyrics: Bool { !controller.syncedLines.isEmpty }
    private var showSynced: Bool { hasSyncedLyrics && (syncedOverride ?? settings.settings.preferSyncedLyrics) }

    private func lyricsPage() -> some View {
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
            Divider()
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
            .help(track.albumFavorited ? "Unstar album" : "Star album")

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

    private func albumFacts(_ track: TrackInfo) -> some View {
        let facts = checks.albumFacts
        return VStack(alignment: .leading, spacing: 4) {
            // Year: Music, the file tag (if different) and MusicBrainz
            HStack(spacing: 6) {
                factLabel("Year")
                Text(track.year > 0 ? "\(track.year)" : "—")
                    .font(.system(size: 11, weight: .medium))
                if let tagYear = track.fileTags?.year, tagYear != track.year {
                    Text("tag \(tagYear)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("The file's tag says \(tagYear)")
                }
                if let year = facts?.year {
                    if year == track.year {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .help("Matches MusicBrainz")
                    } else {
                        chip("MusicBrainz: \(year)", selected: false) {
                            music.setAlbumYear(year)
                        }
                        .help("Original release year on MusicBrainz — click to set it on the whole album")
                    }
                }
                Spacer(minLength: 0)
                lookupControl(facts)
            }

            // Genre: Music's, plus MusicBrainz genres to pick from
            HStack(spacing: 6) {
                factLabel("Genre")
                Text(track.genre.isEmpty ? "—" : track.genre)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let genres = facts?.genres, GenreMatching.agrees(track.genre, with: genres) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .help("One of the top MusicBrainz genres")
                }
                Spacer(minLength: 0)
            }
            if let genres = facts?.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(genres.prefix(6), id: \.self) { genre in
                            let name = GenreMatching.displayName(genre)
                            chip(name, selected: TextMatching.normalizeForMatching(name) == TextMatching.normalizeForMatching(track.genre)) {
                                music.setAlbumGenre(name)
                            }
                            .help("Set the genre of the whole album to \(name)")
                        }
                    }
                }
            } else if let error = checks.albumLookupError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if let stats = checks.albumStats, stats.trackCount > 0 {
                let s = settings.settings
                let count = stats.qualifying(s.albumStarCriterion, minRating: s.albumStarMinRating)
                Text(albumStarCaption(count: count, total: stats.trackCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
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
                Label("Look up", systemImage: "magnifyingglass")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Look up year and genre on MusicBrainz")
        }
    }

    private func factLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .leading)
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
            Text(playlistIsAlbum ? "ALBUM TRACKS" : "PLAYLIST")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

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

    // MARK: - Action Row (Cover and Lyrics pages)

    @ViewBuilder
    private func actionRow(_ track: TrackInfo) -> some View {
        let option = panel.isOptionPressed
        HStack(spacing: 4) {
            if page == .cover {
                actionButton("Fetch", icon: "photo.badge.arrow.down", disabled: controller.artworkLoading,
                             help: "Fetch artwork from the iTunes Store", action: controller.fetchArtwork)
                if track.isLocal {
                    actionButton(option ? "Delete" : "Write", icon: option ? "trash" : "tag", destructive: option,
                                 disabled: track.artworkData == nil && !option,
                                 help: "Write the artwork into the file's tag (hold ⌥ to delete it)") {
                        if option { controller.deleteArtwork() } else { controller.writeArtworkToFile() }
                    }
                }
                actionButton("Copy", icon: "doc.on.doc", disabled: track.artworkData == nil,
                             help: "Copy the artwork", action: controller.copyArtwork)
            } else {
                let hasLyrics = !controller.lyrics.isEmpty
                actionButton("Fetch", icon: "text.magnifyingglass", disabled: controller.lyricsLoading,
                             help: "Fetch lyrics", action: controller.fetchLyrics)
                actionButton(option ? "Delete" : "Write", icon: option ? "trash" : "tag", destructive: option,
                             disabled: !hasLyrics && !option,
                             help: track.isLocal ? "Write the lyrics into the file's tag (hold ⌥ to delete them)"
                                                 : "Save the lyrics in Music (hold ⌥ to delete them)") {
                    if option { controller.deleteLyrics() } else { controller.writeLyricsToFile() }
                }
                actionButton(option && controller.syncedLyricsText != nil ? "Copy LRC" : "Copy", icon: "doc.on.doc",
                             disabled: !hasLyrics, help: "Copy the lyrics (hold ⌥ to copy with timestamps)") {
                    controller.copyLyrics(withTiming: option)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, destructive: Bool = false, disabled: Bool,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                .foregroundStyle(destructive ? .red : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Status and Tabs

    @ViewBuilder
    private func statusLine() -> some View {
        Group {
            if let progress = controller.bulkProgress {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Stop") { controller.cancelBulkFetch() }
                        .buttonStyle(.borderless)
                }
            } else if let msg = controller.statusMessage {
                Text(msg)
                    .foregroundStyle(controller.statusIsError ? .red : .green)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 10))
        .frame(height: 14)
        .animation(.default, value: controller.statusMessage)
    }

    private func tabBar(_ track: TrackInfo) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                tabButton(.cover, icon: "photo", help: "Cover")
                tabButton(.lyrics, icon: "quote.bubble", help: "Lyrics")
                tabButton(.album, icon: "square.stack", help: "Album: rating, year, genre and tracks",
                          badge: checks.suggestions.contains { $0.kind != .syncedLyrics })
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 10) {
                Button(action: { music.previousTrack() }) {
                    Image(systemName: "backward.fill").font(.system(size: 10))
                }.buttonStyle(.plain).help("Previous")
                Button(action: { music.playPause() }) {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                }.buttonStyle(.plain).help(track.isPlaying ? "Pause" : "Play")
                Button(action: { music.nextTrack() }) {
                    Image(systemName: "forward.fill").font(.system(size: 10))
                }.buttonStyle(.plain).help("Next")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            Button(action: onShowSettingsMenu) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private func tabButton(_ target: PanelPage, icon: String, help: String, badge: Bool = false) -> some View {
        let selected = page == target
        return Button(action: { settings.settings.panelPage = target }) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.primary.opacity(0.1) : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 3).padding(.trailing, 8)
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
