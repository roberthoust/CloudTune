import Foundation
import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {
    // MARK: - Published state
    @Published private(set) var songs: [Song] = [] {
        didSet { songsVersion &+= 1 }
    }
    /// Changes whenever `songs` does; cheap for views to watch instead of comparing the whole array.
    @Published private(set) var songsVersion = 0
    @Published private(set) var savedFolders: [URL] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var albumMappings: [String: String] = [:]
    @Published private(set) var songMetadataCache: [String: SongMetadata] = [:]
    // Precomputed album buckets for fast UI
    @Published private(set) var albumBuckets: [AlbumBucket] = []

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

    // MARK: - Persistence
    // Every change writes only the songs it touched (see LibraryDatabase); nothing rewrites the whole library.
    private let db = LibraryDatabase.shared
    private let ioQueue = DispatchQueue(label: "LibraryIO", qos: .utility)

    private var pendingBucketsWork: DispatchWorkItem?

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
        // 1) Restore bookmarks: key (path when added) → where the folder lives now.
        let bookmarks = BookmarkStore.shared
        let restored = bookmarks.restoredFolders()
        let uniqueFolders = Dictionary(grouping: restored.values, by: { $0.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values
        savedFolders = Array(uniqueFolders)

        // 2) Load from the database (importing the old JSON files the first time).
        //    Song paths are rebuilt from each folder's current location, so a moved
        //    app data folder (reinstall/update) no longer forces a full rescan.
        let db = self.db
        let allKeys = bookmarks.allKeys
        let stored = await Task.detached(priority: .userInitiated) {
            db.setFolderLocations(restored)
            db.importLegacyJSONIfNeeded(libraryURL: FilePersistence.libraryURL,
                                        playlistsURL: FilePersistence.playlistsURL,
                                        bookmarkKeys: allKeys)
            return db.fetchSongs()
        }.value

        if !stored.isEmpty {
            // 3) Fast start from the database, then drop anything whose file is gone (memory only).
            self.songs = stored
            ArtworkThumbnails.shared.prewarm(stored.compactMap(\.artworkID))
            scheduleRebuildAlbumBuckets()
            _ = await pruneMissingFiles(updateDisk: false)
            startAlbumLookups()
        } else {
            // 4) Nothing stored yet: scan the restored folders.
            var loaded: [Song] = []
            var lookups: [(items: [OnlineLookup], folder: URL)] = []
            for (key, folder) in restored {
                db.saveFolder(key: key, url: folder)
                let result = await loadAndEnrichSongs(from: folder)
                loaded.append(contentsOf: result.songs)
                lookups.append((result.needsLookup, folder))
            }
            self.songs = loaded
            scheduleRebuildAlbumBuckets()
            db.saveSongs(loaded)
            for l in lookups { startOnlineLookups(l.items, in: l.folder) }
            startAlbumLookups()
        }
    }

    // MARK: - Sorted / searched lists (done by the database)

    func songs(sortedBy sort: SongSortOption) async -> [Song] {
        let db = self.db
        let ids = await Task.detached(priority: .userInitiated) { db.songIDs(sortedBy: sort) }.value
        return songs(forIDs: ids, appendingMissing: true)
    }

    func searchSongs(_ query: String) async -> [Song] {
        let db = self.db
        let ids = await Task.detached(priority: .userInitiated) { db.searchSongIDs(query) }.value
        return songs(forIDs: ids, appendingMissing: false)
    }

    /// For song pickers (playlists): everything A–Z when the query is empty, otherwise search results.
    func pickerSongs(matching query: String) async -> [Song] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? await songs(sortedBy: .title)
            : await searchSongs(query)
    }

    /// Maps database IDs to the songs in memory (skipping ones pruned this session).
    /// `appendingMissing` adds any in-memory songs the database didn't return, so nothing vanishes from a full list.
    private func songs(forIDs ids: [String], appendingMissing: Bool) -> [Song] {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = ids.compactMap { byID[$0] }
        if appendingMissing, result.count < songs.count {
            let returned = Set(ids)
            result.append(contentsOf: songs.filter { !returned.contains($0.id) })
        }
        return result
    }

    // MARK: - Import / Scan

    func loadSongs(from folderURL: URL) async {
        await importAndEnrich(folderURL)
    }

    /// Import a folder: songs appear as soon as their tags are read; songs with
    /// incomplete tags are then looked up online in the background and updated in place.
    func importAndEnrich(_ folderURL: URL) async {
        let result = await loadAndEnrichSongs(from: folderURL)
        guard !result.songs.isEmpty else { return }
        await appendSongs(result.songs, from: folderURL)
        BookmarkStore.shared.saveBookmark(forFolder: folderURL)
        startOnlineLookups(result.needsLookup, in: folderURL)
    }

    typealias OnlineLookup = (raw: Song, shown: Song)

    /// Fast, offline part of import (tags + cleanup + album naming). Never touches the network.
    private func loadAndEnrichSongs(from folderURL: URL) async -> (songs: [Song], needsLookup: [OnlineLookup]) {
        let scan = await SongLoader.scanLocal(from: folderURL)
        guard !scan.songs.isEmpty else { return ([], []) }

        var cleaned: [Song] = []
        cleaned.reserveCapacity(scan.songs.count)
        for s in scan.songs { cleaned.append(await enrich(song: s)) }

        // Pick a final album display name and persist mapping for this folder
        let finalAlbumName = resolveFinalAlbumName(from: cleaned, folderURL: folderURL)
        albumMappings[folderURL.path] = finalAlbumName
        AlbumMappingStore.save(albumMappings)

        // Rewrite album field so grouping is stable
        return (renameSongs(cleaned, withAlbumName: finalAlbumName), scan.needsLookup)
    }

    /// Slow, online part of import. Runs one song at a time (MusicBrainz allows ~1 request/sec)
    /// and updates each song in the library as its result arrives.
    private func startOnlineLookups(_ items: [OnlineLookup], in folderURL: URL) {
        guard !items.isEmpty else { startAlbumLookups(); return }
        Task { [weak self] in
            var found: [Song] = []
            for item in items {
                let improved = await SongLoader.lookUpOnline(raw: item.raw, shown: item.shown)
                guard let self else { return }
                let cleaned = await self.enrich(song: improved)
                found.append(cleaned)
                self.applyLookup(cleaned)
            }
            self?.refreshAlbumName(for: folderURL, using: found)
            self?.startAlbumLookups()
        }
    }

    // MARK: - Album details (year, genre, cover, track numbers, album-name-as-artist tags)

    private var albumLookupTask: Task<Void, Never>?
    private var albumLookupRequested = false

    /// Looks up albums that are missing details, one at a time in the background.
    /// Safe to call often: if a pass is running, one more pass runs after it.
    func startAlbumLookups() {
        guard albumLookupTask == nil else { albumLookupRequested = true; return }
        albumLookupTask = Task { [weak self] in
            await self?.runAlbumLookups()
            guard let self else { return }
            self.albumLookupTask = nil
            if self.albumLookupRequested {
                self.albumLookupRequested = false
                self.startAlbumLookups()
            }
        }
    }

    private func runAlbumLookups() async {
        let db = self.db
        let defaultID = SongLoader.defaultCoverArtworkID
        for group in AlbumLookup.groups(in: songs, defaultArtworkID: defaultID) {
            if Task.isCancelled { return }
            let key = AlbumLookup.key(album: group.album, artist: group.artist)

            // Use the saved result when there is one; search again only for albums
            // not found last time, and only once they're old enough to retry.
            var info = await Task.detached { db.albumInfo(key: key) }.value
            if info == nil || (!info!.found && Date().timeIntervalSince(info!.checkedAt) > AlbumLookup.retryNotFoundAfter) {
                guard let fresh = await AlbumLookup.lookUp(album: group.album, artist: group.artist,
                                                           songCount: group.songIDs.count) else {
                    print("💿 Album lookup failed (will retry later): \(group.album)")
                    continue
                }
                db.saveAlbumInfo(fresh)
                info = fresh
                print(fresh.found
                      ? "💿 Album found: \(group.album) → \(fresh.title ?? "?") (\(fresh.year ?? "no year"), \(fresh.genre ?? "no genre"))"
                      : "💿 Album not found: \(group.album) — \(group.artist)")
            }
            guard let info, info.found else { continue }

            var coverID: String?
            if group.needsCover, let data = await AlbumLookup.coverArt(for: info) {
                coverID = await Task.detached { ArtworkStore.shared.save(data) }.value
            }
            applyAlbumInfo(info, coverID: coverID, to: group)
        }
    }

    private func applyAlbumInfo(_ info: AlbumInfo, coverID: String?, to group: AlbumLookup.Group) {
        let ids = Set(group.songIDs)
        var updated = songs
        var changed: [Song] = []
        for i in updated.indices where ids.contains(updated[i].id) {
            let filled = AlbumLookup.apply(info, to: updated[i], album: group.album,
                                           coverID: coverID, defaultArtworkID: SongLoader.defaultCoverArtworkID)
            if filled != updated[i] {
                updated[i] = filled
                changed.append(filled)
            }
        }
        guard !changed.isEmpty else { return }

        songs = updated   // one update for the whole album
        for s in changed { songMetadataCache.removeValue(forKey: s.id) }  // rows read the song itself again
        db.saveSongs(changed)
        if let coverID { ArtworkThumbnails.shared.prewarm([coverID]) }
        scheduleRebuildAlbumBuckets()
        print("💿 Album details applied: \(group.album) — \(changed.count) song\(changed.count == 1 ? "" : "s") updated")
    }

    /// Swap in an improved song, keeping its current album so album groups don't flicker mid-import.
    private func applyLookup(_ improved: Song) {
        guard let i = songs.firstIndex(where: { $0.id == improved.id }) else { return }
        var updated = improved
        updated.album = songs[i].album
        guard updated != songs[i] else { return }
        songs[i] = updated
        db.saveSongs([updated])
        scheduleRebuildAlbumBuckets()
    }

    /// After all lookups for a folder finish, re-pick the album name now that online results are in.
    private func refreshAlbumName(for folderURL: URL, using found: [Song]) {
        let foundByID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let folderPath = folderURL.standardizedFileURL.path
        let folderSongs = songs.filter { $0.url.standardizedFileURL.path.hasPrefix(folderPath) }
        guard !folderSongs.isEmpty else { return }

        let candidates = folderSongs.map { foundByID[$0.id] ?? $0 }
        let name = resolveFinalAlbumName(from: candidates, folderURL: folderURL)
        guard name != albumMappings[folderURL.path] else { return }

        print("🏷️ Album name for \(folderURL.lastPathComponent) updated → \(name)")
        albumMappings[folderURL.path] = name
        AlbumMappingStore.save(albumMappings)
        var renamed: [Song] = []
        for i in songs.indices where songs[i].url.standardizedFileURL.path.hasPrefix(folderPath) {
            songs[i].album = name
            renamed.append(songs[i])
        }
        db.saveSongs(renamed)
        scheduleRebuildAlbumBuckets()
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
            artworkID: song.artworkID,
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
        }
        db.saveFolder(key: BookmarkStore.shared.key(forFolder: folderURL), url: folderURL)

        // De-dup by URL, append, persist just the new songs
        let existingURLs = Set(songs.map { $0.url })
        let filtered = newSongs.filter { !existingURLs.contains($0.url) }
        if !filtered.isEmpty {
            self.songs.append(contentsOf: filtered)
            ArtworkThumbnails.shared.prewarm(filtered.compactMap(\.artworkID))
            db.saveSongs(filtered)
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
        db.deleteSongs(ids: removed.map(\.id))
        db.deleteFolder(key: BookmarkStore.shared.key(forFolder: folder))
        BookmarkStore.shared.removeBookmark(forFolderPath: folder.path)
        albumMappings.removeValue(forKey: folder.path)
        AlbumMappingStore.save(albumMappings)
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
                    if updateDisk { self.db.deleteSongs(ids: Array(removedIDs)) }
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
        db.deleteSongs(ids: Array(idsToRemove))
        scheduleRebuildAlbumBuckets()
    }

    // MARK: - Thumbnails
    /// Cover thumbnail for a song (shared by every song with the same artwork). Nil if it has none.
    func thumbnailFor(song: Song, side: CGSize) async -> UIImage? {
        guard let id = song.artworkID else { return nil }
        return await ArtworkThumbnails.shared.thumbnail(for: id)
    }

    // MARK: - Helpers

    func isMetadataIncomplete(_ songs: [Song]) -> Bool {
        guard songs.count > 1 else { return false }
        let names = Set(songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) })
        let hasUnknowns = names.contains("No Album") || names.contains("Unknown Album")
        return names.count > 1 || hasUnknowns
    }

    private func renameSongs(_ songs: [Song], withAlbumName albumName: String) -> [Song] {
        // Copy-and-modify keeps every other field (MusicBrainz ID, link, tags) intact.
        songs.map { var s = $0; s.album = albumName; return s }
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
