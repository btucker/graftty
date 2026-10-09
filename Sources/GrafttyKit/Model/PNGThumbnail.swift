#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared ImageIO pipeline: decode the first frame or page of any readable
/// image, apply its EXIF orientation, scale so the longer side is at most
/// `maxPixelSize`, and re-encode as PNG.
public enum PNGThumbnail {
    public static func encode(source: CGImageSource, maxPixelSize: Int) -> Data? {
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
