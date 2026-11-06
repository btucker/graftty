#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// @spec IOS-10.11
/// Project icons are decoded once per distinct image, not on every redraw of
/// each view that shows one.
enum ProjectIconImage {
    #if canImport(AppKit)
    typealias Platform = NSImage
    #elseif canImport(UIKit)
    typealias Platform = UIImage
    #endif

    /// NSCache is thread-safe; keys compare the bytes, not the instance.
    nonisolated(unsafe) private static let cache: NSCache<NSData, Platform> = {
        let cache = NSCache<NSData, Platform>()
        cache.countLimit = 128
        return cache
    }()

    static func platformImage(_ data: Data) -> Platform? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = Platform(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func image(_ data: Data) -> Image? {
        #if canImport(AppKit)
        platformImage(data).map { Image(nsImage: $0) }
        #else
        platformImage(data).map { Image(uiImage: $0) }
        #endif
    }
}
