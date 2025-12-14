import Foundation

/// Centralized store for folder-scoped security bookmarks.
/// Keys are *normalized* file-system paths so that variants like
/// "/private/var/..." and "/var/..." map to the same entry.
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let storageKey = "ScopedFolderBookmarks.v1"

    /// folderPath(normalized) -> bookmarkData
    private var bookmarks: [String: Data] = [:]

    /// Set of folderPath(normalized) we have called startAccessing… on.
    private var activeAccess: Set<String> = []

    private init() {
        if let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Data] {
            var fixed: [String: Data] = [:]
            for (k, v) in dict {
                fixed[Self.normalizePath(k)] = v
            }
            bookmarks = fixed
        }
    }

    // MARK: - Path normalization

    /// Normalizes a path for stable comparisons:
    /// - standardizes & resolves symlinks
    /// - strips a leading "/private" (File Provider vs. local differences)
    /// - removes a trailing slash
    private static func normalizePath(_ raw: String) -> String {
        var p = URL(fileURLWithPath: raw)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if p.hasPrefix("/private") {
            p.removeFirst("/private".count)
        }
        // drop trailing slash (except root)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Save / remove

    /// Persist a security-scoped bookmark for the given folder URL.
    func saveBookmark(forFolder folderURL: URL) {
        do {
            let key = Self.normalizePath(folderURL.path)

            // Create a SECURITY-SCOPED bookmark via NSURL (Swift URL overlay can be finicky)
            let data = try (folderURL as NSURL).bookmarkData(
                options: [],                                  // ← no .withSecurityScope on iOS
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            bookmarks[key] = data
            UserDefaults.standard.set(bookmarks, forKey: storageKey)
            print("🔖 Saved SECURITY-SCOPED bookmark for: \(folderURL.lastPathComponent)")
        } catch {
            print("❌ Failed to create bookmark for \(folderURL.path): \(error)")
        }
    }

    func removeBookmark(forFolderPath path: String) {
        let key = Self.normalizePath(path)
        bookmarks.removeValue(forKey: key)
        UserDefaults.standard.set(bookmarks, forKey: storageKey)
        if activeAccess.contains(key) {
            URL(fileURLWithPath: key).stopAccessingSecurityScopedResource()
            activeAccess.remove(key)
            print("🛑 Stopped scope for removed folder: \(key)")
        }
    }

    // MARK: - Resolve

    private func resolveFolderURL(fromStoredPath path: String) -> URL? {
        let key = Self.normalizePath(path)
        guard let data = bookmarks[key] else { return nil }
        var stale: ObjCBool = false
        do {
            // Resolve using NSURL (no .withSecurityScope on iOS)
            let resolved = try NSURL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) as URL

            if stale.boolValue {
                // Recreate a fresh bookmark and persist it (no .withSecurityScope on iOS)
                let refreshed = try (resolved as NSURL).bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                bookmarks[key] = refreshed
                UserDefaults.standard.set(bookmarks, forKey: storageKey)
                print("♻️ Refreshed stale bookmark for: \(key)")
            }
            return resolved
        } catch {
            print("❌ Failed resolving bookmark for \(key): \(error)")
            return nil
        }
    }

    private func bookmarkedParentFolder(for fileURL: URL) -> URL? {
        let filePath = Self.normalizePath(fileURL.path)

        // 1) Exact parent
        let parent = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        if let exact = resolveFolderURL(fromStoredPath: parent) { return exact }

        // 2) Longest-prefix match across stored keys (handles nested bookmarks)
        for storedPath in bookmarks.keys.sorted(by: { $0.count > $1.count }) {
            if filePath.hasPrefix(storedPath + "/"), let resolved = resolveFolderURL(fromStoredPath: storedPath) {
                return resolved
            }
        }
        return nil
    }

    /// All restored, resolved folder URLs for UI / rescans.
    func restoredFolderURLs() -> [URL] {
        Array(bookmarks.keys.compactMap { resolveFolderURL(fromStoredPath: $0) })
    }

    // MARK: - Access control

    /// Begin access for the folder containing `fileURL` if we have a bookmark.
    /// Returns true if access is active (newly started or already active).
    @discardableResult
    func beginAccessIfBookmarked(parentOf fileURL: URL) -> Bool {
        guard let folderURL = bookmarkedParentFolder(for: fileURL) else { return false }
        let key = Self.normalizePath(folderURL.path)
        if !activeAccess.contains(key) {
            if folderURL.startAccessingSecurityScopedResource() {
                activeAccess.insert(key)
                return true
            } else {
                print("⚠️ startAccessingSecurityScopedResource() failed for \(key)")
                return false
            }
        } else {
            // Helpful debug so logs show why we didn't print another "Started" line
            print("🔐 Using existing scope for: \(folderURL.lastPathComponent)")
            return true
        }
    }

    /// Stop access for the folder containing `fileURL`. Call this ONLY when the user
    /// removes the folder from the app, or when you intentionally release scopes.
    func endAccess(forFolderContaining fileURL: URL) {
        guard let folderURL = bookmarkedParentFolder(for: fileURL) else { return }
        let key = Self.normalizePath(folderURL.path)
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
