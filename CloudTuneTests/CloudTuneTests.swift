//
//  CloudTuneTests.swift
//  CloudTuneTests
//
//  Created by Robert Houst on 7/17/25.
//

import AVFoundation
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

    @Test func scanLocalReadsFolderWithoutNetwork() async throws {
        // A folder with three untagged WAV files.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for name in ["01 First", "02 Second", "03 Third"] {
            let url = folder.appendingPathComponent(name).appendingPathExtension("wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            buffer.frameLength = 4410 // 0.1 s of silence
            try file.write(from: buffer)
        }

        let scan = await SongLoader.scanLocal(from: folder)

        #expect(scan.songs.count == 3)
        #expect(Set(scan.songs.map(\.trackNumber)) == [1, 2, 3])
        #expect(scan.songs.allSatisfy { $0.artworkID != nil })   // default cover filled in
        // Folder-name hints fill the missing album/artist offline, so nothing needs the network.
        #expect(scan.needsLookup.isEmpty)
        #expect(scan.songs.allSatisfy { !MetadataEnricher.needsOnlineLookup($0) })
        // Nothing was written into the music folder (no .metadata sidecars during the fast pass).
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".metadata").path))
    }

    @Test func onlineLookupOnlyForIncompleteSongs() {
        let url = URL(fileURLWithPath: "/x.mp3")
        let complete = Song(title: "T", artist: "A", album: "Al", duration: 120, url: url)
        #expect(!MetadataEnricher.needsOnlineLookup(complete))
        #expect(MetadataEnricher.needsOnlineLookup(Song(title: "T", artist: "A", album: "No Album", duration: 120, url: url)))
        #expect(MetadataEnricher.needsOnlineLookup(Song(title: "T", artist: "Unknown Artist", album: "Al", duration: 120, url: url)))
        #expect(MetadataEnricher.needsOnlineLookup(Song(title: "T", artist: "A", album: "Al", duration: 0, url: url)))
    }

    @Test func identicalArtworkIsStoredOnce() {
        let art = Data("same cover".utf8)
        let a = Song(title: "1", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/a.mp3"), artwork: art)
        let b = Song(title: "2", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/b.mp3"), artwork: art)
        #expect(a.artworkID == b.artworkID)
    }
}
