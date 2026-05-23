import SwiftUI
import AppKit

// MARK: - Main Popover View

struct PopoverView: View {
    @StateObject private var music = MusicObserver.shared
    @StateObject private var settings = SettingsManager.shared
    
    @State private var lyrics: String = ""
    @State private var lyricsSource: LyricsSource = .none
    @State private var lyricsLoading: Bool = false
    @State private var lyricsError: String?
    @State private var showPlaybackControls: Bool = false
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false
    @State private var didInitialLoad: Bool = false
    @State private var isOptionPressed: Bool = false
    @State private var activeLyricsRequestID = UUID()
    @State private var pendingLyricsFileWrites: [String: String] = [:]
    
    // Playlist view state
    @State private var showPlaylist: Bool = false
    @State private var playlistTracks: [PlaylistTrackInfo] = []
    @State private var playlistLoading: Bool = false
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    enum LyricsSource {
        case none
        case embedded
        case genius
    }
    
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
        .onChange(of: music.currentTrack?.trackKey) { oldKey, newKey in
            if oldKey != newKey {
                onTrackChanged()
            }
        }
        .onAppear {
            // Handle initial load (onChange doesn't fire for the first value)
            if !didInitialLoad {
                didInitialLoad = true
                onTrackChanged()
            }
        }
        .onReceive(timer) { _ in
            let pressed = NSEvent.modifierFlags.contains(.option)
            if pressed != isOptionPressed {
                isOptionPressed = pressed
            }
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
            
            // Status message
            if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(statusIsError ? .red : .green)
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
            
            Button(action: { music.setDisliked(!track.disliked) }) {
                Image(systemName: track.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 14))
                    .foregroundStyle(track.disliked ? .red : .secondary)
            }
            .buttonStyle(.plain)
            
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
    
    private func lyricsSection() -> some View {
        VStack(spacing: 2) {
            lyricsHeader()
                .padding(.horizontal, 10)

            if lyricsLoading {
                ProgressView("Fetching...")
                    .font(.system(size: 11))
                    .padding(.vertical, 12)
            } else if let error = lyricsError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
            } else if !lyrics.isEmpty {
                ScrollView {
                    Text(lyrics)
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
            if playlistLoading {
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
                    }
                    .frame(height: 280)
                    .onAppear {
                        if let current = playlistTracks.first(where: { $0.isCurrentTrack }) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation {
                                    proxy.scrollTo(current.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func playlistRow(_ track: PlaylistTrackInfo) -> some View {
        HStack(spacing: 0) {
            // Left 45%: Song title (click to play, marquee on hover)
            Button(action: {
                music.playTrackAtIndex(track.id)
                // Refresh playlist after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    loadPlaylist()
                }
            }) {
                MarqueeText(text: track.name, font: .systemFont(ofSize: 11, weight: track.isCurrentTrack ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(width: (panelWidth - 12) * 0.43, alignment: .leading)
            
            // Right 55%: Rating controls
            HStack(spacing: 3) {
                Button(action: {
                    music.setFavoritedForTrack(atIndex: track.id, value: !track.favorited)
                    refreshTrackInPlaylist(track.id, favorited: !track.favorited)
                }) {
                    Image(systemName: track.favorited ? "heart.fill" : "heart")
                        .font(.system(size: 10))
                        .foregroundStyle(track.favorited ? .pink : .secondary)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    music.setDislikedForTrack(atIndex: track.id, value: !track.disliked)
                    refreshTrackInPlaylist(track.id, disliked: !track.disliked)
                }) {
                    Image(systemName: track.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 9))
                        .foregroundStyle(track.disliked ? .red : .secondary)
                }
                .buttonStyle(.plain)
                
                Spacer().frame(width: 4)
                
                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        let newRating = track.rating == star ? 0 : star
                        music.setRatingForTrack(atIndex: track.id, stars: newRating)
                        refreshTrackInPlaylist(track.id, rating: newRating)
                    }) {
                        Image(systemName: star <= track.rating ? "star.fill" : "star")
                            .font(.system(size: 9))
                            .foregroundStyle(star <= track.rating ? .yellow : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: (panelWidth - 12) * 0.57, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(track.isCurrentTrack ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    private func lyricsHeader() -> some View {
        HStack {
            Text(lyricsHeaderTitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: {
                NSApp.sendAction(NSSelectorFromString("showSettingsMenu"), to: nil, from: nil)
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings & API Key")
        }
    }

    private var lyricsHeaderTitle: String {
        switch lyricsSource {
        case .embedded:
            return "LYRICS (EMBEDDED)"
        case .genius:
            return "LYRICS (GENIUS)"
        case .none:
            return "LYRICS"
        }
    }
    
    // MARK: - Action Buttons
    
    private func actionButtons(_ track: TrackInfo) -> some View {
        VStack(spacing: 4) {
            // Row 1: Fetch (left=lyrics, right=artwork)
            HStack(spacing: 4) {
                Button(action: fetchLyrics) {
                    Label("Fetch Lyrics", systemImage: "text.magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!settings.hasGeniusKey || lyricsLoading)
                
                Button(action: fetchArtwork) {
                    Label("Fetch Artwork", systemImage: "photo.artframe")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            
            // Row 2: Write to ID3 tag (left=lyrics, right=artwork)
            if track.isLocal {
                HStack(spacing: 4) {
                    Button(action: {
                        if isOptionPressed {
                            deleteLyricsFromFile(track)
                        } else {
                            writeLyricsToFile(track)
                        }
                    }) {
                        Label(isOptionPressed ? "Delete Lyrics" : "Write Lyrics", systemImage: isOptionPressed ? "trash" : "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(isOptionPressed ? .red : .primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(lyrics.isEmpty && !isOptionPressed)
                    
                    Button(action: {
                        if isOptionPressed {
                            deleteArtworkFromFile(track)
                        } else {
                            writeArtworkToFile(track)
                        }
                    }) {
                        Label(isOptionPressed ? "Delete Artwork" : "Write Artwork", systemImage: isOptionPressed ? "trash" : "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(isOptionPressed ? .red : .primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(track.artworkData == nil && !isOptionPressed)
                }
            }
            
            // Row 3: Copy to clipboard (left=lyrics, right=artwork)
            HStack(spacing: 4) {
                Button(action: copyLyrics) {
                    Label("Copy Lyrics", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(lyrics.isEmpty)
                
                Button(action: { copyArtwork(track) }) {
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
    
    // MARK: - Actions
    
    private func onTrackChanged() {
        flushPendingLyricsFileWrites()
        invalidateLyricsRequest()
        lyricsLoading = false
        lyricsError = nil
        statusMessage = nil
        statusIsError = false
        
        if showPlaylist {
            loadPlaylist()
        }
        
        guard let track = music.currentTrack else {
            lyrics = ""
            lyricsSource = .none
            return
        }
        
        if let embedded = normalizedLyrics(track.embeddedLyrics) {
            lyrics = embedded
            lyricsSource = .embedded
            return
        }
        
        lyrics = ""
        lyricsSource = .none
        
        guard settings.settings.autoFetchLyrics, settings.hasGeniusKey else {
            return
        }
        
        startLyricsFetch(for: track)
    }
    
    private func fetchLyrics() {
        guard let track = music.currentTrack else { return }
        guard settings.hasGeniusKey else {
            lyricsError = "No Genius API key"
            return
        }
        
        startLyricsFetch(for: track)
    }
    
    private func startLyricsFetch(for track: TrackInfo) {
        let requestID = UUID()
        activeLyricsRequestID = requestID
        
        Task {
            let result = await fetchLyrics(for: track, requestID: requestID)
            guard let result else { return }

            // Evaluate activity and auto-write checks on the MainActor sequentially
            let isActive = await MainActor.run { isActiveLyricsRequest(requestID, for: track) }
            guard isActive else { return }

            let shouldAutoWrite = await MainActor.run { shouldAutoWriteFetchedLyrics(for: track) }
            guard shouldAutoWrite else { return }

            await MainActor.run {
                writeLyricsToFile(track, lyrics: result.lyrics)
            }
        }
    }
    
    private func fetchLyrics(for track: TrackInfo, requestID: UUID) async -> LyricsResult? {
        guard settings.hasGeniusKey else {
            await MainActor.run {
                if activeLyricsRequestID == requestID {
                    lyricsError = "No Genius API key"
                    lyricsLoading = false
                }
            }
            return nil
        }
        
        await MainActor.run {
            guard isActiveLyricsRequest(requestID, for: track) else { return }
            lyricsLoading = true
            lyricsError = nil
        }
        
        do {
            let result = try await GeniusFetcher.shared.fetchLyrics(
                title: track.name,
                artist: track.artist,
                apiKey: settings.settings.geniusAPIKey
            )
            let shouldApply = await MainActor.run {
                isActiveLyricsRequest(requestID, for: track)
            }
            guard shouldApply else { return nil }
            await MainActor.run {
                self.lyrics = result.lyrics
                self.lyricsSource = .genius
                self.lyricsLoading = false
            }
            return result
        } catch {
            let shouldApply = await MainActor.run {
                isActiveLyricsRequest(requestID, for: track)
            }
            guard shouldApply else { return nil }
            await MainActor.run {
                self.lyricsError = error.localizedDescription
                self.lyricsLoading = false
            }
            return nil
        }
    }
    
    private func fetchArtwork() {
        guard let track = music.currentTrack else { return }
        showStatus("Fetching artwork...")
        
        Task {
            do {
                let query = "\(track.artist) \(track.album)"
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let url = URL(string: "https://itunes.apple.com/search?term=\(query)&entity=album&limit=1")!
                let (data, _) = try await URLSession.shared.data(from: url)
                
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let first = results.first,
                   let artworkURL = first["artworkUrl100"] as? String {
                    let highRes = artworkURL.replacingOccurrences(of: "100x100", with: "600x600")
                    if let url = URL(string: highRes) {
                        let (imageData, _) = try await URLSession.shared.data(from: url)
                        await MainActor.run {
                            music.updateArtwork(imageData)
                            showStatus("Artwork fetched ✓")
                        }
                        return
                    }
                }
                await MainActor.run { showStatus("No artwork found") }
            } catch {
                await MainActor.run { showStatus("Fetch failed") }
            }
        }
    }
    
    private func writeLyricsToFile(_ track: TrackInfo) {
        writeLyricsToFile(track, lyrics: lyrics)
    }
    
    private func writeLyricsToFile(_ track: TrackInfo, lyrics: String) {
        if let path = track.filePath {
            // Writing metadata on the active Music track can interrupt playback,
            // so local tracks are persisted via the file tag only.
            if shouldDeferLyricsFileWrite(for: track) {
                pendingLyricsFileWrites[path] = lyrics
                music.currentTrack?.embeddedLyrics = lyrics
                showStatus("Lyrics queued for file write ✓")
            } else {
                do {
                    try MetadataWriter.shared.writeToFile(filePath: path, lyrics: lyrics, artworkData: nil)
                    music.currentTrack?.embeddedLyrics = lyrics
                    showStatus("Lyrics → File ✓")
                } catch {
                    showStatus("Lyrics write failed", isError: true)
                }
            }
        } else {
            music.setLyrics(lyrics)
            showStatus("Lyrics → Music ✓")
        }
    }
    
    private func invalidateLyricsRequest() {
        activeLyricsRequestID = UUID()
    }
    
    private func isActiveLyricsRequest(_ requestID: UUID, for track: TrackInfo) -> Bool {
        activeLyricsRequestID == requestID && music.currentTrack?.trackKey == track.trackKey
    }
    
    private func normalizedLyrics(_ lyrics: String?) -> String? {
        guard let lyrics else { return nil }
        let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    private func shouldAutoWriteFetchedLyrics(for track: TrackInfo) -> Bool {
        guard settings.settings.autoWriteLyrics else { return false }
        return track.isLocal
    }

    private func shouldDeferLyricsFileWrite(for track: TrackInfo) -> Bool {
        guard let path = track.filePath else { return false }
        return music.currentTrack?.filePath == path
    }

    private func flushPendingLyricsFileWrites() {
        let currentPath = music.currentTrack?.filePath
        let writesToFlush = pendingLyricsFileWrites.filter { $0.key != currentPath }
        guard !writesToFlush.isEmpty else { return }

        for (path, lyrics) in writesToFlush {
            do {
                try MetadataWriter.shared.writeToFile(filePath: path, lyrics: lyrics, artworkData: nil)
                pendingLyricsFileWrites.removeValue(forKey: path)
            } catch {
                showStatus("Deferred lyrics write failed", isError: true)
            }
        }
    }
    
    private func writeArtworkToFile(_ track: TrackInfo) {
        guard let path = track.filePath else { return }
        do {
            try MetadataWriter.shared.writeToFile(filePath: path, lyrics: nil, artworkData: track.artworkData)
            showStatus("Artwork → ID3 ✓")
        } catch {
            showStatus("Error: \(error.localizedDescription)")
        }
    }
    
    private func deleteLyricsFromFile(_ track: TrackInfo) {
        if let path = track.filePath {
            if shouldDeferLyricsFileWrite(for: track) {
                pendingLyricsFileWrites[path] = ""
                music.currentTrack?.embeddedLyrics = nil
                showStatus("Lyrics deletion queued ✓", isError: true)
            } else {
                do {
                    try MetadataWriter.shared.writeToFile(filePath: path, lyrics: "", artworkData: nil)
                    music.currentTrack?.embeddedLyrics = nil
                    showStatus("Lyrics deleted ✓", isError: true)
                } catch {
                    showStatus("Lyrics deleted (ID3 err)", isError: true)
                }
            }
        } else {
            music.setLyrics("")
            showStatus("Lyrics deleted ✓", isError: true)
        }
    }
    
    private func deleteArtworkFromFile(_ track: TrackInfo) {
        music.deleteArtwork()
        
        if let path = track.filePath {
            do {
                try MetadataWriter.shared.writeToFile(filePath: path, lyrics: nil, artworkData: Data())
                showStatus("Artwork deleted ✓", isError: true)
            } catch {
                showStatus("Artwork deleted (ID3 err)", isError: true)
            }
        } else {
            showStatus("Artwork deleted ✓", isError: true)
        }
    }
    
    private func copyLyrics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lyrics, forType: .string)
        showStatus("Lyrics copied ✓")
    }
    
    private func copyArtwork(_ track: TrackInfo) {
        guard let data = track.artworkData, let image = NSImage(data: data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        showStatus("Artwork copied ✓")
    }
    
    private func showStatus(_ message: String, isError: Bool = false) {
        withAnimation { 
            statusMessage = message
            statusIsError = isError
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { statusMessage = nil }
        }
    }
    
    // MARK: - Playlist Helpers
    
    private func loadPlaylist() {
        playlistLoading = true
        playlistTracks = []
        playlistTracks = music.fetchPlaylistTracks()
        playlistLoading = false
    }
    
    /// Optimistically update a track in the local playlist array for instant UI feedback.
    private func refreshTrackInPlaylist(_ trackId: Int, favorited: Bool? = nil, disliked: Bool? = nil, rating: Int? = nil) {
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
