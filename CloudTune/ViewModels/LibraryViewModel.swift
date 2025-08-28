import Foundation
import SwiftUI
import AVFoundation

final class LibraryViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var savedFolders: [URL] = []
    @Published var playlists: [Playlist] = []
    @Published var albumMappings: [String: String] = [:]
    @Published var songMetadataCache: [String: SongMetadata] = [:]
    @Published var selectedAlbumID: String?

    var albums: [String] {
        Set(songs.map { $0.album }).sorted()
    }

    var allSongs: [Song] { songs }

    init() {
        albumMappings = AlbumMappingStore.load()
        Task { await loadLibraryOnLaunch() }
    }

    // MARK: - Launch

    func loadLibraryOnLaunch() async {
        // 1) Restore bookmarks → de-dupe → publish
        let restoredFolders = BookmarkManager.restoreBookmarkedFolders()
        let uniqueFolders = Dictionary(grouping: restoredFolders, by: { $0.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values
        await MainActor.run { savedFolders = Array(uniqueFolders) }
        FilePersistence.saveFolderList(savedFolders)

        // 2) Try cached library first (fast start)
        let cachedSongs = FilePersistence.loadLibrary()
        if !cachedSongs.isEmpty {
            await MainActor.run { self.songs = cachedSongs }
            // 3) Immediately prune any files that were deleted outside the app
            await pruneMissingFiles(updateDisk: false) // don’t rewrite cache twice on launch
            return
        }

        // 4) Cold load + enrich
        var loaded: [Song] = []
        for folder in savedFolders {
            let enriched = await loadAndEnrichSongs(from: folder)
            loaded.append(contentsOf: enriched)
        }

        await MainActor.run { self.songs = loaded }
        FilePersistence.saveLibrary(loaded)
    }

    // MARK: - Import / Scan

    func loadSongs(from folderURL: URL) async {
        let enriched = await loadAndEnrichSongs(from: folderURL)
        guard !enriched.isEmpty else { return }
        await appendSongs(enriched, from: folderURL)
        BookmarkManager.saveFolderBookmark(url: folderURL)
    }

    @MainActor
    func importAndEnrich(_ folderURL: URL) async {
        let enriched = await loadAndEnrichSongs(from: folderURL)
        guard !enriched.isEmpty else { return }
        await appendSongs(enriched, from: folderURL)
        BookmarkManager.saveFolderBookmark(url: folderURL)
    }

    private func loadAndEnrichSongs(from folderURL: URL) async -> [Song] {
        let raw = await SongLoader.loadSongs(from: folderURL)
        guard !raw.isEmpty else { return [] }

        do {
            // Enrich in parallel
            let enriched = try await withThrowingTaskGroup(of: Song.self) { group in
                for s in raw { group.addTask { await self.enrich(song: s) } }
                return try await group.reduce(into: [Song]()) { $0.append($1) }
            }

            // Pick a final album display name and persist mapping for this folder
            let finalAlbumName = resolveFinalAlbumName(from: enriched, folderURL: folderURL)
            await MainActor.run {
                albumMappings[folderURL.path] = finalAlbumName
                AlbumMappingStore.save(albumMappings)
            }

            // Rewrite album field so grouping is stable
            return renameSongs(enriched, withAlbumName: finalAlbumName)
        } catch {
            print("❌ Metadata enrichment failed: \(error)")
            return raw
        }
    }

    private func enrich(song: Song) async -> Song {
        let meta = await SongMetadataManager.shared.enrichMetadata(for: song)
        await MainActor.run { self.songMetadataCache[song.id] = meta }

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
        // Keep folder list in sync
        let normalizedPath = folderURL.standardizedFileURL.path
        let existingPaths = Set(savedFolders.map { $0.standardizedFileURL.path })
        if !existingPaths.contains(normalizedPath) {
            await MainActor.run {
                savedFolders.append(folderURL.standardizedFileURL)
                FilePersistence.saveFolderList(savedFolders)
            }
        }

        // De-dup by URL, append, persist
        let existingURLs = Set(songs.map { $0.url })
        let filtered = newSongs.filter { !existingURLs.contains($0.url) }
        await MainActor.run {
            self.songs.append(contentsOf: filtered)
            FilePersistence.saveLibrary(self.songs)
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
        BookmarkManager.removeBookmark(for: folder)
        albumMappings.removeValue(forKey: folder.path)
        AlbumMappingStore.save(albumMappings)
        FilePersistence.saveFolderList(savedFolders)
        FilePersistence.saveLibrary(songs)
    }

    /// One-tap “Force Remove Missing Files”: removes any song whose file cannot be found/resolved.
    /// - Parameter updateDisk: set true to rewrite the on-disk cache immediately.
    @discardableResult
    func pruneMissingFiles(updateDisk: Bool = true) async -> Int {
        let fm = FileManager.default
        let snapshot = songs

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var kept: [Song] = []
                var removedIDs = Set<Song.ID>()
                var removedURLs: [URL] = []

                for s in snapshot {
                    let url = s.url.standardizedFileURL
                    if fm.fileExists(atPath: url.path) {
                        kept.append(s)
                    } else {
                        removedIDs.insert(s.id)
                        removedURLs.append(url)
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
                    if updateDisk { FilePersistence.saveLibrary(kept) }
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
        await MainActor.run {
            self.songs.removeAll { idsToRemove.contains($0.id) }
            for id in idsToRemove { self.songMetadataCache.removeValue(forKey: id) }
            FilePersistence.saveLibrary(self.songs)
        }
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
