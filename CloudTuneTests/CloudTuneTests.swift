//
//  CloudTuneTests.swift
//  CloudTuneTests
//
//  Created by Robert Houst on 7/17/25.
//

import AVFoundation
import Foundation
import GRDB
import Testing
import UIKit
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

    // MARK: - Database

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func legacyJSONImportsOnceAndFollowsMovedFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Old install: folder lived under an old app container path.
        let oldFolderKey = "/var/mobile/Containers/Data/Application/OLD/Documents/Music"
        let inFolder = Song(id: "s1", title: "One", artist: "A", album: "Al", duration: 60,
                            url: URL(fileURLWithPath: oldFolderKey + "/Album/01 One.mp3"))
        let elsewhere = Song(id: "s2", title: "Two", artist: "A", album: "Al", duration: 60,
                             url: URL(fileURLWithPath: "/somewhere/else/02 Two.mp3"))
        let libraryURL = dir.appendingPathComponent("Library.json")
        let playlistsURL = dir.appendingPathComponent("playlists.json")
        try JSONEncoder().encode([inFolder, elsewhere]).write(to: libraryURL)
        try JSONEncoder().encode([Playlist(id: "p1", name: "Mix", songIDs: ["s2", "s1"])]).write(to: playlistsURL)

        let db = try LibraryDatabase(dbQueue: DatabaseQueue())
        db.importLegacyJSONIfNeeded(libraryURL: libraryURL, playlistsURL: playlistsURL, bookmarkKeys: [oldFolderKey])

        // New install: the same folder now resolves to a different container.
        let newFolder = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEW/Documents/Music")
        db.setFolderLocations([oldFolderKey: newFolder])
        let songs = db.fetchSongs()

        #expect(songs.map(\.id) == ["s1", "s2"])
        #expect(songs[0].url.path == newFolder.path + "/Album/01 One.mp3")   // followed the move
        #expect(songs[1].url.path == "/somewhere/else/02 Two.mp3")           // no folder → absolute path kept
        #expect(db.fetchPlaylists().first?.songIDs == ["s2", "s1"])          // order kept

        // Old files kept as backups, and a second run doesn't import again.
        #expect(FileManager.default.fileExists(atPath: libraryURL.path + ".migrated"))
        try JSONEncoder().encode([elsewhere]).write(to: libraryURL)
        db.importLegacyJSONIfNeeded(libraryURL: libraryURL, playlistsURL: playlistsURL, bookmarkKeys: [])
        #expect(db.fetchSongs().count == 2)
    }

    @Test func saveSongsWritesOnlyWhatChanged() throws {
        let db = try LibraryDatabase(dbQueue: DatabaseQueue())
        let folder = URL(fileURLWithPath: "/music")
        db.saveFolder(key: "/music", url: folder)

        var a = Song(id: "a", title: "A", artist: "X", album: "Al", duration: 1, url: folder.appendingPathComponent("a.mp3"))
        let b = Song(id: "b", title: "B", artist: "X", album: "Al", duration: 1, url: folder.appendingPathComponent("b.mp3"))
        db.saveSongs([a, b])

        a.title = "A (renamed)"
        db.saveSongs([a])
        db.deleteSongs(ids: ["b"])
        db.waitForPendingWrites()

        let songs = db.fetchSongs()
        #expect(songs.map(\.title) == ["A (renamed)"])
        #expect(songs.first?.url.path == "/music/a.mp3")
    }

    @Test func databaseSortsAndSearchesSongs() throws {
        let db = try LibraryDatabase(dbQueue: DatabaseQueue())
        let folder = URL(fileURLWithPath: "/music")
        db.saveFolder(key: "/music", url: folder)
        func song(_ id: String, _ title: String, _ artist: String, _ album: String = "Al") -> Song {
            Song(id: id, title: title, artist: artist, album: album, duration: 1, url: folder.appendingPathComponent("\(id).mp3"))
        }
        db.saveSongs([
            song("1", "The Zebra", "Beyoncé"),
            song("2", "Track 10", "ABBA"),
            song("3", "Track 2", "ABBA"),
            song("4", "01 - apple", "Coldplay", "Café Hits"),
        ])
        // No waitForPendingWrites: queries must see writes queued before them.

        #expect(db.songIDs(sortedBy: .recent) == ["4", "3", "2", "1"])
        // Track numbers and "The" are ignored, numbers compare naturally (2 before 10).
        #expect(db.songIDs(sortedBy: .title) == ["4", "3", "2", "1"])
        #expect(SongSortKey.sortKey("01 - Apple") == "apple")
        #expect(SongSortKey.sortKey("07_Intro") == "intro")
        #expect(SongSortKey.sortKey("The Zebra") == "zebra")
        #expect(db.songIDs(sortedBy: .artist) == ["3", "2", "1", "4"])

        // Case and accents don't matter; every word must match somewhere; album counts.
        #expect(db.searchSongIDs("beyonce") == ["1"])
        #expect(db.searchSongIDs("CAFE") == ["4"])
        #expect(db.searchSongIDs("abba 10") == ["2"])
        #expect(db.searchSongIDs("track") == ["3", "2"])
        #expect(db.searchSongIDs("100%").isEmpty)  // % is literal, not a wildcard

        // Renaming updates the sort key.
        db.saveSongs([song("1", "Aardvark", "Beyoncé")])
        #expect(db.songIDs(sortedBy: .title) == ["1", "4", "3", "2"])
    }

    @Test(arguments: [
        // (title, artist, track) → expected
        ("04 21 Savage - Bad Guy (Chopped Not Slopped)", "21 Savage", 4, "Bad Guy (Chopped Not Slopped)"),
        ("21 Savage - Close My Eyes", "21 Savage", 3, "Close My Eyes"),
        ("01 - Intro", "Drake", 1, "Intro"),
        ("1. Intro", "Drake", 0, "Intro"),
        ("07_Intro", "Drake", 7, "Intro"),
        ("03 Bonnie & Clyde", "Jay-Z", 3, "Bonnie & Clyde"),
        ("Metallica – One", "Metallica", 0, "One"),
        ("Drake - Jumpman", "Drake & Future", 0, "Jumpman"),
        ("02 Beyonce - Halo", "Beyoncé", 2, "Halo"),
        ("Tyler the Creator -- Goblin", "Tyler, The Creator", 1, "Goblin"),
        ("Tyler The Creator- Transylvania", "Tyler, The Creator", 5, "Transylvania"),
        // Real titles that start with numbers or look like prefixes stay as they are.
        ("7 Rings", "Ariana Grande", 7, "7 Rings"),
        ("99 Problems", "Jay-Z", 99, "99 Problems"),
        ("21 Questions", "50 Cent", 0, "21 Questions"),
        ("1-800-273-8255", "Logic", 0, "1-800-273-8255"),
        ("Bad Guy", "Unknown Artist", 0, "Bad Guy"),
        ("Drake", "Drake", 0, "Drake"),
        ("Other Artist - Song", "Drake", 0, "Other Artist - Song"),
        ("Drakeo - Song", "Drake", 0, "Drakeo - Song"),
    ])
    func titleCleanup(_ c: (String, String, Int, String)) {
        #expect(SongTitle.cleaned(c.0, artist: c.1, trackNumber: c.2) == c.3)
    }

    @Test func coverThumbnailsAreSmallAndCached() async throws {
        // A 1200×1200 "cover"
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1200),
                                          format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200)) }
        let id = ArtworkStore.shared.save(try #require(big.jpegData(compressionQuality: 0.9)))

        // Many rows asking at once share one result.
        async let a = ArtworkThumbnails.shared.thumbnail(for: id)
        async let b = ArtworkThumbnails.shared.thumbnail(for: id)
        let (thumbA, thumbB) = await (a, b)

        let thumb = try #require(thumbA)
        #expect(thumb === thumbB)
        #expect(max(thumb.size.width, thumb.size.height) <= 420)
        #expect(ArtworkThumbnails.shared.cached(id) === thumb)  // instant next time
    }

    @Test func identicalArtworkIsStoredOnce() {
        let art = Data("same cover".utf8)
        let a = Song(title: "1", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/a.mp3"), artwork: art)
        let b = Song(title: "2", artist: "", album: "", duration: 0, url: URL(fileURLWithPath: "/b.mp3"), artwork: art)
        #expect(a.artworkID == b.artworkID)
    }
}
