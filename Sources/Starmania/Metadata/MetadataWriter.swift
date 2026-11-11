import Foundation
import AppKit
import ID3TagEditor
import AVFoundation

class MetadataWriter: @unchecked Sendable {
    static let shared = MetadataWriter()
    
    private init() {}
    
    // MARK: - Export to Downloads
    
    func exportArtwork(data: Data, artist: String, title: String) throws -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = sanitizeFilename("\(artist) - \(title) - Artwork.png")
        let destURL = downloadsURL.appendingPathComponent(filename)
        
        if let image = NSImage(data: data),
           let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try pngData.write(to: destURL)
        } else {
            try data.write(to: destURL)
        }
        
        return destURL
    }
    
    func exportLyrics(_ lyrics: String, artist: String, title: String) throws -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = sanitizeFilename("\(artist) - \(title) - Lyrics.txt")
        let destURL = downloadsURL.appendingPathComponent(filename)
        
        try lyrics.write(to: destURL, atomically: true, encoding: .utf8)
        return destURL
    }
    
    // MARK: - Tag Writing
    
    /// Write lyrics and/or artwork into the file's tags. `nil` leaves a field untouched,
    /// an empty value removes it. Runs off the main actor (nonisolated async).
    func writeToFile(filePath: String, lyrics: String?, artworkData: Data?) async throws {
        switch Self.format(of: filePath) {
        case .mp3:
            try writeID3(filePath: filePath, lyrics: lyrics, artworkData: artworkData)
        case .m4a:
            try await writeMP4(filePath: filePath, lyrics: lyrics, artworkData: artworkData)
        case nil:
            throw MetadataError.unsupportedFormat(URL(fileURLWithPath: filePath).pathExtension.lowercased())
        }
    }
    
    func checkExistingMetadata(filePath: String) async -> (hasLyrics: Bool, hasArtwork: Bool) {
        switch Self.format(of: filePath) {
        case .mp3:
            return checkID3Metadata(filePath: filePath)
        case .m4a:
            return await checkMP4Metadata(filePath: filePath)
        case nil:
            return (false, false)
        }
    }
    
    // MARK: - Tag Reading

    struct FileTags: Equatable {
        var lyrics: String?
        var year: Int?
        var genre: String?
    }

    /// Read lyrics, year and genre straight from the file, so what Starmania shows is what the
    /// file holds (Music's database copy can lag behind after a tag write). Nil for unsupported files.
    func readTags(filePath: String) async -> FileTags? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        switch Self.format(of: filePath) {
        case .mp3:
            guard let tag = try? ID3TagEditor().read(from: filePath) else { return FileTags() }
            let reader = ID3TagContentReader(id3Tag: tag)
            let lyrics = reader.unsynchronizedLyrics().map(\.content).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let year = reader.recordingDateTime()?.year ?? reader.recordingYear()
            let genre = reader.genre().flatMap { $0.description ?? $0.identifier.map { "\($0)" } }
            return FileTags(lyrics: lyrics, year: year, genre: genre)
        case .m4a:
            let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
            let metadata = (try? await asset.load(.metadata)) ?? []
            func string(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = metadata.first(where: { $0.identifier == id }) else { return nil }
                return try? await item.load(.stringValue)
            }
            let lyrics = await string(.iTunesMetadataLyrics)
            let date = await string(.iTunesMetadataReleaseDate)
            let genre = await string(.iTunesMetadataUserGenre)
            return FileTags(lyrics: lyrics, year: date.flatMap(Self.year(fromDate:)), genre: genre)
        case nil:
            return nil
        }
    }

    /// "2005", "2005-01-10" or "2005-01-10T08:00:00Z" → 2005.
    nonisolated static func year(fromDate text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix(4)
        guard digits.count == 4, let year = Int(digits), year > 0 else { return nil }
        return year
    }

    enum TagFormat { case mp3, m4a }
    
    /// Only plain MP3 and MPEG-4 audio are writable. Raw ADTS `.aac` has no tag container
    /// and `.m4p` is DRM-protected, so both are rejected rather than re-muxed.
    static func format(of filePath: String) -> TagFormat? {
        switch URL(fileURLWithPath: filePath).pathExtension.lowercased() {
        case "mp3": return .mp3
        case "m4a": return .m4a
        default: return nil
        }
    }
    
    // MARK: - Private
    
    private func writeID3(filePath: String, lyrics: String?, artworkData: Data?) throws {
        let editor = ID3TagEditor()
        let existingTag = try? editor.read(from: filePath)
        
        let tag = existingTag ?? ID32v3TagBuilder().build()
        
        // Handle lyrics
        if let lyrics = lyrics {
            removeAllLyricsFrames(&tag.frames)
            if !lyrics.isEmpty {
                tag.frames[.unsynchronizedLyrics(.eng)] = ID3FrameWithLocalizedContent(
                    language: .eng,
                    contentDescription: "Lyrics",
                    content: lyrics
                )
            }
        }
        
        // Handle artwork
        if let artworkData = artworkData {
            removeAllArtworkFrames(&tag.frames)
            if !artworkData.isEmpty {
                tag.frames[.attachedPicture(.frontCover)] = ID3FrameAttachedPicture(
                    picture: artworkData,
                    type: .frontCover,
                    format: detectImageFormat(artworkData)
                )
            }
        }
        
        try editor.write(tag: tag, to: filePath)
    }
    
    private func writeMP4(filePath: String, lyrics: String?, artworkData: Data?) async throws {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let existing = try await asset.load(.metadata)
        var metadataItems = existing.filter { item in
            guard let id = item.identifier else { return true }
            if lyrics != nil && id == .iTunesMetadataLyrics { return false }
            if artworkData != nil && id == .iTunesMetadataCoverArt { return false }
            return true
        }.compactMap { $0.mutableCopy() as? AVMutableMetadataItem }
        
        if let lyrics = lyrics, !lyrics.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataLyrics
            item.value = lyrics as NSString
            item.extendedLanguageTag = "eng"
            metadataItems.append(item)
        }
        
        if let artworkData = artworkData, !artworkData.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = artworkData as NSData
            metadataItems.append(item)
        }
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MetadataError.writeError("Could not create AVAssetExportSession")
        }
        exportSession.metadata = metadataItems
        
        if #available(macOS 15, *) {
            do {
                try await exportSession.export(to: tempURL, as: .m4a)
            } catch {
                throw MetadataError.writeError("Export failed: \(error.localizedDescription)")
            }
        } else {
            exportSession.outputURL = tempURL
            exportSession.outputFileType = .m4a
            await exportSession.export()
            if let error = exportSession.error {
                throw MetadataError.writeError("Export failed: \(error.localizedDescription)")
            }
        }
        
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw MetadataError.writeError("Export produced no output file")
        }
        
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
    
    private func checkID3Metadata(filePath: String) -> (hasLyrics: Bool, hasArtwork: Bool) {
        let editor = ID3TagEditor()
        guard let tag = try? editor.read(from: filePath) else {
            return (false, false)
        }
        let hasLyrics = tag.frames.keys.contains { key in
            if case .unsynchronizedLyrics = key { return true }
            return false
        }
        let hasArtwork = tag.frames.keys.contains { key in
            if case .attachedPicture = key { return true }
            return false
        }
        return (hasLyrics, hasArtwork)
    }
    
    private func checkMP4Metadata(filePath: String) async -> (hasLyrics: Bool, hasArtwork: Bool) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        let metadata = (try? await asset.load(.metadata)) ?? []
        let hasLyrics = metadata.contains { $0.identifier == .iTunesMetadataLyrics }
        let hasArtwork = metadata.contains { $0.identifier == .iTunesMetadataCoverArt }
        return (hasLyrics, hasArtwork)
    }
    
    private func removeAllLyricsFrames(_ frames: inout [FrameName: ID3Frame]) {
        let keys = frames.keys.filter { key in
            if case .unsynchronizedLyrics = key { return true }
            return false
        }
        for key in keys {
            frames.removeValue(forKey: key)
        }
    }
    
    private func removeAllArtworkFrames(_ frames: inout [FrameName: ID3Frame]) {
        let keys = frames.keys.filter { key in
            if case .attachedPicture = key { return true }
            return false
        }
        for key in keys {
            frames.removeValue(forKey: key)
        }
    }
    
    private func detectImageFormat(_ data: Data) -> ID3PictureFormat {
        var bytes = [UInt8](repeating: 0, count: 4)
        data.copyBytes(to: &bytes, count: min(4, data.count))
        if bytes[0] == 0x89 && bytes[1] == 0x50 { return .png }
        return .jpeg
    }
    
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
}

enum MetadataError: LocalizedError {
    case unsupportedFormat(String)
    case writeError(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported audio format: .\(ext)"
        case .writeError(let msg): return "Write error: \(msg)"
        }
    }
}
