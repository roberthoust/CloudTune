//
//  ArtworkThumbnails.swift
//  CloudTune
//
//  Small, ready-to-draw cover thumbnails keyed by artwork ID (see ArtworkStore).
//  Every song on an album shares one artwork ID, so an album's cover is decoded once
//  for the whole list instead of once per song. Thumbnails are kept in memory and on
//  disk, so after the first time they appear instantly, even after a relaunch.
//

import SwiftUI
import UIKit
import ImageIO

/// Thread-safe: NSCache is thread-safe and `waiting` is guarded by `lock`.
final class ArtworkThumbnails: @unchecked Sendable {
    static let shared = ArtworkThumbnails()

    /// One size for every list and grid (largest use is the 140pt album grid at 3x).
    private let maxPixelSize = 420

    private let mem = NSCache<NSString, UIImage>()
    private let folder: URL
    private let queue = DispatchQueue(label: "ArtworkThumbnails", qos: .userInitiated, attributes: .concurrent)

    // Requests for a thumbnail that's already being made wait for that one instead of making another.
    private let lock = NSLock()
    private var waiting: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = caches.appendingPathComponent("CoverThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mem.totalCostLimit = 64 * 1024 * 1024 // ~64MB of decoded thumbnails
    }

    /// Instant, memory-only lookup. Safe to call while building a view.
    func cached(_ artworkID: String) -> UIImage? {
        mem.object(forKey: artworkID as NSString)
    }

    /// Memory → disk → build from the full image. Never blocks the main thread.
    func thumbnail(for artworkID: String) async -> UIImage? {
        if let img = cached(artworkID) { return img }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if waiting[artworkID] != nil {
                waiting[artworkID]!.append { continuation.resume(returning: $0) }
                lock.unlock()
                return
            }
            waiting[artworkID] = [{ continuation.resume(returning: $0) }]
            lock.unlock()

            queue.async { [self] in
                let img = loadOrBuild(artworkID)
                if let img, let cg = img.cgImage {
                    mem.setObject(img, forKey: artworkID as NSString, cost: cg.bytesPerRow * cg.height)
                }
                lock.lock()
                let callbacks = waiting.removeValue(forKey: artworkID) ?? []
                lock.unlock()
                callbacks.forEach { $0(img) }
            }
        }
    }

    /// Get covers ready in the background (e.g. right after the library loads).
    func prewarm<S: Sequence>(_ artworkIDs: S) where S.Element == String {
        for id in Set(artworkIDs) where cached(id) == nil {
            Task.detached(priority: .utility) { _ = await self.thumbnail(for: id) }
        }
    }

    // MARK: - Private

    private func loadOrBuild(_ id: String) -> UIImage? {
        let diskURL = folder.appendingPathComponent(id).appendingPathExtension("jpg")

        // Check first: ImageIO logs a scary-looking error for every missing file it's asked to open.
        if FileManager.default.fileExists(atPath: diskURL.path),
           let source = CGImageSourceCreateWithURL(diskURL as CFURL, nil),
           let cg = makeThumbnail(from: source) {
            return UIImage(cgImage: cg)
        }

        guard let data = ArtworkStore.shared.data(for: id),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = makeThumbnail(from: source) else { return nil }

        let img = UIImage(cgImage: cg)
        if let jpg = img.jpegData(compressionQuality: 0.85) {
            try? jpg.write(to: diskURL, options: .atomic)
        }
        return img
    }

    /// ImageIO scales while decoding (much cheaper than decoding full size then redrawing)
    /// and returns an already-decoded image, so drawing it on screen costs nothing extra.
    private func makeThumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A cover thumbnail that shows immediately when cached and loads in the background otherwise.
struct ArtworkThumbView: View {
    let artworkID: String?

    @State private var image: UIImage?

    init(artworkID: String?) {
        self.artworkID = artworkID
        // Start with the cached image so there's no placeholder flash for covers we've already shown.
        _image = State(initialValue: artworkID.flatMap { ArtworkThumbnails.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: artworkID) {
            guard let artworkID else { image = nil; return }
            if let cached = ArtworkThumbnails.shared.cached(artworkID) {
                image = cached
            } else {
                image = await ArtworkThumbnails.shared.thumbnail(for: artworkID)
            }
        }
    }
}
