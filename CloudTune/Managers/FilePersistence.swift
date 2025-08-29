import Foundation

enum FP { // centralize queue + debounce
    static let ioQ = DispatchQueue(label: "io.file.persistence", qos: .utility)
    static func debounce(key: String, delay: TimeInterval, perform: @escaping () -> Void) {
        struct Token { static var work = [String: DispatchWorkItem]() }
        Token.work[key]?.cancel()
        let item = DispatchWorkItem(block: perform)
        Token.work[key] = item
        ioQ.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

struct FilePersistence {
    static let folderListKey = "SavedFolders.json"
    static let libraryKey    = "Library.json"
    static let playlistsKey  = "playlists.json"

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! }
    static var savedFoldersURL: URL { docs.appendingPathComponent(folderListKey) }
    static var libraryURL: URL { docs.appendingPathComponent(libraryKey) }
    static var playlistsURL: URL { docs.appendingPathComponent(playlistsKey) }

    // MARK: Folder list (small) — immediate OK, but still off main
    static func saveFolderList(_ urls: [URL]) {
        FP.ioQ.async {
            let strings = urls.map { $0.absoluteString }
            if let data = try? JSONEncoder().encode(strings) {
                try? data.write(to: savedFoldersURL, options: .atomic)
            }
        }
    }
    static func loadFolderList() -> [URL] {
        guard let data = try? Data(contentsOf: savedFoldersURL),
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    // MARK: Library — debounced coalesced writer
    static func saveLibrary(_ songs: [Song]) {
        FP.debounce(key: "lib", delay: 0.5) {
            do {
                let data = try JSONEncoder().encode(songs)
                try data.write(to: libraryURL, options: .atomic)
                // print("💾 Library saved (debounced).")
            } catch {
                print("❌ saveLibrary:", error)
            }
        }
    }
    static func loadLibrary() -> [Song] {
        guard let data = try? Data(contentsOf: libraryURL) else { return [] }
        return (try? JSONDecoder().decode([Song].self, from: data)) ?? []
    }

    // MARK: Playlists — debounced writer
    static func savePlaylists(_ playlists: [Playlist]) {
        FP.debounce(key: "pls", delay: 0.5) {
            do {
                let data = try JSONEncoder().encode(playlists)
                try data.write(to: playlistsURL, options: .atomic)
                // print("💾 Playlists saved (debounced).")
            } catch {
                print("❌ savePlaylists:", error)
            }
        }
    }
    static func loadPlaylists() -> [Playlist] {
        guard let data = try? Data(contentsOf: playlistsURL) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }
}
