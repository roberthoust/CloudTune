//
//  ArtworkThumbnailCache.swift
//  CloudTune
//
//  Created by Robert Houst on 8/29/25.
//


import UIKit

final class ArtworkThumbnailCache {
    static let shared = ArtworkThumbnailCache()

    private let mem = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "ArtThumbIO", qos: .utility)
    private let folder: URL
    private let targetSize = CGSize(width: 160, height: 160) // grid/list friendly

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("ArtThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mem.countLimit = 400 // tune
        mem.totalCostLimit = 32 * 1024 * 1024 // ~32MB
    }

    func thumbnail(for song: Song, fallbackAlbumName: String?) async -> UIImage? {
        // Key: prefer artwork bytes hash if you have one; else song.id + size
        let keyString = "s:\(song.id)-\(Int(targetSize.width))"
        let key = keyString as NSString

        if let img = mem.object(forKey: key) { return img }

        let diskURL = folder.appendingPathComponent(keyString).appendingPathExtension("jpg")
        if let img = UIImage(contentsOfFile: diskURL.path) {
            mem.setObject(img, forKey: key, cost: img.jpegData(compressionQuality: 0.8)?.count ?? 0)
            return img
        }

        // Generate off the main thread
        return await withCheckedContinuation { cont in
            io.async {
                var img: UIImage?
                if let data = song.artwork, let full = UIImage(data: data) {
                    img = Self.downscale(full, to: self.targetSize)
                } else if let placeholder = UIImage(named: "DefaultCover") {
                    img = Self.downscale(placeholder, to: self.targetSize)
                }

                if let img {
                    self.mem.setObject(img, forKey: key, cost: img.jpegData(compressionQuality: 0.8)?.count ?? 0)
                    if let jpg = img.jpegData(compressionQuality: 0.82) {
                        try? jpg.write(to: diskURL, options: .atomic)
                    }
                }
                cont.resume(returning: img)
            }
        }
    }

    private static func downscale(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
