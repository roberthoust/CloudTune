//
//  PlaylistCovers.swift
//  CloudTune
//
//  Playlist cover images, downsampled off the main thread to the size they're shown at and
//  cached in memory. (Covers used to be decoded at full size on the main thread on every redraw.)
//

import ImageIO
import SwiftUI
import UIKit

final class PlaylistCovers: @unchecked Sendable {
    static let shared = PlaylistCovers()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    /// Bumped when a cover file is rewritten under the same name, so stale cache entries are skipped.
    private var versions: [String: Int] = [:]

    /// Call after writing a cover file.
    func invalidate(_ filename: String) {
        lock.lock(); versions[filename, default: 0] += 1; lock.unlock()
    }

    /// Identifies one version of a cover at one size; changes when the cover file is replaced.
    func key(_ filename: String, pixelSize: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return "\(filename)#\(versions[filename] ?? 0)@\(pixelSize)"
    }

    func cached(_ filename: String, pixelSize: Int) -> UIImage? {
        cache.object(forKey: key(filename, pixelSize: pixelSize) as NSString)
    }

    func image(_ filename: String, pixelSize: Int) async -> UIImage? {
        let k = key(filename, pixelSize: pixelSize) as NSString
        if let hit = cache.object(forKey: k) { return hit }
        let url = PlaylistViewModel.getCoversDirectory().appendingPathComponent(filename)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
        }.value
        if let image { cache.setObject(image, forKey: k) }
        return image
    }
}

/// A playlist's cover (or the default cover), square with rounded corners.
struct PlaylistCoverImageView: View {
    let playlist: Playlist
    var side: CGFloat = 150

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?

    private var pixelSize: Int { Int(side * displayScale) }

    var body: some View {
        let filename = playlist.coverArtFilename
        // Use the cache right away so covers we've already shown don't flash.
        let image = loaded ?? filename.flatMap { PlaylistCovers.shared.cached($0, pixelSize: pixelSize) }

        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image("DefaultCover").resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.093, style: .continuous))
        .task(id: filename.map { PlaylistCovers.shared.key($0, pixelSize: pixelSize) }) {
            guard let filename else { loaded = nil; return }
            loaded = await PlaylistCovers.shared.image(filename, pixelSize: pixelSize)
        }
    }
}
