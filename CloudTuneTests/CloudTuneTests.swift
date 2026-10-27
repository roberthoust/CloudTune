//
//  CloudTuneTests.swift
//  CloudTuneTests
//
//  Created by Robert Houst on 7/17/25.
//

import Foundation
import Testing
@testable import CloudTune

struct CloudTuneTests {

    @Test func legacyArtworkMigratesOutOfLibraryJSON() throws {
        let art = Data((0..<4096).map { UInt8($0 % 251) })
        let legacyJSON = """
        [{"id":"abc","title":"T","artist":"A","album":"Al","duration":1.5,
          "url":"file:///tmp/song.mp3","artwork":"\(art.base64EncodedString())"}]
        """

        let songs = try JSONDecoder().decode([Song].self, from: Data(legacyJSON.utf8))
        let song = try #require(songs.first)

        // Bytes moved into ArtworkStore and are still readable through `artwork`.
        #expect(song.artworkID != nil)
        #expect(song.artwork == art)

        // Re-saving writes only the ID, never the image bytes.
        let reencoded = String(decoding: try JSONEncoder().encode(songs), as: UTF8.self)
        #expect(reencoded.contains("\"artworkID\""))
        #expect(!reencoded.contains("\"artwork\":"))

        // Round trip keeps the reference.
        let decodedAgain = try JSONDecoder().decode([Song].self, from: Data(reencoded.utf8))
        #expect(decodedAgain.first?.artwork == art)
    }

    @Test func identicalArtworkIsStoredOnce() {
        let art = Data("same cover".utf8)
        let a = Song(title: "1", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/a.mp3"), artwork: art)
        let b = Song(title: "2", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/b.mp3"), artwork: art)
        #expect(a.artworkID == b.artworkID)
    }
}
