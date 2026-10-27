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

    func createPlaylist(name: String, songIDs: [String], coverArtFilename: String? = nil) {
        let newPlaylist = Playlist(name: name, coverArtFilename: coverArtFilename, songIDs: songIDs)
        playlists.append(newPlaylist)
        scheduleSavePlaylists()
    }

    func addPlaylist(_ playlist: Playlist) {
        playlists.append(playlist)
        scheduleSavePlaylists()
    }

    func updatePlaylist(_ updated: Playlist, withNewImage image: UIImage? = nil) {
        if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
            var updatedPlaylist = updated

            if let image = image {
                ioQueue.async {
                    let newFilename = self.safeFilename(for: updated.name)

                    if let oldFilename = updated.coverArtFilename, oldFilename != newFilename {
                        let oldPath = Self.getCoversDirectory().appendingPathComponent(oldFilename)
                        try? FileManager.default.removeItem(at: oldPath)
                    }

                    if let saved = self.saveCoverImage(image: image, as: newFilename) {
                        DispatchQueue.main.async {
                            updatedPlaylist.coverArtFilename = saved
                            self.playlists[index] = updatedPlaylist
                            self.scheduleSavePlaylists()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.playlists[index] = updatedPlaylist
                            self.scheduleSavePlaylists()
                        }
                    }
                }
            } else {
                playlists[index] = updatedPlaylist
                scheduleSavePlaylists()
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

    func safeFilename(for name: String) -> String {
        let clean = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        return "playlist_\(clean).jpg"
    }

    func saveCoverImage(image: UIImage, for name: String) -> String? {
        let filename = safeFilename(for: name)
        return saveCoverImage(image: image, as: filename)
    }

    func saveCoverImage(image: UIImage, as filename: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }

        let path = Self.getCoversDirectory().appendingPathComponent(filename)
        do {
            try data.write(to: path)
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
