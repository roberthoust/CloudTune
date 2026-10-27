//
//  SongMetadata.swift
//  CloudTune
//
//  Created by Robert Houst on 7/31/25.
//

import Foundation

struct SongMetadata: Codable {
    var title: String
    var artist: String
    var album: String
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var discNumber: Int?
    var artwork: Data?
}

actor SongMetadataManager {
    static let shared = SongMetadataManager()

    private var cache: [String: SongMetadata] = [:]

    private init() {}

    func updateMetadata(for id: String, with metadata: SongMetadata) {
        cache[id] = metadata
    }

    func metadata(for song: Song) async -> SongMetadata {
        if let enriched = cache[song.id] {
            return enriched
        }

        return SongMetadata(
            title: song.title,
            artist: song.artist,
            album: song.album,
            genre: song.genre.isEmpty ? nil : song.genre,
            year: song.year.isEmpty ? nil : song.year,
            trackNumber: song.trackNumber == 0 ? nil : song.trackNumber,
            discNumber: song.discNumber == 0 ? nil : song.discNumber
        )
    }

    func clearMetadata(for id: String) async {
        cache.removeValue(forKey: id)
    }

    func preload(metadataDict: [String: SongMetadata]) async {
        self.cache = metadataDict
    }

    func allMetadata() async -> [String: SongMetadata] {
        return cache
    }

    /// Enrich a single song's metadata
    func enrichMetadata(for song: Song) async -> SongMetadata {
        // Drop leading track numbers / "Artist - " (keeps titles like "7 Rings" intact)
        let trimmedTitle = SongTitle.cleaned(song.title, artist: song.artist, trackNumber: song.trackNumber)

        let enriched = SongMetadata(
            title: trimmedTitle.isEmpty ? song.title : trimmedTitle,
            artist: song.artist.isEmpty ? "Unknown Artist" : song.artist,
            album: song.album.isEmpty ? "Unknown Album" : song.album,
            genre: song.genre.isEmpty ? nil : song.genre,
            year: song.year.isEmpty ? nil : song.year,
            trackNumber: song.trackNumber == 0 ? nil : song.trackNumber,
            discNumber: song.discNumber == 0 ? nil : song.discNumber,
            artwork: nil // never read; avoids loading image bytes for every song
        )

        await updateMetadata(for: song.id, with: enriched)
        return enriched
    }

    /// Enrich an array of songs asynchronously, returning an array of enriched Song objects
    func enrichMetadata(for songs: [Song]) async -> [Song] {
        var enrichedSongs: [Song] = []

        for song in songs {
            let enrichedMeta = await enrichMetadata(for: song)
            let enrichedSong = Song(
                id: song.id,
                title: enrichedMeta.title,
                artist: enrichedMeta.artist,
                album: enrichedMeta.album,
                duration: song.duration,
                url: song.url,
                artworkID: song.artworkID,
                genre: enrichedMeta.genre ?? song.genre,
                year: enrichedMeta.year ?? song.year,
                trackNumber: enrichedMeta.trackNumber ?? song.trackNumber,
                discNumber: enrichedMeta.discNumber ?? song.discNumber
            )
            enrichedSongs.append(enrichedSong)
        }

        return enrichedSongs
    }
}
