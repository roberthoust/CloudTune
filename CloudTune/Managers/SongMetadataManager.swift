//
//  SongMetadataManager.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//

import Foundation

class SongMetadataManager: ObservableObject {
    static let shared = SongMetadataManager()

    private var overrides: [String: SongMetadataUpdate] = [:]

    private let metadataFile: URL = {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docDir.appendingPathComponent("ModifiedMetadata.json")
    }()

    private init() {
        loadMetadata()
    }

    func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataFile.path) else { return }
        do {
            let data = try Data(contentsOf: metadataFile)
            overrides = try JSONDecoder().decode([String: SongMetadataUpdate].self, from: data)
        } catch {
            print("❌ Failed to load metadata overrides:", error)
        }
    }

    func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: metadataFile, options: [.atomic])
        } catch {
            print("❌ Failed to save metadata overrides:", error)
        }
    }

    func updateMetadata(for songID: String, with newData: SongMetadataUpdate) {
        overrides[songID] = newData
        saveMetadata()
    }

    func metadata(for song: Song) -> SongMetadataUpdate {
        return overrides[song.id] ?? SongMetadataUpdate(from: song)
    }
}
