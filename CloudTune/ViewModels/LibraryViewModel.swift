import Foundation
import SwiftUI

class LibraryViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var savedFolders: [URL] = []

    // 🧠 For smart album import prompting
    @Published var showAlbumPrompt: Bool = false
    @Published var pendingFolder: URL?
    @Published var pendingSongs: [Song] = []
    @Published var albumMappings: [String: String] = [:]

    init() {
        albumMappings = AlbumMappingStore.load()
        loadLibraryOnLaunch()
    }

    /// Called on App launch
    func loadLibraryOnLaunch() {
        print("🔁 Restoring bookmarks and loading songs...")

        // Restore bookmarked folders with access
        let restoredFolders = BookmarkManager.restoreBookmarkedFolders()

        // Deduplicate based on normalized paths
        let uniqueFolders = Dictionary(grouping: restoredFolders, by: { $0.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values
        savedFolders = Array(uniqueFolders)
        FilePersistence.saveFolderList(savedFolders)

        // Attempt to load cached library first
        let cachedSongs = FilePersistence.loadLibrary()

        if !cachedSongs.isEmpty {
            self.songs = cachedSongs
        } else {
            // If no cached songs, rescan folders
            var loadedSongs: [Song] = []
            for folder in savedFolders {
                let songsFromFolder = SongLoader.loadSongs(from: folder)
                let songsWithOverride: [Song]

                if let overrideName = albumMappings[folder.path] {
                    songsWithOverride = songsFromFolder.map {
                        Song(id: $0.id, title: $0.title, artist: $0.artist, album: overrideName,
                             duration: $0.duration, url: $0.url, artwork: $0.artwork,
                             genre: $0.genre, year: $0.year, trackNumber: $0.trackNumber, discNumber: $0.discNumber)
                    }
                } else {
                    songsWithOverride = songsFromFolder
                }

                loadedSongs.append(contentsOf: songsWithOverride)
            }

            self.songs = loadedSongs
            FilePersistence.saveLibrary(loadedSongs)
        }
    }

    /// Called when user selects a new folder
    func loadSongs(from folderURL: URL) {
        print("📁 Loading songs from: \(folderURL.path)")

        let newSongs = SongLoader.loadSongs(from: folderURL)

        // Save bookmark for persistent access
        BookmarkManager.saveFolderBookmark(url: folderURL)

        if let overrideName = albumMappings[folderURL.path] {
            let renamed = newSongs.map {
                Song(id: $0.id, title: $0.title, artist: $0.artist, album: overrideName,
                     duration: $0.duration, url: $0.url, artwork: $0.artwork,
                     genre: $0.genre, year: $0.year, trackNumber: $0.trackNumber, discNumber: $0.discNumber)
            }
            appendSongs(renamed, from: folderURL)
            return
        }

        if isMetadataIncomplete(newSongs) {
            pendingFolder = folderURL
            pendingSongs = newSongs
            showAlbumPrompt = true
        } else {
            appendSongs(newSongs, from: folderURL)
        }
    }

    /// Called after user confirms treating folder as album
    func applyAlbumOverride(name: String) {
        guard let folder = pendingFolder else { return }

        let renamed = pendingSongs.map {
            Song(id: $0.id, title: $0.title, artist: $0.artist, album: name,
                 duration: $0.duration, url: $0.url, artwork: $0.artwork,
                 genre: $0.genre, year: $0.year, trackNumber: $0.trackNumber, discNumber: $0.discNumber)
        }

        albumMappings[folder.path] = name
        AlbumMappingStore.save(albumMappings)
        appendSongs(renamed, from: folder)

        // Clear state
        pendingFolder = nil
        pendingSongs = []
        showAlbumPrompt = false
    }

    /// Remove a folder and all associated songs + bookmark
    func removeFolder(_ folder: URL) {
        savedFolders.removeAll { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
        songs.removeAll { $0.url.standardizedFileURL.path.contains(folder.standardizedFileURL.path) }

        BookmarkManager.removeBookmark(for: folder)
        albumMappings.removeValue(forKey: folder.path)

        AlbumMappingStore.save(albumMappings)
        FilePersistence.saveFolderList(savedFolders)
        FilePersistence.saveLibrary(songs)
    }

    /// Add songs to library + track folder
    private func appendSongs(_ newSongs: [Song], from folderURL: URL) {
        let normalizedPath = folderURL.standardizedFileURL.path
        let existingPaths = Set(savedFolders.map { $0.standardizedFileURL.path })

        if !existingPaths.contains(normalizedPath) {
            savedFolders.append(folderURL.standardizedFileURL)
            FilePersistence.saveFolderList(savedFolders)
        }

        // Prevent duplicates
        let existingURLs = Set(songs.map { $0.url })
        let filtered = newSongs.filter { !existingURLs.contains($0.url) }

        DispatchQueue.main.async {
            self.songs.append(contentsOf: filtered)
            FilePersistence.saveLibrary(self.songs)
        }
    }

    /// Detect folders with inconsistent album metadata
    func isMetadataIncomplete(_ songs: [Song]) -> Bool {
        guard songs.count > 1 else { return false }

        let albumNames = Set(songs.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) })
        let hasUnknowns = albumNames.contains("No Album") || albumNames.contains("Unknown Album")

        return albumNames.count > 1 || hasUnknowns
    }

    func updateMetadata(for songID: String, with metadata: SongMetadataUpdate) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        let old = songs[index]

        let updatedSong = Song(
            id: old.id,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: old.duration,
            url: old.url,
            artwork: old.artwork,
            genre: metadata.genre ?? "",
            year: metadata.year ?? "",
            trackNumber: metadata.trackNumber ?? 0,
            discNumber: metadata.discNumber ?? 0
        )

        songs[index] = updatedSong
        FilePersistence.saveLibrary(songs)
    }
}
