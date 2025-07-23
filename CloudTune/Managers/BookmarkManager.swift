import Foundation

class BookmarkManager {
    static let bookmarksKey = "bookmarkedFolders"

    static func saveFolderBookmark(url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [], // ⚠️ NO .withSecurityScope on iOS
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var bookmarks = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }

    static func restoreBookmarkedFolders() -> [URL] {
        guard let saved = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] else { return [] }
        var urls: [URL] = []

        for data in saved {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if url.startAccessingSecurityScopedResource() {
                    urls.append(url)
                }
            }
        }
        return urls
    }
    
    static func removeBookmark(for folderURL: URL) {
        guard var bookmarks = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] else { return }

        // Filter out the matching URL bookmark
        bookmarks.removeAll { bookmarkData in
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url == folderURL
            }
            return false
        }

        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }
}
