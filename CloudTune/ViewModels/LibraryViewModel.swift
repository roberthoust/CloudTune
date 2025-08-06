import Foundation
import SwiftUI
import AVFoundation

class LibraryViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var savedFolders: [URL] = []
    @Published var playlists: [Playlist] = []
    @Published var albumMappings: [String: String] = [:]
    @Published var songMetadataCache: [String: SongMetadata] = [:]
    @Published var selectedAlbumID: String?

    var albums: [String] {
        Set(songs.map { $0.album }).sorted()
    }

    var allSongs: [Song] {
        songs
    }

    init() {
        albumMappings = AlbumMappingStore.load()
        Task {
            await loadLibraryOnLaunch()
        }
    }

    func loadLibraryOnLaunch() async {
        print("🔁 Restoring bookmarks and loading songs...")
        let restoredFolders = BookmarkManager.restoreBookmarkedFolders()
        let uniqueFolders = Dictionary(grouping: restoredFolders, by: { $0.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values
        await MainActor.run {
            savedFolders = Array(uniqueFolders)
        }
        FilePersistence.saveFolderList(savedFolders)

        let cachedSongs = FilePersistence.loadLibrary()
        if !cachedSongs.isEmpty {
            await MainActor.run {
                self.songs = cachedSongs
            }
            return
        }

        var loadedSongs: [Song] = []
        for folder in savedFolders {
            let enriched = await loadAndEnrichSongs(from: folder)
            loadedSongs.append(contentsOf: enriched)
        }

        await MainActor.run {
            self.songs = loadedSongs
        }
        FilePersistence.saveLibrary(loadedSongs)
    }

    func loadSongs(from folderURL: URL) async {
        print("📁 Loading songs from: \(folderURL.path)")
        let enriched = await loadAndEnrichSongs(from: folderURL)

        if enriched.isEmpty {
            print("⚠️ No valid songs found in this folder.")
            return
        }

        await appendSongs(enriched, from: folderURL)
        BookmarkManager.saveFolderBookmark(url: folderURL)
    }

    @MainActor
    func importAndEnrich(_ folderURL: URL) async {
        print("📁 Importing and enriching: \(folderURL.lastPathComponent)")

        let enriched = await loadAndEnrichSongs(from: folderURL)
        if enriched.isEmpty {
            print("⚠️ No valid songs found in this folder.")
            return
        }

        await appendSongs(enriched, from: folderURL)
        BookmarkManager.saveFolderBookmark(url: folderURL)
    }

    private func loadAndEnrichSongs(from folderURL: URL) async -> [Song] {
        let rawSongs = await SongLoader.loadSongs(from: folderURL)
        print("🎵 Found \(rawSongs.count) raw songs in folder \(folderURL.lastPathComponent)")
        guard !rawSongs.isEmpty else { return [] }

        do {
            let enrichedSongs = try await withThrowingTaskGroup(of: Song.self) { group in
                for song in rawSongs {
                    group.addTask {
                        return await self.enrich(song: song)
                    }
                }
                return try await group.reduce(into: [Song]()) { $0.append($1) }
            }

            let finalAlbumName = resolveFinalAlbumName(from: enrichedSongs, folderURL: folderURL)
            await MainActor.run {
                albumMappings[folderURL.path] = finalAlbumName
                AlbumMappingStore.save(albumMappings)
            }

            return renameSongs(enrichedSongs, withAlbumName: finalAlbumName)
        } catch {
            print("❌ Metadata enrichment failed: \(error)")
            return rawSongs
        }
    }

    private func enrich(song: Song) async -> Song {
        let meta = await SongMetadataManager.shared.enrichMetadata(for: song)

        await MainActor.run {
            self.songMetadataCache[song.id] = meta
        }

        let cleanArtist = !(meta.artist ?? "").isEmpty ? meta.artist : song.artist
        let cleanAlbum = !(meta.album ?? "").isEmpty ? meta.album : song.album
        let cleanGenre = meta.genre?.isEmpty == false ? meta.genre : song.genre
        let cleanYear = meta.year ?? song.year
        let cleanTrack = meta.trackNumber ?? song.trackNumber
        let cleanDisc = meta.discNumber ?? song.discNumber

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
        let enrichedAlbumNames = songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
        let counted = Dictionary(grouping: enrichedAlbumNames, by: { $0 })
            .mapValues { $0.count }
            .filter { !$0.key.isEmpty && $0.key.lowercased() != "unknown album" }

        if let (mostCommon, count) = counted
            .filter({ $0.key.lowercased() != "no album" })
            .max(by: { $0.value < $1.value }),
            Double(count) / Double(songs.count) >= 0.4 {
            return mostCommon
        } else {
            return folderURL.lastPathComponent
        }
    }

    private func appendSongs(_ newSongs: [Song], from folderURL: URL) async {
        let normalizedPath = folderURL.standardizedFileURL.path
        let existingPaths = Set(savedFolders.map { $0.standardizedFileURL.path })

        if !existingPaths.contains(normalizedPath) {
            await MainActor.run {
                savedFolders.append(folderURL.standardizedFileURL)
                FilePersistence.saveFolderList(savedFolders)
            }
        }

        let existingURLs = Set(songs.map { $0.url })
        let filtered = newSongs.filter { !existingURLs.contains($0.url) }

        await MainActor.run {
            self.songs.append(contentsOf: filtered)
            FilePersistence.saveLibrary(self.songs)
        }
    }

    func removeFolder(_ folder: URL) {
        savedFolders.removeAll { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
        songs.removeAll { $0.url.standardizedFileURL.path.contains(folder.standardizedFileURL.path) }

        BookmarkManager.removeBookmark(for: folder)
        albumMappings.removeValue(forKey: folder.path)

        AlbumMappingStore.save(albumMappings)
        FilePersistence.saveFolderList(savedFolders)
        FilePersistence.saveLibrary(songs)
    }

    func isMetadataIncomplete(_ songs: [Song]) -> Bool {
        guard songs.count > 1 else { return false }

        let albumNames = Set(songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) })
        let hasUnknowns = albumNames.contains("No Album") || albumNames.contains("Unknown Album")

        return albumNames.count > 1 || hasUnknowns
    }

    private func renameSongs(_ songs: [Song], withAlbumName albumName: String) -> [Song] {
        return songs.map {
            Song(id: $0.id, title: $0.title, artist: $0.artist, album: albumName,
                 duration: $0.duration, url: $0.url, artwork: $0.artwork,
                 genre: $0.genre, year: $0.year, trackNumber: $0.trackNumber, discNumber: $0.discNumber)
        }
    }
}
