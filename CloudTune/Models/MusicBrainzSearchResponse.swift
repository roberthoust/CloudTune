//
//  MusicBrainzSearchResponse.swift
//  CloudTune
//
//  Created by Robert Houst on 7/31/25.
//


struct MusicBrainzSearchResponse: Codable {
    let recordings: [Recording]
}

struct Recording: Codable {
    let title: String
    let releases: [Release]?
    let artistCredit: [ArtistCredit]
}

struct Release: Codable {
    let id: String
    let title: String
    let date: String?       // e.g., "2018-06-29"
    let status: String?     // e.g., "Official"
}

struct ArtistCredit: Codable {
    let name: String
}
