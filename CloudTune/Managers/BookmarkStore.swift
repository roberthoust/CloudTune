import Foundation

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let storageKey = "ScopedFolderBookmarks.v1"
    // Use standardized, symlink-resolved paths as keys.
    private var bookmarks: [String: Data] = [:]

    // Track which folders we’ve called startAccessing… on (standardized path).
    private var activeAccess: Set<String> = []

    private init() {
        if let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Data] {
            // Normalize keys that may have been stored unstandardized in older builds
            var fixed: [String: Data] = [:]
            for (k, v) in dict {
                let std = URL(fileURLWithPath: k).standardizedFileURL.resolvingSymlinksInPath().path
                fixed[std] = v
            }
            bookmarks = fixed
        }
    }

    // MARK: - Save / remove

    func saveBookmark(forFolder folderURL: URL) {
        do {
            let options: URL.BookmarkCreationOptions
            if #available(iOS 13.0, *) { options = [.minimalBookmark] } else { options = [] }

            let stdPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
            let data = try folderURL.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarks[stdPath] = data
            UserDefaults.standard.set(bookmarks, forKey: storageKey)
            print("🔖 Saved bookmark for folder: \(folderURL.lastPathComponent)")
        } catch {
            print("❌ Failed to create bookmark for \(folderURL.path): \(error)")
        }
    }

    func removeBookmark(forFolderPath path: String) {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        bookmarks.removeValue(forKey: stdPath)
        UserDefaults.standard.set(bookmarks, forKey: storageKey)
        // If it’s currently active, end it now.
        if activeAccess.contains(stdPath) {
            let u = URL(fileURLWithPath: stdPath)
            u.stopAccessingSecurityScopedResource()
            activeAccess.remove(stdPath)
            print("🛑 Stopped scope for removed folder: \(stdPath)")
        }
    }

    // MARK: - Resolve

    private func resolveFolderURL(fromStoredPath path: String) -> URL? {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard let data = bookmarks[stdPath] else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let refreshed = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                bookmarks[stdPath] = refreshed
                UserDefaults.standard.set(bookmarks, forKey: storageKey)
                print("♻️ Refreshed stale bookmark for: \(stdPath)")
            }
            return url
        } catch {
            print("❌ Failed resolving bookmark for \(stdPath): \(error)")
            return nil
        }
    }

    private func bookmarkedParentFolder(for fileURL: URL) -> URL? {
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path

        // 1) Exact parent hit
        let parent = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        if let exact = resolveFolderURL(fromStoredPath: parent.path) { return exact }

        // 2) Longest-prefix match against stored keys
        for storedPath in bookmarks.keys.sorted(by: { $0.count > $1.count }) {
            if filePath.hasPrefix(storedPath + "/"), let resolved = resolveFolderURL(fromStoredPath: storedPath) {
                return resolved
            }
        }
        return nil
    }
    
    // Return the resolved folder URLs for all stored bookmarks
    func restoredFolderURLs() -> [URL] {
        bookmarks.keys.compactMap { resolveFolderURL(fromStoredPath: $0) }
    }

    // MARK: - Access control

    /// Begin access for the folder containing `fileURL` if we have a bookmark.
    /// Returns true if access is active (new or already-active).
    @discardableResult
    func beginAccessIfBookmarked(parentOf fileURL: URL) -> Bool {
        guard let folderURL = bookmarkedParentFolder(for: fileURL) else { return false }
        let key = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        if !activeAccess.contains(key) {
            if folderURL.startAccessingSecurityScopedResource() {
                activeAccess.insert(key)
                print("🔐 Started scope for: \(folderURL.lastPathComponent)")
                return true
            } else {
                print("⚠️ startAccessingSecurityScopedResource() failed for \(key)")
                return false
            }
        }
        // already active
        return true
    }

    /// Stop access for the folder containing `fileURL`. Call this ONLY when the user
    /// removes the folder from the app, or when you are intentionally releasing scopes.
    func endAccess(forFolderContaining fileURL: URL) {
        guard let folderURL = bookmarkedParentFolder(for: fileURL) else { return }
        let key = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        if activeAccess.contains(key) {
            folderURL.stopAccessingSecurityScopedResource()
            activeAccess.remove(key)
            print("🛑 Stopped scope for: \(folderURL.lastPathComponent)")
        }
    }

    /// Optional helper to release everything (e.g. on app termination).
    func endAllAccess() {
        for key in activeAccess {
            URL(fileURLWithPath: key).stopAccessingSecurityScopedResource()
            print("🛑 Stopped scope for: \(key)")
        }
        activeAccess.removeAll()
    }
}

// MARK: - Back-compat helper (stopper closure style)
extension BookmarkStore {
    /// Drop-in replacement for old BookmarkManager API:
    /// Starts scope for the folder containing `fileURL` (if bookmarked) and
    /// returns a stopper you can call later. Returns `nil` if no scope was opened.
    func beginAccessWithStopper(for fileURL: URL) -> (() -> Void)? {
        if beginAccessIfBookmarked(parentOf: fileURL) {
            return { [weak self] in
                self?.endAccess(forFolderContaining: fileURL)
            }
        }
        return nil
    }
}
