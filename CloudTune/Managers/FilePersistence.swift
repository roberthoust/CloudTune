import Foundation

/// Lightweight persistence helpers for small JSON payloads stored in
/// the app's Documents directory. Designed to be side‑effect free
/// (no logging), atomic, and simple.
struct FilePersistence {
    // MARK: Filenames
    private enum Store: String { case savedFolders = "SavedFolders.json", library = "Library.json", playlists = "playlists.json" }

    // MARK: URL helpers
    private static func url(for store: Store) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(store.rawValue)
    }

    // MARK: Generic read/write
    @discardableResult
    private static func write<T: Encodable>(_ value: T, to store: Store) -> Bool {
        guard let u = url(for: store) else { return false }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: u, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from store: Store) -> T? {
        guard let u = url(for: store), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Saved Folders
    static func saveFolderList(_ urls: [URL]) {
        // Persist as absoluteString to keep scheme + path intact.
        let strings = urls.map { $0.standardizedFileURL.absoluteString }
        _ = write(strings, to: .savedFolders)
    }

    static func loadFolderList() -> [URL] {
        guard let strings: [String] = read([String].self, from: .savedFolders) else { return [] }
        // Filter out malformed entries
        return strings.compactMap { URL(string: $0) }
    }

    // MARK: Library
    static func saveLibrary(_ songs: [Song]) {
        _ = write(songs, to: .library)
    }

    static func loadLibrary() -> [Song] {
        read([Song].self, from: .library) ?? []
    }

    // MARK: Playlists
    static func savePlaylists(_ playlists: [Playlist]) {
        _ = write(playlists, to: .playlists)
    }

    static func loadPlaylists() -> [Playlist] {
        read([Playlist].self, from: .playlists) ?? []
    }
}
