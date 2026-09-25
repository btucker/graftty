import AppKit
import SwiftUI

/// Sample the landmark's center, preferring colorful, lit pixels over dark terrain.
@MainActor
enum WorktreeArtworkPalette {
    private final class Entry: NSObject {
        let colors: [Color]
        init(_ colors: [Color]) { self.colors = colors }
    }
    private static let cache: NSCache<NSImage, Entry> = {
        let cache = NSCache<NSImage, Entry>()
        cache.countLimit = 128
        return cache
    }()

    static func colors(_ image: NSImage) -> [Color] {
        if let accent = (image as? WorktreeSVGMap.Preview)?.territoryColor {
            return [Color(nsColor: accent), Color(nsColor: accent)]
        }
        if let entry = cache.object(forKey: image) { return entry.colors }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return [.gray, .gray] }
        let landmarkPixels = min(CGFloat(cg.height), CGFloat(cg.height) * WorktreeMapLayout.landmarkHeight / image.size.height)
        let landmark = cg.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: landmarkPixels)) ?? cg
        context.draw(landmark, in: CGRect(x: 0, y: 0, width: 32, height: 24))
        var counts: [Int: Double] = [:]
        for y in 4..<20 {
            for x in 5..<27 {
                let i = (y * 32 + x) * 4
                guard bytes[i + 3] > 192 else { continue }
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 75 else { continue }
                let saturation = Double(high - low) / Double(high)
                let key = (r / 32) * 64 + (g / 32) * 8 + b / 32
                counts[key, default: 0] += max(0.05, saturation * saturation) * Double(high) / 255
            }
        }
        let ranked = counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0]! > counts[$1]! }
        func rgb(_ key: Int) -> [Double] {
            [key / 64, (key / 8) % 8, key % 8].map { Double($0) / 7 }
        }
        let primary = ranked.first ?? 292
        let first = rgb(primary)
        let secondary = ranked.first { zip(rgb($0), first).reduce(0) { $0 + abs($1.0 - $1.1) } > 0.6 } ?? primary
        let colors = [first, rgb(secondary)].map { Color(red: $0[0], green: $0[1], blue: $0[2]) }
        cache.setObject(Entry(colors), forKey: image)
        return colors
    }
}
