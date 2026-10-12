#if canImport(ImageIO)
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation
import ImageIO
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import UniformTypeIdentifiers

/// Shared ImageIO pipeline: decode the first frame or page of any readable
/// image, apply its EXIF orientation, scale so the longer side is at most
/// `maxPixelSize`, and re-encode as PNG.
public enum PNGThumbnail {
    /// Verify source bytes before decoding; bound both wire payload and decoded thumbnail.
    public static func projectIcon(_ data: Data, revision: String) -> Data? {
        guard data.count <= 2 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == revision,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = encode(source: source, maxPixelSize: 64), thumbnail.count <= 65536 else { return nil }
        return thumbnail
    }

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

#endif
