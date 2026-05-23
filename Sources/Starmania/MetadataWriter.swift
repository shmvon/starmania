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
    
    // MARK: - ID3 Writing
    
    func writeToFile(filePath: String, lyrics: String?, artworkData: Data?) throws {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        switch ext {
        case "mp3":
            try writeID3(filePath: filePath, lyrics: lyrics, artworkData: artworkData)
        case "m4a", "m4p", "aac":
            try writeMP4(filePath: filePath, lyrics: lyrics, artworkData: artworkData)
        default:
            throw MetadataError.unsupportedFormat(ext)
        }
    }
    
    func checkExistingMetadata(filePath: String) -> (hasLyrics: Bool, hasArtwork: Bool) {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        switch ext {
        case "mp3":
            return checkID3Metadata(filePath: filePath)
        case "m4a", "m4p", "aac":
            return checkMP4Metadata(filePath: filePath)
        default:
            return (false, false)
        }
    }
    
    // MARK: - Private
    
    private func writeID3(filePath: String, lyrics: String?, artworkData: Data?) throws {
        let editor = ID3TagEditor()
        let existingTag = try? editor.read(from: filePath)
        
        var tag = existingTag ?? ID32v3TagBuilder().build()
        
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
        
        guard !tag.frames.isEmpty else {
            throw MetadataError.writeError("No metadata to write")
        }
        
        try editor.write(tag: tag, to: filePath)
    }
    
    private func writeMP4(filePath: String, lyrics: String?, artworkData: Data?) throws {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVAsset(url: url)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let fileType: AVFileType = .m4a
        
        var metadataItems = asset.metadata.filter { item in
            guard let id = item.identifier else { return false }
            return id != .iTunesMetadataLyrics && id != .iTunesMetadataCoverArt
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
        
        exportSession.outputURL = tempURL
        exportSession.outputFileType = fileType
        exportSession.metadata = metadataItems
        
        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        
        exportSession.exportAsynchronously {
            exportError = exportSession.error
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = exportError {
            throw MetadataError.writeError("Export failed: \(error.localizedDescription)")
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
    
    private func checkMP4Metadata(filePath: String) -> (hasLyrics: Bool, hasArtwork: Bool) {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVAsset(url: url)
        let hasLyrics = asset.metadata.contains { $0.identifier == .iTunesMetadataLyrics }
        let hasArtwork = asset.metadata.contains { $0.identifier == .iTunesMetadataCoverArt }
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
