//
//  ArtworkStore.swift
//  CloudTune
//
//  Stores cover art as individual files instead of inside Library.json.
//  Files are named by a hash of their bytes, so identical covers (every song
//  on an album, the default cover) are stored once and shared.
//

import Foundation
import CryptoKit

final class ArtworkStore {
    static let shared = ArtworkStore()

    private let folder: URL
    private let mem = NSCache<NSString, NSData>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mem.totalCostLimit = 48 * 1024 * 1024 // ~48MB of raw image bytes
    }

    /// Saves artwork (if not already stored) and returns its ID. Safe to call from any thread.
    @discardableResult
    func save(_ data: Data) -> String {
        let id = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = fileURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("❌ ArtworkStore.save:", error)
            }
        }
        mem.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return id
    }

    /// Returns the artwork bytes for an ID, from memory if possible. Safe to call from any thread.
    func data(for id: String) -> Data? {
        if let cached = mem.object(forKey: id as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        mem.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return data
    }

    private func fileURL(for id: String) -> URL {
        folder.appendingPathComponent(id).appendingPathExtension("img")
    }
}
