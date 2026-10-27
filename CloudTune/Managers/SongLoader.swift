import Foundation
import AVFoundation
import UIKit

class SongLoader {
    static let allowedExtensions = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"]
    static let imageExtensions   = ["jpg", "jpeg", "png", "webp"]

    /// Result of the fast, offline import pass.
    struct LocalScan {
        /// Ready to show right away: tags + folder/filename cleanup, artwork filled in.
        var songs: [Song]
        /// Songs whose tags had gaps; look these up online in the background with `lookUpOnline`.
        /// Each entry pairs the untouched file tags (`raw`) with the song we're showing (`shown`).
        var needsLookup: [(raw: Song, shown: Song)]
    }

    /// Fast import: read tags from every audio file in a folder (several at once), no network.
    /// NOTE: Security scope is managed by the caller (FolderPicker + SecurityScopeKeeper).
    static func scanLocal(from folderURL: URL) async -> LocalScan {
        // ❗️Do NOT open/close security scope here — it’s kept alive by the caller.

        // Get all files (non-hidden)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            print("⚠️ Could not read folder: \(folderURL)")
            return LocalScan(songs: [], needsLookup: [])
        }

        let audioFiles = files.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }

        // Fallback cover from an image in the folder; stored once, shared by every song that needs it.
        let fallbackArtworkID = (bestAlbumArtwork(in: files) ?? defaultCoverData).map { ArtworkStore.shared.save($0) }

        // Read tags with limited parallelism (file I/O bound; too many at once just thrashes).
        let maxConcurrent = 4
        var results = [(raw: Song, local: Song)?](repeating: nil, count: audioFiles.count)
        await withTaskGroup(of: (Int, Song, Song).self) { group in
            var next = 0
            func addNext() {
                guard next < audioFiles.count else { return }
                let i = next, url = audioFiles[i]
                next += 1
                group.addTask {
                    let raw = extractMetadata(from: url)
                    return (i, raw, MetadataEnricher.enrichLocal(raw))
                }
            }
            for _ in 0..<min(maxConcurrent, audioFiles.count) { addNext() }
            for await (i, raw, local) in group {
                results[i] = (raw, local)
                addNext()
            }
        }

        var scan = LocalScan(songs: [], needsLookup: [])
        for case let (raw, local)? in results {
            var song = local
            if song.artworkID == nil { song.artworkID = fallbackArtworkID }
            if song.album.isEmpty  { song.album  = raw.album }
            if song.artist.isEmpty { song.artist = raw.artist }
            if song.title.isEmpty  { song.title  = raw.title }
            scan.songs.append(song)
            if MetadataEnricher.needsOnlineLookup(local) { scan.needsLookup.append((raw, song)) }
        }
        print("⚡️ Scanned \(scan.songs.count) songs in \(folderURL.lastPathComponent) — \(scan.needsLookup.count) need an online lookup")
        return scan
    }

    /// Slow path for one song: MusicBrainz / Cover Art Archive / Deezer. Rate-limited; run in the background.
    /// Returns the improved song, keeping `shown`'s ID and artwork unless real cover art was found.
    static func lookUpOnline(raw: Song, shown: Song) async -> Song {
        guard var enriched = try? await MetadataEnricher.enrich(raw) else { return shown }

        // Raw had no embedded art: try the release's cover, else keep the cover we already show.
        if enriched.artworkID == nil {
            if let apiArtwork = try? await MetadataEnricher.fetchArtwork(for: enriched) {
                enriched.artwork = apiArtwork
            } else {
                enriched.artworkID = shown.artworkID
            }
        }

        // Never replace good values with blanks.
        if enriched.album.isEmpty  { enriched.album  = shown.album }
        if enriched.artist.isEmpty { enriched.artist = shown.artist }
        if enriched.title.isEmpty  { enriched.title  = shown.title }
        print("✨ Online lookup: '\(enriched.title)' — \(enriched.artist) / \(enriched.album) (MBID \(enriched.musicBrainzReleaseID ?? "none"))")
        return enriched
    }

    // MARK: - Helpers

    /// Pick the best image to use as fallback album cover.
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

        return scored
            .sorted { $0.1 > $1.1 }
            .first
            .flatMap { try? Data(contentsOf: $0.0) }
    }
    /// Encoded once — re-encoding the PNG for every song was a noticeable cost on large imports.
    private static let defaultCoverData: Data? = UIImage(named: "DefaultCover")?.pngData()

    /// Extract AVMetadata and fallback fields from a file.
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

        // Strict fallback: only accept track numbers from known keys/IDs
        if trackNumber == nil {
            let allowedIDs: Set<String> = [
                AVMetadataIdentifier.id3MetadataTrackNumber.rawValue,   // "TRCK"
                AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue // "trkn"
            ]

            func parseTrack(_ item: AVMetadataItem) -> Int? {
                if let n = item.numberValue?.intValue, (1...99).contains(n) { return n }
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

        // Final sanity
        if let tn = trackNumber, !(1...99).contains(tn) { trackNumber = nil }

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
                title  = components[1].trimmingCharacters(in: .whitespaces)
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
