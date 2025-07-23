import Foundation

struct FilePersistence {
    static let folderListKey = "SavedFolders.json"
    static let libraryKey = "Library.json"
    static let playlistsKey = "playlists.json"

    static var savedFoldersURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(folderListKey)
    }

    static var libraryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(libraryKey)
    }

    static var playlistsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(playlistsKey)
    }

    static func saveFolderList(_ urls: [URL]) {
        guard let url = savedFoldersURL else { return }
        let strings = urls.map { $0.absoluteString }
        try? JSONEncoder().encode(strings).write(to: url)
    }

    static func loadFolderList() -> [URL] {
        guard let url = savedFoldersURL,
              let data = try? Data(contentsOf: url),
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return strings.compactMap { URL(string: $0) }
    }

    // Save entire song library
    static func saveLibrary(_ songs: [Song]) {
        guard let url = libraryURL else { return }
        do {
            let data = try JSONEncoder().encode(songs)
            try data.write(to: url)
            print("💾 Library saved successfully.")
        } catch {
            print("❌ Failed to save library:", error)
        }
    }

    // Load entire song library
    static func loadLibrary() -> [Song] {
        guard let url = libraryURL,
              let data = try? Data(contentsOf: url),
              let songs = try? JSONDecoder().decode([Song].self, from: data)
        else {
            print("⚠️ Failed to load saved library.")
            return []
        }
        return songs
    }
}
