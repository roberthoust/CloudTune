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

    init() {
        loadPlaylists()
    }

    func createPlaylist(name: String, songIDs: [String], coverArtFilename: String? = nil) {
        let newPlaylist = Playlist(name: name, coverArtFilename: coverArtFilename, songIDs: songIDs)
        playlists.append(newPlaylist)
        savePlaylists()
    }

    func addPlaylist(_ playlist: Playlist) {
        playlists.append(playlist)
        savePlaylists()
    }

    func updatePlaylist(_ updated: Playlist, withNewImage image: UIImage? = nil) {
        if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
            var updatedPlaylist = updated

            if let image = image {
                let newFilename = safeFilename(for: updated.name)

                if let oldFilename = updated.coverArtFilename, oldFilename != newFilename {
                    let oldPath = getCoversDirectory().appendingPathComponent(oldFilename)
                    try? FileManager.default.removeItem(at: oldPath)
                }

                if let saved = saveCoverImage(image: image, as: newFilename) {
                    updatedPlaylist.coverArtFilename = saved
                }
            }

            playlists[index] = updatedPlaylist
            savePlaylists()
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        if let filename = playlist.coverArtFilename {
            let path = getCoversDirectory().appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: path)
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func savePlaylists() {
        do {
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: playlistsFile)
        } catch {
            print("❌ Error saving playlists:", error)
        }
    }

    func loadPlaylists() {
        do {
            let data = try Data(contentsOf: playlistsFile)
            playlists = try JSONDecoder().decode([Playlist].self, from: data)

            for playlist in playlists {
                if let filename = playlist.coverArtFilename {
                    let fullPath = getCoversDirectory().appendingPathComponent(filename)
                    print("🖼 Cover image exists for \(playlist.name):", FileManager.default.fileExists(atPath: fullPath.path))
                }
            }
        } catch {
            print("❌ Error loading playlists:", error)
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

        let path = getCoversDirectory().appendingPathComponent(filename)
        do {
            try data.write(to: path)
            return filename
        } catch {
            print("❌ Failed to save cover image:", error)
            return nil
        }
    }

    func getCoversDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}
