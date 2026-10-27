//
//  LibraryDatabase.swift
//  CloudTune
//
//  SQLite (GRDB) storage for the library: folders, songs, playlists.
//  Replaces Library.json / playlists.json, which had to be rewritten in full on every change.
//
//  Songs are stored relative to their folder (folderID + relativePath) rather than by absolute
//  path, because iOS moves the app's data folder on reinstall/update. On launch each folder is
//  re-resolved from its bookmark and song URLs are rebuilt from it, so no rescan is needed.
//
//  The `source` / `remoteID` / `downloadState` columns are there for cloud sources
//  (Google Drive, Dropbox, …) later; every song is "local" today.
//

import Foundation
import GRDB

final class LibraryDatabase {
    static let shared = LibraryDatabase.makeShared()

    private let dbQueue: DatabaseQueue

    /// Writes run in order on this queue, off the main thread.
    private let writeQueue = DispatchQueue(label: "LibraryDatabase.write", qos: .utility)

    /// Folder ID (bookmark key) → where that folder currently lives. Only touched on `writeQueue`.
    private var folderLocations: [String: URL] = [:]

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static func makeShared() -> LibraryDatabase {
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: dir.appendingPathComponent("Library.sqlite").path)
            return try LibraryDatabase(dbQueue: queue)
        } catch {
            // Should never happen; keep the app usable (nothing persists) rather than crash.
            print("❌ LibraryDatabase open failed, using in-memory store: \(error)")
            return try! LibraryDatabase(dbQueue: DatabaseQueue())
        }
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "folder") { t in
                t.primaryKey("id", .text)                  // bookmark key (normalized path when added)
                t.column("name", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "local")
                t.column("remoteID", .text)                // cloud folder ID, later
                t.column("addedAt", .datetime).notNull()
            }

            try db.create(table: "song") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("duration", .double).notNull()
                t.column("artworkID", .text)
                t.column("musicBrainzReleaseID", .text)
                t.column("genre", .text).notNull()
                t.column("year", .text).notNull()
                t.column("trackNumber", .integer).notNull()
                t.column("discNumber", .integer).notNull()
                t.column("externalURL", .text).notNull()
                t.column("tags", .text).notNull()          // JSON array

                // Where the file is
                t.column("source", .text).notNull().defaults(to: "local")  // local | googleDrive | dropbox …
                t.column("remoteID", .text)                                // ID at the cloud provider
                t.column("folderID", .text).references("folder", onDelete: .setNull).indexed()
                t.column("relativePath", .text)                            // path inside the folder
                t.column("localPath", .text)                               // last known absolute path (fallback)
                t.column("downloadState", .text).notNull().defaults(to: "downloaded") // none | downloading | downloaded
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(index: "song_album", on: "song", columns: ["album"])
            try db.create(index: "song_artist", on: "song", columns: ["artist"])

            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("coverArtFilename", .text)
                t.column("position", .integer).notNull()
            }

            try db.create(table: "playlistSong") { t in
                t.belongsTo("playlist", onDelete: .cascade).notNull()
                t.column("songID", .text).notNull()        // not a foreign key: playlists keep IDs of songs that may come back
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "position"])
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }

        // Sort and search keys, so the Songs and Search screens can ask the database
        // instead of sorting/filtering the whole library in memory.
        migrator.registerMigration("v2-sort-search") { db in
            try db.alter(table: "song") { t in
                t.add(column: "titleSort", .text).notNull().defaults(to: "")
                t.add(column: "artistSort", .text).notNull().defaults(to: "")
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, title, artist, album FROM song")
            for row in rows {
                let title: String = row["title"], artist: String = row["artist"], album: String = row["album"]
                try db.execute(sql: "UPDATE song SET titleSort = ?, artistSort = ?, searchText = ? WHERE id = ?",
                               arguments: [SongSortKey.sortKey(title), SongSortKey.sortKey(artist),
                                           SongSortKey.searchText(title: title, artist: artist, album: album),
                                           row["id"] as String])
            }
        }

        // Clean up titles imported before SongTitle existed ("04 21 Savage - Bad Guy" → "Bad Guy").
        // v4 runs it again after the artist match learned to ignore punctuation ("Tyler The Creator -- …").
        migrator.registerMigration("v3-clean-titles", migrate: cleanStoredTitles)
        migrator.registerMigration("v4-clean-titles-punctuation", migrate: cleanStoredTitles)

        // Album details from MusicBrainz (year, genre, track list), one row per album.
        // Albums that weren't found are kept too, so they aren't searched again every launch.
        migrator.registerMigration("v5-album-info") { db in
            try db.create(table: "albumInfo") { t in
                t.primaryKey("key", .text)                 // AlbumLookup.key(album:artist:)
                t.column("releaseID", .text)               // nil = not found
                t.column("releaseGroupID", .text)
                t.column("title", .text)
                t.column("artist", .text)
                t.column("year", .text)
                t.column("genre", .text)
                t.column("tracks", .text).notNull()        // JSON
                t.column("hasCover", .boolean).notNull()
                t.column("checkedAt", .datetime).notNull()
            }
        }

        return migrator
    }

    private static func cleanStoredTitles(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, title, artist, album, trackNumber FROM song")
        for row in rows {
            let title: String = row["title"], artist: String = row["artist"], album: String = row["album"]
            let cleaned = SongTitle.cleaned(title, artist: artist, trackNumber: row["trackNumber"])
            guard cleaned != title else { continue }
            try db.execute(sql: "UPDATE song SET title = ?, titleSort = ?, searchText = ? WHERE id = ?",
                           arguments: [cleaned, SongSortKey.sortKey(cleaned),
                                       SongSortKey.searchText(title: cleaned, artist: artist, album: album),
                                       row["id"] as String])
        }
    }

    // MARK: - Records

    private struct FolderRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "folder"
        var id: String
        var name: String
        var source: String = "local"
        var remoteID: String? = nil
        var addedAt: Date = Date()
    }

    private struct SongRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "song"
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var artworkID: String?
        var musicBrainzReleaseID: String?
        var genre: String
        var year: String
        var trackNumber: Int
        var discNumber: Int
        var externalURL: String
        var tags: [String]
        var source: String = "local"
        var remoteID: String? = nil
        var folderID: String?
        var relativePath: String?
        var localPath: String?
        var downloadState: String = "downloaded"
        var addedAt: Date = Date()
        var titleSort: String
        var artistSort: String
        var searchText: String

        init(song: Song, folderID: String?, relativePath: String?) {
            id = song.id; title = song.title; artist = song.artist; album = song.album
            titleSort = SongSortKey.sortKey(song.title)
            artistSort = SongSortKey.sortKey(song.artist)
            searchText = SongSortKey.searchText(title: song.title, artist: song.artist, album: song.album)
            duration = song.duration; artworkID = song.artworkID
            musicBrainzReleaseID = song.musicBrainzReleaseID
            genre = song.genre; year = song.year
            trackNumber = song.trackNumber; discNumber = song.discNumber
            externalURL = song.externalURL; tags = song.tags
            self.folderID = folderID; self.relativePath = relativePath
            localPath = song.url.path
        }

        func song(folderURLs: [String: URL]) -> Song {
            let url: URL
            if let folderID, let base = folderURLs[folderID], let relativePath {
                url = base.appendingPathComponent(relativePath)
            } else {
                url = URL(fileURLWithPath: localPath ?? "")
            }
            return Song(id: id, title: title, artist: artist, album: album, duration: duration, url: url,
                        artworkID: artworkID, musicBrainzReleaseID: musicBrainzReleaseID,
                        genre: genre, year: year, trackNumber: trackNumber, discNumber: discNumber,
                        externalURL: externalURL, tags: tags)
        }
    }

    private struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "playlist"
        var id: String
        var name: String
        var coverArtFilename: String?
        var position: Int
    }

    private struct PlaylistSongRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "playlistSong"
        var playlistId: String
        var songID: String
        var position: Int
    }

    // MARK: - Folders

    /// Tell the database where folders live right now (from resolved bookmarks). Call before loading songs.
    func setFolderLocations(_ locations: [String: URL]) {
        writeQueue.sync { folderLocations = locations }
    }

    func saveFolder(key: String, url: URL) {
        writeQueue.async { [self] in
            folderLocations[key] = url
            write("saveFolder") { db in
                if try FolderRecord.fetchOne(db, key: key) == nil {
                    try FolderRecord(id: key, name: url.lastPathComponent).insert(db)
                }
            }
        }
    }

    /// Removes a folder and every song stored under it.
    func deleteFolder(key: String) {
        writeQueue.async { [self] in
            folderLocations.removeValue(forKey: key)
            write("deleteFolder") { db in
                try SongRecord.filter(Column("folderID") == key).deleteAll(db)
                _ = try FolderRecord.deleteOne(db, key: key)
            }
        }
    }

    // MARK: - Songs

    /// Reads every song. Blocking; call off the main thread.
    func fetchSongs() -> [Song] {
        let locations = writeQueue.sync { folderLocations }
        do {
            return try dbQueue.read { db in
                try SongRecord.order(Column("addedAt"), Column("rowid")).fetchAll(db).map { $0.song(folderURLs: locations) }
            }
        } catch {
            print("❌ fetchSongs:", error)
            return []
        }
    }

    /// Inserts or updates these songs only (not the whole library).
    func saveSongs(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        writeQueue.async { [self] in
            let records = songs.map(record(for:))
            write("saveSongs(\(songs.count))") { db in
                for r in records {
                    // Keep the original addedAt / cloud fields when updating an existing row.
                    if var existing = try SongRecord.fetchOne(db, key: r.id) {
                        let keep = (existing.addedAt, existing.source, existing.remoteID, existing.downloadState)
                        existing = r
                        (existing.addedAt, existing.source, existing.remoteID, existing.downloadState) = keep
                        try existing.update(db)
                    } else {
                        try r.insert(db)
                    }
                }
            }
        }
    }

    /// Song IDs in the given order. Blocking; call off the main thread.
    /// Runs after any queued writes, so songs saved just before are included.
    func songIDs(sortedBy sort: SongSortOption) -> [String] {
        let title = Column("titleSort").collating(.localizedStandardCompare)
        let artist = Column("artistSort").collating(.localizedStandardCompare)
        let order: [any SQLOrderingTerm]
        switch sort {
        case .recent: order = [Column("addedAt").desc, Column.rowID.desc]
        case .title:  order = [title, artist, Column("id")]
        case .artist: order = [artist, title, Column("id")]
        }
        return readAfterWrites("songIDs(sortedBy:)") { db in
            try String.fetchAll(db, SongRecord.select(Column("id")).order(order))
        }
    }

    /// IDs of songs whose title, artist or album contain every word of `query`
    /// (ignoring case and accents), sorted by title. Blocking; call off the main thread.
    func searchSongIDs(_ query: String) -> [String] {
        let words = SongSortKey.searchWords(query)
        var request = SongRecord.select(Column("id"))
        for word in words {
            let escaped = word
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            request = request.filter(sql: "searchText LIKE ? ESCAPE '\\'", arguments: ["%\(escaped)%"])
        }
        request = request.order(Column("titleSort").collating(.localizedStandardCompare), Column("id"))
        return readAfterWrites("searchSongIDs") { db in
            try String.fetchAll(db, request)
        }
    }

    func deleteSongs(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeQueue.async { [self] in
            write("deleteSongs(\(ids.count))") { db in
                _ = try SongRecord.deleteAll(db, keys: ids)
            }
        }
    }

    /// Splits a song's URL into (folder, path inside folder) using the folders we know about.
    private func record(for song: Song) -> SongRecord {
        let path = BookmarkStore.normalizePath(song.url.path)
        let match = folderLocations
            .map { (key: $0.key, base: BookmarkStore.normalizePath($0.value.path)) }
            .filter { path.hasPrefix($0.base + "/") }
            .max { $0.base.count < $1.base.count }
        let relative = match.map { String(path.dropFirst($0.base.count + 1)) }
        return SongRecord(song: song, folderID: match?.key, relativePath: relative)
    }

    // MARK: - Album details

    /// Blocking; call off the main thread.
    func albumInfo(key: String) -> AlbumInfo? {
        readAfterWrites("albumInfo") { db in
            try AlbumInfo.fetchOne(db, key: key).map { [$0] } ?? []
        }.first
    }

    func saveAlbumInfo(_ info: AlbumInfo) {
        writeQueue.async { [self] in
            write("saveAlbumInfo") { db in try info.save(db) }
        }
    }

    // MARK: - Playlists

    func fetchPlaylists() -> [Playlist] {
        do {
            return try dbQueue.read { db in
                let entries = try PlaylistSongRecord.order(Column("position")).fetchAll(db)
                let songsByPlaylist = Dictionary(grouping: entries, by: \.playlistId)
                return try PlaylistRecord.order(Column("position")).fetchAll(db).map {
                    Playlist(id: $0.id, name: $0.name, coverArtFilename: $0.coverArtFilename,
                             songIDs: (songsByPlaylist[$0.id] ?? []).map(\.songID))
                }
            }
        } catch {
            print("❌ fetchPlaylists:", error)
            return []
        }
    }

    /// Playlists are small; replace them all in one transaction.
    func replacePlaylists(_ playlists: [Playlist]) {
        writeQueue.async { [self] in
            write("replacePlaylists(\(playlists.count))") { db in
                try Self.insertPlaylists(playlists, db: db, replacingExisting: true)
            }
        }
    }

    private static func insertPlaylists(_ playlists: [Playlist], db: Database, replacingExisting: Bool) throws {
        if replacingExisting { try PlaylistRecord.deleteAll(db) } // cascades to playlistSong
        for (i, p) in playlists.enumerated() {
            try PlaylistRecord(id: p.id, name: p.name, coverArtFilename: p.coverArtFilename, position: i).insert(db)
            for (j, songID) in p.songIDs.enumerated() {
                try PlaylistSongRecord(playlistId: p.id, songID: songID, position: j).insert(db)
            }
        }
    }

    // MARK: - One-time import of the old JSON files

    /// Moves Library.json and playlists.json into the database the first time the new version runs.
    /// `bookmarkKeys` are the folder keys from BookmarkStore, used to file each song under its folder.
    /// The old files are kept, renamed to *.migrated, in case anything needs recovering.
    func importLegacyJSONIfNeeded(libraryURL: URL, playlistsURL: URL, bookmarkKeys: [String]) {
        writeQueue.sync { [self] in
            let done = (try? dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'legacyJSONImported'")
            }) ?? nil
            guard done == nil else { return }

            let decoder = JSONDecoder()
            let songs = (try? Data(contentsOf: libraryURL)).flatMap { try? decoder.decode([Song].self, from: $0) } ?? []
            let playlists = (try? Data(contentsOf: playlistsURL)).flatMap { try? decoder.decode([Playlist].self, from: $0) } ?? []

            // Old paths are matched against the bookmark keys as they were saved (also old paths).
            let keys = bookmarkKeys.sorted { $0.count > $1.count }
            write("importLegacyJSON") { db in
                for key in keys where try FolderRecord.fetchOne(db, key: key) == nil {
                    try FolderRecord(id: key, name: URL(fileURLWithPath: key).lastPathComponent).insert(db)
                }
                for song in songs where try SongRecord.fetchOne(db, key: song.id) == nil {
                    let path = BookmarkStore.normalizePath(song.url.path)
                    let key = keys.first { path.hasPrefix($0 + "/") }
                    let relative = key.map { String(path.dropFirst($0.count + 1)) }
                    try SongRecord(song: song, folderID: key, relativePath: relative).insert(db)
                }
                try Self.insertPlaylists(playlists, db: db, replacingExisting: false)
                try db.execute(sql: "INSERT INTO appState (key, value) VALUES ('legacyJSONImported', ?)",
                               arguments: [ISO8601DateFormatter().string(from: Date())])
            }

            for url in [libraryURL, playlistsURL] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("migrated"))
            }
            print("🗄️ Imported \(songs.count) songs and \(playlists.count) playlists into the database.")
        }
    }

    // MARK: - Helpers

    /// Blocks until all queued writes have finished (tests, app shutdown).
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    private func readAfterWrites<T>(_ label: String, _ value: (Database) throws -> [T]) -> [T] {
        writeQueue.sync {
            do {
                return try dbQueue.read(value)
            } catch {
                print("❌ LibraryDatabase.\(label):", error)
                return []
            }
        }
    }

    private func write(_ label: String, _ updates: (Database) throws -> Void) {
        do {
            try dbQueue.write(updates)
        } catch {
            print("❌ LibraryDatabase.\(label):", error)
        }
    }
}

extension AlbumInfo: FetchableRecord, PersistableRecord {
    static let databaseTableName = "albumInfo"
}
