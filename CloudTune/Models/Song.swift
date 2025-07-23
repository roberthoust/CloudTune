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
    var artwork: Data?

    var genre: String
    var year: String
    var trackNumber: Int
    var discNumber: Int

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, url, artwork
        case genre, year, trackNumber, discNumber
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        url: URL,
        artwork: Data? = nil,
        genre: String = "",
        year: String = "",
        trackNumber: Int = 0,
        discNumber: Int = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.url = url
        self.artwork = artwork
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.album = try container.decode(String.self, forKey: .album)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.url = try container.decode(URL.self, forKey: .url)
        self.artwork = try container.decodeIfPresent(Data.self, forKey: .artwork)

        self.genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        self.year = try container.decodeIfPresent(String.self, forKey: .year) ?? ""
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        self.discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
    }
    
    static func generateStableID(from url: URL) -> String {
        let path = url.standardizedFileURL.path
        let data = Data(path.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}
