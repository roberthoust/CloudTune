//
//  SongMetadataUpdate.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//


import Foundation

struct SongMetadataUpdate: Codable {
    var title: String
    var artist: String
    var album: String
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var discNumber: Int?
}
extension SongMetadataUpdate {
    init(from song: Song) {
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
        self.genre = nil
        self.year = nil
        self.trackNumber = nil
        self.discNumber = nil
    }
}
