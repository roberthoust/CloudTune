import Foundation
import AVFoundation
import UIKit

class SongLoader {
    static let allowedExtensions = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp"]

    /// Load all valid audio files from a given folder URL, optionally using a persisted security scope.
    static func loadSongs(from folderURL: URL) async -> [Song] {
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
            let rawSong = extractMetadata(from: fileURL)
            print("🔍 Extracted Raw Metadata — Title: \(rawSong.title), Artist: \(rawSong.artist ?? "nil"), Album: \(rawSong.album ?? "nil"), Track: \(rawSong.trackNumber ?? 0)")

            do {
                var enriched = try await MetadataEnricher.enrich(rawSong)
                print("""
                ✨ Enriched Metadata
                   Title:   \(enriched.title)
                   Artist:  \(enriched.artist)
                   Album:   \(enriched.album)
                   Year:    \(enriched.year)
                   Track:   \(enriched.trackNumber) / Disc: \(enriched.discNumber)
                   Duration:\(String(format: "%.1f sec", enriched.duration))
                   Genre:   \(enriched.genre ?? "N/A")
                   MBID:    \(enriched.musicBrainzReleaseID ?? "N/A")
                   Link:    \(enriched.externalURL ?? "N/A")
                """)

                // Try fetching artwork from API as first priority
                if enriched.artwork == nil {
                    if let apiArtwork = try? await MetadataEnricher.fetchArtwork(for: enriched) {
                        enriched.artwork = apiArtwork
                    } else {
                        enriched.artwork = fallbackArtwork ?? rawSong.artwork
                    }
                }

                // Ensure album/artist/title fallback safety
                if enriched.album.isEmpty {
                    enriched.album = rawSong.album
                }
                if enriched.artist.isEmpty {
                    enriched.artist = rawSong.artist
                }
                if enriched.title.isEmpty {
                    enriched.title = rawSong.title
                }

                songs.append(enriched)
            } catch {
                // Fallback to raw song if enrichment failed
                print("⚠️ Enrichment failed for \(rawSong.title). Using fallback metadata.")
                var fallback = rawSong
                if fallback.artwork == nil {
                    fallback.artwork = fallbackArtwork
                }
                print("📦 Fallback Metadata — Title: \(fallback.title), Artist: \(fallback.artist), Album: \(fallback.album), Track: \(fallback.trackNumber ?? 0)")
                songs.append(fallback)
            }
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
        var genre: String? = nil
        let duration = CMTimeGetSeconds(asset.duration)
        var trackNumber: Int? = nil

        // Common tag pass
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
            case "genre":
                genre = meta.stringValue
            case "trackNumber":
                if let number = meta.numberValue?.intValue, (1...99).contains(number) {
                    trackNumber = number
                } else if let stringValue = meta.stringValue {
                    let parts = stringValue.components(separatedBy: "/")
                    if let first = parts.first,
                       let num = Int(first.trimmingCharacters(in: .whitespaces)),
                       (1...99).contains(num) {
                        trackNumber = num
                    }
                }
            default:
                break
            }
        }

        // MARK: Strict fallback: only accept track numbers from known keys/IDs
        if trackNumber == nil {
            let allowedIDs: Set<String> = [
                AVMetadataIdentifier.id3MetadataTrackNumber.rawValue,   // "TRCK"
                AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue // "trkn"
            ]

            func parseTrack(_ item: AVMetadataItem) -> Int? {
                // Prefer numberValue if sane
                if let n = item.numberValue?.intValue, (1...99).contains(n) { return n }
                // Parse string forms like "05/12", "05", "5 of 12"
                if let s = item.stringValue {
                    let cleaned = s.replacingOccurrences(of: "of", with: "/")
                    let first = cleaned
                        .components(separatedBy: CharacterSet(charactersIn: "/ -_"))
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let n = Int(first), (1...99).contains(n) { return n }
                }
                return nil
            }

            outer: for format in asset.availableMetadataFormats {
                for item in asset.metadata(forFormat: format) {
                    let isCommonTrack = (item.commonKey?.rawValue == "trackNumber")
                    let isAllowedID = item.identifier.map { allowedIDs.contains($0.rawValue) } ?? false
                    guard isCommonTrack || isAllowedID else { continue }

                    if let n = parseTrack(item) {
                        trackNumber = n
                        break outer
                    }
                }
            }
        }

        // FINAL sanity: discard absurd values (e.g., year=2015 accidentally parsed upstream)
        if let tn = trackNumber, !(1...99).contains(tn) {
            trackNumber = nil
        }

        // Filename rescue (e.g., "01 - Title", "1. Title", "01_Title")
        if trackNumber == nil {
            let leadingDigits = filename.prefix { $0.isNumber }
            if let n = Int(leadingDigits), (1...99).contains(n) {
                trackNumber = n
            }
        }

        // Fallback for FLAC (or bad metadata): "Artist - Title"
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
            artwork: artworkData,
            genre: genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            trackNumber: trackNumber ?? 0
        )
    }
}
