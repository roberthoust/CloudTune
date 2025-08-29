import Foundation

/// Keeps security scopes alive for picked folders during app lifetime.
/// On iOS you cannot re-open scope from a bookmark later, so we keep it
/// until the user removes the folder (or you call `stopAll()` on exit).
final class SecurityScopeKeeper {
    static let shared = SecurityScopeKeeper()
    private init() {}

    private let q = DispatchQueue(label: "scope.keeper.serial")
    private var stoppers: [String: () -> Void] = [:]   // key = standardized folder path

    func keepScope(for folderURL: URL, stopper: @escaping () -> Void) {
        let key = folderURL.standardizedFileURL.path
        q.sync {
            guard stoppers[key] == nil else { return }
            stoppers[key] = stopper
            print("🔐 Keeping security scope for: \(folderURL.lastPathComponent)")
        }
    }

    func hasScope(for folderURL: URL) -> Bool {
        let key = folderURL.standardizedFileURL.path
        return q.sync { stoppers[key] != nil }
    }

    /// True if we have a scope for the file's parent folder.
    func ensureScope(forParentOf fileURL: URL) -> Bool {
        hasScope(for: fileURL.deletingLastPathComponent().standardizedFileURL)
    }

    func closeScope(for folderURL: URL) {
        let key = folderURL.standardizedFileURL.path
        let stopper = q.sync { stoppers.removeValue(forKey: key) }
        stopper?()
        print("🔓 Closed security scope for: \(folderURL.lastPathComponent)")
    }

    func stopAll() {
        let all = q.sync { stoppers.values }
        all.forEach { $0() }
        q.sync { stoppers.removeAll() }
        print("🔚 Closed all security scopes.")
    }
}
