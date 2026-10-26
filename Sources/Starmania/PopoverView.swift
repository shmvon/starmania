import SwiftUI
import AppKit

/// Panel state owned by the app delegate: visibility and the ⌥ key (sampled only while visible).
@MainActor
final class PanelState: ObservableObject {
    @Published var isVisible = false
    @Published var isOptionPressed = false
}

// MARK: - Main Popover View

struct PopoverView: View {
    @ObservedObject private var music = MusicObserver.shared
    @ObservedObject private var controller = NowPlayingController.shared
    @ObservedObject var panel: PanelState
    let onShowSettingsMenu: () -> Void

    @State private var showPlaybackControls: Bool = false
    @State private var showSyncedLyrics: Bool = true

    // Playlist view state
    @State private var showPlaylist: Bool = false
    @State private var playlistTracks: [PlaylistTrackInfo] = []
    @State private var playlistLoading: Bool = false
    @State private var playlistRequestID = UUID()

    private let panelWidth: CGFloat = 250

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
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)  // Size to content, don't stretch
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: music.currentTrack?.trackKey) { _, _ in
            if showPlaylist { loadPlaylist() }
        }
        .onChange(of: panel.isVisible) { _, visible in
            if visible && showPlaylist { loadPlaylist() }
        }
    }

    // MARK: - Track View

    @ViewBuilder
    private func trackView(_ track: TrackInfo) -> some View {
        let artSize = panelWidth - 20  // 10pt padding each side

        VStack(spacing: 5) {
            // Row 1: Favorite, Dislike, Stars
            ratingBar(track)
                .padding(.top, 10)
                .padding(.horizontal, 10)

            // Row 2: Artwork with playback overlay
            artworkView(track, size: artSize)
                .padding(.horizontal, 10)

            // Row 3: Track info
            VStack(spacing: 2) {
                Text(track.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(track.artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(track.album)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if !track.isLocal {
                    Label("Streaming", systemImage: "cloud")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 10)

            // Bulk progress or status message
            if let progress = controller.bulkProgress {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Stop") { controller.cancelBulkFetch() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 10)
            } else if let msg = controller.statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(controller.statusIsError ? .red : .green)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
            }

            // Toggle bar: Lyrics vs Playlist
            viewToggleBar()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)

            Divider()

            // Row 4: Lyrics or Playlist
            if showPlaylist {
                playlistSection()
            } else {
                lyricsSection()

                Divider().padding(.vertical, 3)

                // Row 5: Action buttons (only in lyrics mode)
                actionButtons(track)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .animation(.default, value: controller.statusMessage)
    }

    // MARK: - Rating Bar

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

            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        music.setRating(track.rating == star ? 0 : star)
                    }) {
                        Image(systemName: star <= track.rating ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(star <= track.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rate \(star) (⌃⌥\(star))")
                }
            }
        }
    }

    // MARK: - Artwork

    private func artworkView(_ track: TrackInfo, size: CGFloat) -> some View {
        ZStack {
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
                        Image(systemName: "music.note")
                            .font(.system(size: 36))
                            .foregroundStyle(.quaternary)
                    }
            }

            if showPlaybackControls {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.4))
                    .frame(width: size, height: size)

                HStack(spacing: 22) {
                    Button(action: { music.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)

                    Button(action: { music.playPause() }) {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)

                    Button(action: { music.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
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

    // MARK: - Lyrics

    private var hasSyncedLyrics: Bool { !controller.syncedLines.isEmpty }

    private func lyricsSection() -> some View {
        VStack(spacing: 2) {
            lyricsHeader()
                .padding(.horizontal, 10)

            if controller.lyricsLoading {
                ProgressView("Fetching...")
                    .font(.system(size: 11))
                    .padding(.vertical, 12)
            } else if let error = controller.lyricsError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
            } else if hasSyncedLyrics && showSyncedLyrics {
                syncedLyricsView()
                    .frame(height: 280)
            } else if !controller.lyrics.isEmpty {
                ScrollView {
                    Text(controller.lyrics)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                .frame(height: 280)  // ~7cm for lyrics
            } else {
                Text("No lyrics")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
    }

    /// Time-synced lyrics: highlights the current line and keeps it centered.
    private func syncedLyricsView() -> some View {
        let lines = controller.syncedLines
        return TimelineView(.animation(minimumInterval: 0.25, paused: !panel.isVisible)) { context in
            let time = music.currentTrack?.estimatedPosition(at: context.date) ?? 0
            let currentIndex = LRCParser.currentLineIndex(in: lines, at: time)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(lines) { line in
                            let isCurrent = line.id == currentIndex
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 120)  // Lets the first and last lines reach the center
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

    // MARK: - View Toggle Bar

    private func viewToggleBar() -> some View {
        HStack(spacing: 0) {
            Button(action: { showPlaylist = false }) {
                Image(systemName: "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(showPlaylist ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(showPlaylist ? Color.clear : Color.primary.opacity(0.1))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Lyrics")

            Button(action: {
                showPlaylist = true
                loadPlaylist()
            }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(showPlaylist ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(showPlaylist ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Playlist")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Playlist Section

    private func playlistSection() -> some View {
        VStack(spacing: 0) {
            if playlistLoading && playlistTracks.isEmpty {
                ProgressView("Loading playlist...")
                    .font(.system(size: 11))
                    .padding(.vertical, 12)
            } else if playlistTracks.isEmpty {
                Text("No playlist available")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
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
                        .padding(.trailing, 10)
                    }
                    .frame(height: 280)
                    .onAppear { scrollToCurrent(proxy) }
                    .onChange(of: playlistTracks.first(where: \.isCurrentTrack)?.id) { _, _ in
                        scrollToCurrent(proxy)
                    }
                }
            }
        }
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

        return HStack(spacing: 0) {
            // Left ~44%: Song title (click to play, marquee on hover)
            Button(action: {
                music.playTrack(id: track.id)
            }) {
                MarqueeText(text: track.name, font: .systemFont(ofSize: 11.5, weight: isCurrent ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(width: (panelWidth - 22) * 0.44, alignment: .leading)

            // Right ~56%: Rating controls
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

                Spacer().frame(width: 2)

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
            .frame(width: (panelWidth - 22) * 0.56, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    private func lyricsHeader() -> some View {
        HStack(spacing: 6) {
            Text(lyricsHeaderTitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            if hasSyncedLyrics {
                Button(action: { showSyncedLyrics.toggle() }) {
                    Image(systemName: showSyncedLyrics ? "text.alignleft" : "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showSyncedLyrics ? "Show plain lyrics" : "Show synced lyrics")
            }
            Button(action: onShowSettingsMenu) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var lyricsHeaderTitle: String {
        guard let source = controller.lyricsSource else { return "LYRICS" }
        let synced = hasSyncedLyrics ? ", SYNCED" : ""
        return "LYRICS (\(source.displayName.uppercased())\(synced))"
    }

    // MARK: - Action Buttons

    private func actionButtons(_ track: TrackInfo) -> some View {
        let option = panel.isOptionPressed
        let hasLyrics = !controller.lyrics.isEmpty

        return VStack(spacing: 4) {
            // Row 1: Fetch (left=lyrics, right=artwork)
            HStack(spacing: 4) {
                Button(action: controller.fetchLyrics) {
                    Label("Fetch Lyrics", systemImage: "text.magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(controller.lyricsLoading)

                Button(action: controller.fetchArtwork) {
                    Label("Fetch Artwork", systemImage: "photo.artframe")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(controller.artworkLoading)
            }

            // Row 2: Write to file tag (left=lyrics, right=artwork); ⌥ switches to delete
            if track.isLocal {
                HStack(spacing: 4) {
                    Button(action: {
                        if option { controller.deleteLyrics() } else { controller.writeLyricsToFile() }
                    }) {
                        Label(option ? "Delete Lyrics" : "Write Lyrics", systemImage: option ? "trash" : "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(option ? .red : .primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!hasLyrics && !option)

                    Button(action: {
                        if option { controller.deleteArtwork() } else { controller.writeArtworkToFile() }
                    }) {
                        Label(option ? "Delete Artwork" : "Write Artwork", systemImage: option ? "trash" : "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(option ? .red : .primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(track.artworkData == nil && !option)
                }
                .help("Hold ⌥ to delete instead")
            }

            // Row 3: Copy to clipboard (left=lyrics, right=artwork)
            HStack(spacing: 4) {
                Button(action: controller.copyLyrics) {
                    Label("Copy Lyrics", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!hasLyrics)

                Button(action: controller.copyArtwork) {
                    Label("Copy Artwork", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(track.artworkData == nil)
            }
        }
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
        .frame(width: panelWidth, height: 120)
    }

    // MARK: - Playlist Helpers

    private func loadPlaylist() {
        let requestID = UUID()
        playlistRequestID = requestID
        playlistLoading = true
        Task {
            let tracks = await music.fetchPlaylistTracks()
            guard playlistRequestID == requestID else { return }
            playlistTracks = tracks
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
