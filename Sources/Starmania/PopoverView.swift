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
    @State private var didInitialLoad: Bool = false
    
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
                emptyState("No track playing", icon: "pause.circle")
            } else {
                emptyState("Music not running", icon: "music.note")
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
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            
            Divider().padding(.vertical, 3)
            
            // Row 4: Lyrics
            lyricsSection()
            
            Divider().padding(.vertical, 3)
            
            // Row 5: Action buttons
            actionButtons(track)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
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
                VStack(spacing: 2) {
                    HStack {
                        Text(lyricsSource == .embedded ? "LYRICS (EMBEDDED)" : "LYRICS (GENIUS)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    
                    ScrollView {
                        Text(lyrics)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                    }
                    .frame(height: 280)  // ~7cm for lyrics
                }
            } else {
                VStack(spacing: 2) {
                    Text("No lyrics")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if !settings.hasGeniusKey {
                        Text("⌥-click for settings")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.vertical, 8)
            }
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
                    Button(action: { writeLyricsToFile(track) }) {
                        Label("Write Lyrics", systemImage: "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(lyrics.isEmpty)
                    
                    Button(action: { writeArtworkToFile(track) }) {
                        Label("Write Artwork", systemImage: "tag")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(track.artworkData == nil)
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
    
    private func emptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: panelWidth, height: 120)
    }
    
    // MARK: - Actions
    
    private func onTrackChanged() {
        lyricsError = nil
        statusMessage = nil
        
        if let track = music.currentTrack, let embedded = track.embeddedLyrics, !embedded.isEmpty {
            lyrics = embedded
            lyricsSource = .embedded
            return
        }
        
        lyrics = ""
        lyricsSource = .none
        
        if settings.settings.autoFetchLyrics && settings.hasGeniusKey {
            fetchLyrics()
        }
    }
    
    private func fetchLyrics() {
        guard let track = music.currentTrack else { return }
        guard settings.hasGeniusKey else {
            lyricsError = "No Genius API key"
            return
        }
        
        lyricsLoading = true
        lyricsError = nil
        
        Task {
            do {
                let result = try await GeniusFetcher.shared.fetchLyrics(
                    title: track.name,
                    artist: track.artist,
                    apiKey: settings.settings.geniusAPIKey
                )
                await MainActor.run {
                    self.lyrics = result.lyrics
                    self.lyricsSource = .genius
                    self.lyricsLoading = false
                }
            } catch {
                await MainActor.run {
                    self.lyricsError = error.localizedDescription
                    self.lyricsLoading = false
                }
            }
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
        guard let path = track.filePath else { return }
        do {
            try MetadataWriter.shared.writeToFile(filePath: path, lyrics: lyrics, artworkData: nil)
            showStatus("Lyrics → ID3 ✓")
        } catch {
            showStatus("Error: \(error.localizedDescription)")
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
    
    private func showStatus(_ message: String) {
        withAnimation { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { statusMessage = nil }
        }
    }
}

