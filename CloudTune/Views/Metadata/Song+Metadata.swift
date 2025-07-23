//
//  Song+Metadata.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//

import Foundation

extension Song {
    var displayTitle: String {
        SongMetadataManager.shared.metadata(for: self).title
    }

    var displayArtist: String {
        SongMetadataManager.shared.metadata(for: self).artist
    }

    var displayAlbum: String {
        SongMetadataManager.shared.metadata(for: self).album
    }

    var displayGenre: String? {
        SongMetadataManager.shared.metadata(for: self).genre
    }

    var displayYear: String? {
        SongMetadataManager.shared.metadata(for: self).year
    }

    var displayTrackNumber: Int? {
        SongMetadataManager.shared.metadata(for: self).trackNumber
    }

    var displayDiscNumber: Int? {
        SongMetadataManager.shared.metadata(for: self).discNumber
    }
}
