import Foundation
import AVFoundation
import UIKit

class SongLoader {
    static let allowedExtensions = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp"]

    /// Load all valid audio files from a given folder URL, optionally using a persisted security scope.
    static func loadSongs(from folderURL: URL) -> [Song] {
        var songs: [Song] = []

        let fileManager = FileManager.default
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // Get all files (non-hidden)
        guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            print("⚠️ Could not read folder: \(folderURL)")
            return []
        }

        // Detect fallback artwork from any image in the folder
        let fallbackArtwork = bestAlbumArtwork(in: files)

        for fileURL in files where allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
            var song = extractMetadata(from: fileURL)
            if song.artwork == nil {
                song.artwork = fallbackArtwork
            }
            songs.append(song)
        }

        return songs
    }

    /// Pick the best image to use as fallback album cover
    private static func bestAlbumArtwork(in files: [URL]) -> Data? {
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }

        let scored = images.map { url -> (URL, Int) in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            var score = 0

            if ["cover", "folder", "front", "album"].contains(where: { name.contains($0) }) {
                score = 100
            } else if name.contains("thumb") || name.hasPrefix("_") || name.hasPrefix(".") {
                score = 0
            } else {
                score = 50
            }

            return (url, score)
        }

        return scored.sorted { $0.1 > $1.1 }.first.flatMap { try? Data(contentsOf: $0.0) }
    }

    /// Extract AVMetadata and fallback fields from a file
    private static func extractMetadata(from fileURL: URL) -> Song {
        let asset = AVAsset(url: fileURL)
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let folderName = fileURL.deletingLastPathComponent().lastPathComponent

        var title = filename
        var artist: String? = nil
        var album: String? = nil
        var artworkData: Data? = nil
        let duration = CMTimeGetSeconds(asset.duration)

        for meta in asset.commonMetadata {
            switch meta.commonKey?.rawValue {
            case "title":
                title = meta.stringValue ?? title
            case "artist":
                artist = meta.stringValue
            case "albumName":
                album = meta.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "artwork":
                artworkData = meta.dataValue
            default:
                break
            }
        }

        // Fallback for FLAC (or bad metadata)
        if (artist == nil || artist!.isEmpty), fileURL.pathExtension.lowercased() == "flac" {
            let components = filename.components(separatedBy: " - ")
            if components.count == 2 {
                artist = components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            }
        }

        return Song(
            id: Song.generateStableID(from: fileURL),
            title: title,
            artist: artist?.isEmpty == false ? artist! : folderName,
            album: album?.isEmpty == false ? album! : "No Album",
            duration: duration,
            url: fileURL,
            artwork: artworkData
        )
    }
    
}
