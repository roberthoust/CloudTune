//
//  PlaylistViewModel.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//

import Foundation
import SwiftUI

class PlaylistViewModel: ObservableObject {
    @Published var playlists: [Playlist] = []

    private let playlistsFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("playlists.json")

    private let ioQueue = DispatchQueue(label: "PlaylistIO", qos: .utility)
    private var pendingSaveWork: DispatchWorkItem?

    init() {
        loadPlaylists()
    }

    /// Adds a new playlist; the cover (if any) is saved in the background.
    @discardableResult
    func createPlaylist(name: String, songIDs: [String], cover: UIImage? = nil) -> Playlist {
        let playlist = Playlist(name: name, songIDs: songIDs)
        playlists.append(playlist)
        scheduleSavePlaylists()
        if let cover { updatePlaylist(playlist, withNewImage: cover) }
        return playlist
    }

    /// Saves changes to a playlist. A new cover is written in the background and then
    /// applied to whatever the playlist looks like by then (so later edits aren't overwritten).
    func updatePlaylist(_ updated: Playlist, withNewImage image: UIImage? = nil) {
        guard let index = playlists.firstIndex(where: { $0.id == updated.id }) else { return }
        playlists[index] = updated
        scheduleSavePlaylists()

        guard let image else { return }
        let id = updated.id
        let oldFilename = updated.coverArtFilename
        ioQueue.async {
            guard let saved = self.saveCoverImage(image: image, as: Self.coverFilename(for: id)) else { return }
            if let oldFilename, oldFilename != saved {
                try? FileManager.default.removeItem(at: Self.getCoversDirectory().appendingPathComponent(oldFilename))
            }
            DispatchQueue.main.async {
                guard let i = self.playlists.firstIndex(where: { $0.id == id }) else { return }
                self.playlists[i].coverArtFilename = saved
                self.scheduleSavePlaylists()
            }
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        if let filename = playlist.coverArtFilename {
            let path = Self.getCoversDirectory().appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: path)
        }
        playlists.removeAll { $0.id == playlist.id }
        scheduleSavePlaylists()
    }

    func savePlaylists() {
        LibraryDatabase.shared.replacePlaylists(playlists)
    }

    func scheduleSavePlaylists(debounce: TimeInterval = 0.3) {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.ioQueue.async {
                self.savePlaylists()
            }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func loadPlaylists() {
        ioQueue.async {
            // The library loader imports the old playlists.json into the database on first
            // launch; make sure that has happened before reading.
            let db = LibraryDatabase.shared
            db.importLegacyJSONIfNeeded(libraryURL: FilePersistence.libraryURL,
                                        playlistsURL: self.playlistsFile,
                                        bookmarkKeys: BookmarkStore.shared.allKeys)
            let loadedPlaylists = db.fetchPlaylists()

            DispatchQueue.main.async {
                self.playlists = loadedPlaylists
            }
        }
    }

    // MARK: - Image Helpers

    /// One cover file per playlist, named by ID (names can repeat and change).
    static func coverFilename(for playlistID: String) -> String {
        "playlist_\(playlistID).jpg"
    }

    func saveCoverImage(image: UIImage, as filename: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }

        let path = Self.getCoversDirectory().appendingPathComponent(filename)
        do {
            try data.write(to: path)
            PlaylistCovers.shared.invalidate(filename)
            return filename
        } catch {
            print("❌ Failed to save cover image:", error)
            return nil
        }
    }

    static func getCoversDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}
