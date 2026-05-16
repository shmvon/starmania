import Foundation
import AppKit

/// Handles writing metadata (lyrics, artwork) to audio files and exporting to Downloads.
class MetadataWriter: @unchecked Sendable {
    static let shared = MetadataWriter()
    
    private init() {}
    
    // MARK: - Export to Downloads
    
    func exportArtwork(data: Data, artist: String, title: String) throws -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = sanitizeFilename("\(artist) - \(title) - Artwork.png")
        let destURL = downloadsURL.appendingPathComponent(filename)
        
        // Convert to PNG if needed
        if let image = NSImage(data: data),
           let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try pngData.write(to: destURL)
        } else {
            // Write raw data as-is
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
    
    // MARK: - ID3 Writing (placeholder for Phase 4)
    
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
    
    /// Check if a file already has lyrics or artwork embedded
    func checkExistingMetadata(filePath: String) -> (hasLyrics: Bool, hasArtwork: Bool) {
        // Phase 4: implement with ID3TagEditor / AVFoundation
        return (false, false)
    }
    
    // MARK: - Private
    
    private func writeID3(filePath: String, lyrics: String?, artworkData: Data?) throws {
        // Phase 4: implement with ID3TagEditor
        print("[Starmania] ID3 writing not yet implemented")
    }
    
    private func writeMP4(filePath: String, lyrics: String?, artworkData: Data?) throws {
        // Phase 4: implement with AVFoundation
        print("[Starmania] MP4 writing not yet implemented")
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
