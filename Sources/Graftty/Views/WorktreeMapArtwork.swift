import AppKit
import SwiftUI

/// Regional color fills the row; fine detail belongs to its landmark.
struct WorktreeMapArtwork: View {
    let image: NSImage
    var decorative = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image(nsImage: Self.terrain(image)).resizable().interpolation(.high)
                Image(nsImage: image).resizable().interpolation(.high)
                    .mask {
                        if decorative {
                            Color.white.opacity(0.08)
                        } else {
                            LinearGradient(stops: [
                                .init(color: .white.opacity(0.08), location: 0),
                                .init(color: .white.opacity(0.08), location: 0.3),
                                // Full detail remains inside even a 220-point column.
                                .init(color: .white, location: 0.5),
                            ], startPoint: .leading, endPoint: .trailing)
                            .mask {
                                if geometry.size.height > WorktreeMapLayout.landmarkHeight {
                                    LinearGradient(stops: [
                                        .init(color: .white, location: 0),
                                        .init(color: .white, location: WorktreeMapLayout.landmarkHeight / geometry.size.height),
                                        .init(color: .clear, location: min(1, 112 / geometry.size.height)),
                                    ], startPoint: .top, endPoint: .bottom)
                                } else {
                                    Color.white
                                }
                            }
                        }
                    }
            }
        }
    }

    private static let terrainCache: NSCache<NSImage, NSImage> = {
        let cache = NSCache<NSImage, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    /// Downsampling removes texture without darkening the image or changing its hue.
    private static func terrain(_ image: NSImage) -> NSImage {
        if let cached = terrainCache.object(forKey: image) { return cached }
        var rect = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0,
              let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 4,
                height: max(1, min(16, Int(ceil(image.size.height * 4 / image.size.width)))),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let raster = context.makeImage() else { return image }
        let terrain = NSImage(cgImage: raster, size: image.size)
        terrainCache.setObject(terrain, forKey: image)
        return terrain
    }
}
