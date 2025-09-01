import Foundation
import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {
    // MARK: - Published state
    @Published private(set) var songs: [Song] = []
    @Published private(set) var savedFolders: [URL] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var albumMappings: [String: String] = [:]
    @Published private(set) var songMetadataCache: [String: SongMetadata] = [:]
    // Precomputed album buckets for fast UI
    @Published private(set) var albumBuckets: [AlbumBucket] = []

    // MARK: - Artwork thumbnail cache (memory + disk)
    private let thumbMem = NSCache<NSString, UIImage>()
    private let thumbIO = DispatchQueue(label: "ThumbIO", qos: .utility)
    private lazy var thumbDiskURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("thumbs", isDirectory: true)
    }()

    struct AlbumBucket: Hashable, Identifiable {
        var id: String { album }
        let album: String
        let songIDs: [Song.ID]
        let repSongID: Song.ID?
    }
    @Published var selectedAlbumID: String?

    var albums: [String] {
        Set(songs.map { $0.album }).sorted()
    }

    var allSongs: [Song] { songs }

    // MARK: - Persistence debounce
    private let ioQueue = DispatchQueue(label: "LibraryIO", qos: .utility)
    private var pendingSaveLibraryWork: DispatchWorkItem?
    private var pendingSaveFoldersWork: DispatchWorkItem?

    private var pendingBucketsWork: DispatchWorkItem?

    private func scheduleSaveLibrary(debounce seconds: TimeInterval = 0.6) {
        pendingSaveLibraryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.songs
            FilePersistence.saveLibrary(snapshot)
        }
        pendingSaveLibraryWork = work
        ioQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func scheduleSaveFolderList(debounce seconds: TimeInterval = 0.8) {
        pendingSaveFoldersWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.savedFolders
            FilePersistence.saveFolderList(snapshot)
        }
        pendingSaveFoldersWork = work
        ioQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleRebuildAlbumBuckets(debounce seconds: TimeInterval = 0.5) {
        pendingBucketsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.songs
            // Build off main thread
            let grouped = Dictionary(grouping: snapshot, by: { s in
                let name = s.album.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "No Album" : name
            })
            var buckets: [AlbumBucket] = []
            buckets.reserveCapacity(grouped.count)
            for (name, songs) in grouped {
                buckets.append(AlbumBucket(album: name,
                                           songIDs: songs.map(\.id),
                                           repSongID: songs.first?.id))
            }
            buckets.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
            DispatchQueue.main.async { self.albumBuckets = buckets }
        }
        pendingBucketsWork = work
        ioQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    init() {
        albumMappings = AlbumMappingStore.load()
        // Configure thumbnail cache
        thumbMem.countLimit = 600
        thumbMem.totalCostLimit = 64 * 1024 * 1024 // ~64 MB of decoded thumbnails
        // Ensure disk cache directory exists
        try? FileManager.default.createDirectory(at: thumbDiskURL, withIntermediateDirectories: true)

        Task { await loadLibraryOnLaunch() }
    }

    // MARK: - Container helpers

    private func currentContainerID() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
        return docs.components(separatedBy: "/Application/").last?.components(separatedBy: "/").first ?? "unknown"
    }

    private func extractContainerID(from path: String) -> String? {
        return path.components(separatedBy: "/Application/").last?.components(separatedBy: "/").first
    }

    // MARK: - Launch

    func loadLibraryOnLaunch() async {
        // 1) Restore bookmarks → de-dupe → publish
        //    (Use BookmarkStore.shared.restoredFolderURLs())
        let restoredFolders = BookmarkStore.shared.restoredFolderURLs()
        let uniqueFolders = Dictionary(grouping: restoredFolders, by: { $0.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values
        savedFolders = Array(uniqueFolders)

        // 2) Cache gating by container UUID
        let thisContainer = currentContainerID()
        let lastContainer = UserDefaults.standard.string(forKey: "lastContainerID")
        let cachedSongs = FilePersistence.loadLibrary()
        let shouldUseCache = (lastContainer == thisContainer) && !cachedSongs.isEmpty

        if shouldUseCache {
            // 3) Fast start with cache, then prune anything missing/foreign
            self.songs = cachedSongs
            scheduleRebuildAlbumBuckets()
            _ = await pruneMissingFiles(updateDisk: false) // don't rewrite cache twice
        } else {
            // 4) Cold load + enrich from the *restored folders* (current install)
            var loaded: [Song] = []
            for folder in savedFolders {
                let enriched = await loadAndEnrichSongs(from: folder)
                loaded.append(contentsOf: enriched)
            }
            self.songs = loaded
            scheduleRebuildAlbumBuckets()
            scheduleSaveLibrary()
        }

        // 5) Remember the container we used to populate cache
        UserDefaults.standard.set(thisContainer, forKey: "lastContainerID")
    }

    // MARK: - Import / Scan

    func loadSongs(from folderURL: URL) async {
        let enriched = await loadAndEnrichSongs(from: folderURL)
        guard !enriched.isEmpty else { return }
        await appendSongs(enriched, from: folderURL)
        BookmarkStore.shared.saveBookmark(forFolder: folderURL)
    }

    func importAndEnrich(_ folderURL: URL) async {
        let enriched = await loadAndEnrichSongs(from: folderURL)
        guard !enriched.isEmpty else { return }
        await appendSongs(enriched, from: folderURL)
        BookmarkStore.shared.saveBookmark(forFolder: folderURL)
    }

    private func loadAndEnrichSongs(from folderURL: URL) async -> [Song] {
        // Load file URLs off the main thread
        let raw = await SongLoader.loadSongs(from: folderURL)
        guard !raw.isEmpty else { return [] }

        // Limit concurrency to keep CPU/thermal in check
        let chunkSize = 8
        var enrichedAll: [Song] = []
        for chunk in raw.chunked(into: chunkSize) {
            do {
                let enrichedChunk = try await withThrowingTaskGroup(of: Song.self) { group in
                    for s in chunk { group.addTask { await self.enrich(song: s) } }
                    return try await group.reduce(into: [Song]()) { $0.append($1) }
                }
                enrichedAll.append(contentsOf: enrichedChunk)
            } catch {
                print("❌ Metadata enrichment chunk failed: \(error)")
                enrichedAll.append(contentsOf: chunk) // fall back to raw for this chunk
            }
        }

        // Pick a final album display name and persist mapping for this folder
        let finalAlbumName = resolveFinalAlbumName(from: enrichedAll, folderURL: folderURL)
        albumMappings[folderURL.path] = finalAlbumName
        AlbumMappingStore.save(albumMappings)

        // Rewrite album field so grouping is stable
        return renameSongs(enrichedAll, withAlbumName: finalAlbumName)
    }

    private func enrich(song: Song) async -> Song {
        let meta = await SongMetadataManager.shared.enrichMetadata(for: song)
        songMetadataCache[song.id] = meta

        let cleanArtist = !(meta.artist ?? "").isEmpty ? meta.artist : song.artist
        let cleanAlbum  = !(meta.album  ?? "").isEmpty ? meta.album  : song.album
        let cleanGenre  = meta.genre?.isEmpty == false ? meta.genre : song.genre
        let cleanYear   = meta.year ?? song.year
        let cleanTrack  = meta.trackNumber ?? song.trackNumber
        let cleanDisc   = meta.discNumber ?? song.discNumber

        return Song(
            id: song.id,
            title: meta.title,
            artist: cleanArtist,
            album: cleanAlbum,
            duration: song.duration,
            url: song.url,
            artwork: song.artwork,
            musicBrainzReleaseID: song.musicBrainzReleaseID,
            genre: cleanGenre ?? song.genre,
            year: cleanYear,
            trackNumber: cleanTrack,
            discNumber: cleanDisc
        )
    }

    private func resolveFinalAlbumName(from songs: [Song], folderURL: URL) -> String {
        // Pick most common non-empty, non-unknown album name; else default to folder name
        let trimmed = songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
        let counts = Dictionary(grouping: trimmed, by: { $0 })
            .mapValues(\.count)
            .filter { !$0.key.isEmpty && $0.key.lowercased() != "unknown album" && $0.key.lowercased() != "no album" }

        if let (winner, n) = counts.max(by: { $0.value < $1.value }),
           Double(n) / Double(songs.count) >= 0.4 {
            return winner
        }
        return folderURL.lastPathComponent
    }

    private func appendSongs(_ newSongs: [Song], from folderURL: URL) async {
        // Keep folder list in sync (no duplicate paths)
        let normalizedPath = folderURL.standardizedFileURL.path
        let existingPaths = Set(savedFolders.map { $0.standardizedFileURL.path })
        if !existingPaths.contains(normalizedPath) {
            savedFolders.append(folderURL.standardizedFileURL)
            scheduleSaveFolderList()
        }

        // De-dup by URL, append, persist (debounced)
        let existingURLs = Set(songs.map { $0.url })
        let filtered = newSongs.filter { !existingURLs.contains($0.url) }
        if !filtered.isEmpty {
            self.songs.append(contentsOf: filtered)
            scheduleSaveLibrary()
            scheduleRebuildAlbumBuckets()
        }
    }

    // MARK: - Removal / Pruning

    /// User removed a folder: drop songs under that path and clear mapping/bookmark.
    func removeFolder(_ folder: URL) {
        let target = folder.standardizedFileURL.path
        let fm = FileManager.default

        // Remove songs and optional sidecars that live beneath the folder
        let removed = songs.filter { $0.url.standardizedFileURL.path.hasPrefix(target) }
        for s in removed { deleteSidecarsIfPresent(for: s.url, fm: fm) }

        songs.removeAll { $0.url.standardizedFileURL.path.hasPrefix(target) }
        savedFolders.removeAll { $0.standardizedFileURL.path == target }

        // Drop caches for removed songs
        for s in removed { songMetadataCache.removeValue(forKey: s.id) }

        // Clean persistence
        BookmarkStore.shared.removeBookmark(forFolderPath: folder.path)
        albumMappings.removeValue(forKey: folder.path)
        AlbumMappingStore.save(albumMappings)
        scheduleSaveFolderList()
        scheduleSaveLibrary()
        scheduleRebuildAlbumBuckets()
    }

    /// One-tap “Force Remove Missing Files”: removes any song whose file cannot be found/resolved
    /// OR whose URL belongs to a different app container.
    @discardableResult
    func pruneMissingFiles(updateDisk: Bool = true) async -> Int {
        let fm = FileManager.default
        let snapshot = songs
        let myContainer = currentContainerID()

        func isForeignContainer(_ path: String) -> Bool {
            guard let id = extractContainerID(from: path) else { return false }
            return !id.isEmpty && id != myContainer
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var kept: [Song] = []
                var removedIDs = Set<Song.ID>()
                var removedURLs: [URL] = []

                for s in snapshot {
                    let url = s.url.standardizedFileURL
                    let path = url.path
                    if isForeignContainer(path) || !fm.fileExists(atPath: path) {
                        removedIDs.insert(s.id)
                        removedURLs.append(url)
                    } else {
                        kept.append(s)
                    }
                }

                // Drop metadata cache for removed IDs
                var newCache = self.songMetadataCache
                for rid in removedIDs { newCache.removeValue(forKey: rid) }

                // Optionally tidy sidecars (artwork/janitor)
                for u in removedURLs { self.deleteSidecarsIfPresent(for: u, fm: fm) }

                DispatchQueue.main.async {
                    self.songs = kept
                    self.songMetadataCache = newCache
                    self.scheduleRebuildAlbumBuckets()
                    if updateDisk { self.scheduleSaveLibrary() }
                    continuation.resume(returning: removedIDs.count)
                }
            }
        }
    }

    /// Also useful if an entire album is “ghosted”: removes any album group with zero existing files.
    func forceRemoveStaleAlbums() async {
        // Group by album; if all songs in a group are missing, remove all of them.
        let fm = FileManager.default
        let grouped = Dictionary(grouping: songs, by: \.album)

        var idsToRemove = Set<Song.ID>()
        for (_, group) in grouped {
            let missingCount = group.filter { !fm.fileExists(atPath: $0.url.path) }.count
            if missingCount == group.count {
                for s in group { idsToRemove.insert(s.id) }
            }
        }

        guard !idsToRemove.isEmpty else { return }
        self.songs.removeAll { idsToRemove.contains($0.id) }
        for id in idsToRemove { self.songMetadataCache.removeValue(forKey: id) }
        scheduleSaveLibrary()
        scheduleRebuildAlbumBuckets()
    }

    // MARK: - Thumbnails
    /// Return a cached or freshly built square thumbnail for a song's embedded artwork.
    /// - Parameters:
    ///   - song: The song whose `artwork` Data (if present) is used.
    ///   - side: Target size in points (width==height). The image is rendered at the device scale.
    /// - Returns: UIImage if artwork exists; otherwise nil (view should show a placeholder).
    func thumbnailFor(song: Song, side: CGSize) async -> UIImage? {
        let sideInt = Int(max(side.width, side.height))
        let key = "s:\(song.id)-\(sideInt)" as NSString

        // 1) Memory cache
        if let img = thumbMem.object(forKey: key) { return img }

        // 2) Disk cache
        let diskURL = thumbDiskURL.appendingPathComponent("\(song.id)-\(sideInt).png")
        if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data, scale: UIScreen.main.scale) {
            thumbMem.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height))
            return img
        }

        // 3) Build from embedded artwork data (if any)
        guard let artData = song.artwork else { return nil }

        // Do the resize off the main thread
        return await withCheckedContinuation { continuation in
            thumbIO.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let img = self.makeThumbnail(from: artData, side: CGSize(width: sideInt, height: sideInt))
                if let img {
                    // Save to caches
                    self.thumbMem.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height))
                    if let png = img.pngData() { try? png.write(to: diskURL, options: .atomic) }
                }
                continuation.resume(returning: img)
            }
        }
    }

    /// Resize & crop center to a square thumbnail.
    private func makeThumbnail(from data: Data, side: CGSize) -> UIImage? {
        guard let src = UIImage(data: data) else { return nil }
        let target = max(side.width, side.height)
        let scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target))
        let img = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            let aspect = max(target / src.size.width, target / src.size.height)
            let w = src.size.width * aspect
            let h = src.size.height * aspect
            let x = (target - w) / 2
            let y = (target - h) / 2
            src.draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
        return UIImage(cgImage: img.cgImage!, scale: scale, orientation: .up)
    }

    // MARK: - Helpers

    func isMetadataIncomplete(_ songs: [Song]) -> Bool {
        guard songs.count > 1 else { return false }
        let names = Set(songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) })
        let hasUnknowns = names.contains("No Album") || names.contains("Unknown Album")
        return names.count > 1 || hasUnknowns
    }

    private func renameSongs(_ songs: [Song], withAlbumName albumName: String) -> [Song] {
        songs.map {
            Song(id: $0.id, title: $0.title, artist: $0.artist, album: albumName,
                 duration: $0.duration, url: $0.url, artwork: $0.artwork,
                 genre: $0.genre, year: $0.year, trackNumber: $0.trackNumber, discNumber: $0.discNumber)
        }
    }

    /// Delete sidecar files we created (optional cleanup so art/json don’t keep albums visible).
    private func deleteSidecarsIfPresent(for url: URL, fm: FileManager) {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let jpg  = folder.appendingPathComponent(stem).appendingPathExtension("jpg")
        let metaDir = folder.appendingPathComponent(".metadata")
        let json = metaDir.appendingPathComponent(stem).appendingPathExtension("json")
        _ = try? fm.removeItem(at: jpg)
        _ = try? fm.removeItem(at: json)
    }
}

// MARK: - Small utilities
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[idx..<next]))
            idx = next
        }
        return result
    }
}

// LibraryViewModel.swift
extension LibraryViewModel {
    func songs(in folder: URL) -> [Song] {
        songs.filter { $0.fileURL.path.hasPrefix(folder.standardizedFileURL.path) }
    }
}
