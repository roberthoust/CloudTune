import Foundation
import SwiftUI
import CryptoKit

struct Song: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var url: URL
    /// ID of the cover in `ArtworkStore`. Only the ID is saved in Library.json, not the image bytes.
    var artworkID: String?
    var musicBrainzReleaseID: String?   // <- For fetching cover art from MusicBrainz

    /// Cover image bytes, loaded from `ArtworkStore` on demand. Setting it stores the bytes there.
    var artwork: Data? {
        get { artworkID.flatMap { ArtworkStore.shared.data(for: $0) } }
        set { artworkID = newValue.map { ArtworkStore.shared.save($0) } }
    }

    var genre: String
    var year: String
    var trackNumber: Int
    var discNumber: Int
    var externalURL: String
    var tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, url
        case artworkID
        case artwork // legacy: raw image bytes from older Library.json files (read-only)
        case genre, year, trackNumber, discNumber
        case musicBrainzReleaseID
        case externalURL, tags
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        url: URL,
        artwork: Data? = nil,
        artworkID: String? = nil,
        musicBrainzReleaseID: String? = nil,
        genre: String = "",
        year: String = "",
        trackNumber: Int = 0,
        discNumber: Int = 0,
        externalURL: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.url = url
        self.artworkID = artworkID ?? artwork.map { ArtworkStore.shared.save($0) }
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.externalURL = externalURL
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.album = try container.decode(String.self, forKey: .album)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.url = try container.decode(URL.self, forKey: .url)
        if let id = try container.decodeIfPresent(String.self, forKey: .artworkID) {
            self.artworkID = id
        } else if let legacy = try container.decodeIfPresent(Data.self, forKey: .artwork) {
            // Old format: move the embedded bytes into ArtworkStore (one-time migration).
            self.artworkID = ArtworkStore.shared.save(legacy)
        } else {
            self.artworkID = nil
        }

        self.musicBrainzReleaseID = try container.decodeIfPresent(String.self, forKey: .musicBrainzReleaseID)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        self.year = try container.decodeIfPresent(String.self, forKey: .year) ?? ""
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        self.discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        self.externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL) ?? ""
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(duration, forKey: .duration)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(artworkID, forKey: .artworkID)
        try container.encodeIfPresent(musicBrainzReleaseID, forKey: .musicBrainzReleaseID)
        try container.encode(genre, forKey: .genre)
        try container.encode(year, forKey: .year)
        try container.encode(trackNumber, forKey: .trackNumber)
        try container.encode(discNumber, forKey: .discNumber)
        try container.encode(externalURL, forKey: .externalURL)
        try container.encode(tags, forKey: .tags)
    }

    var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }

    var displayTitle: String {
        title
    }

    var displayAlbum: String {
        album
    }

    var displayGenre: String {
        genre
    }

    var displayYear: String {
        year
    }

    var displayTrackNumber: Int {
        trackNumber
    }

    var displayDiscNumber: Int {
        discNumber
    }

    var displayExternalURL: String {
        externalURL
    }

    static func generateStableID(from url: URL) -> String {
        let path = url.standardizedFileURL.path
        let data = Data(path.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}
extension Song {
    var fileURL: URL {
        return url
    }
}
