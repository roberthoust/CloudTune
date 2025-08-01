import Foundation


struct Album: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let artist: String
    var coverArt: Data?
    var songs: [Song]

    init(title: String, artist: String, coverArt: Data? = nil, songs: [Song] = []) {
        self.id = "\(artist)-\(title)".lowercased().replacingOccurrences(of: " ", with: "_")
        self.title = title
        self.artist = artist
        self.coverArt = coverArt
        self.songs = songs
    }
}
