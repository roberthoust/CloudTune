//
//  PlaylistImageCache.swift
//  CloudTune
//
//  Created by Robert Houst on 8/29/25.
//


// PlaylistImageCache.swift
import UIKit

final class PlaylistImageCache {
    static let shared = PlaylistImageCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}