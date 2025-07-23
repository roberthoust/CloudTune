import Foundation

struct Playlist: Identifiable, Codable {
    let id: String
    var name: String
    var coverArtFilename: String?
    var songIDs: [String]

    init(id: String = UUID().uuidString, name: String, coverArtFilename: String? = nil, songIDs: [String]) {
        self.id = id
        self.name = name
        self.coverArtFilename = coverArtFilename
        self.songIDs = songIDs
    }
}
