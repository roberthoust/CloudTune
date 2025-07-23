// AlbumMappingStore.swift
// CloudTune
//
// Created to persist folder-to-album name overrides

import Foundation

struct AlbumMappingStore {
    static let savePath: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomAlbumMap.json")
    }()

    /// Load album mappings from disk
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: savePath) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Save album mappings to disk
    static func save(_ mappings: [String: String]) {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        try? data.write(to: savePath)
    }
}
