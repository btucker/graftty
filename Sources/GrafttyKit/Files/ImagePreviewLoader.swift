#if canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
#if canImport(Darwin)
import Darwin
#endif

/// Bounds source bytes and first-frame decoding for native image previews.
public enum ImagePreviewLoader {
    public static let maximumBytes = 20 * 1024 * 1024
    public static let maximumEdge = 2048

    public enum Failure: LocalizedError {
        case unreadable, tooLarge, invalidImage
        public var errorDescription: String? {
            switch self {
            case .unreadable: "Choose a readable regular image file."
            case .tooLarge: "Image previews are limited to 20 MB."
            case .invalidImage: "Could not decode this image. Use a PNG, JPEG, HEIC, GIF, WebP, or PDF file."
            }
        }
    }

    public struct Snapshot {
        public let image: CGImage
        public let bytes: Data
    }

    public static func load(_ url: URL) throws -> CGImage { try snapshot(url).image }

    public static func snapshot(_ url: URL) throws -> Snapshot {
        guard url.isFileURL else { throw Failure.unreadable }
        // A FIFO must not block the app before the file-type check.
        let fd = GrafttyPOSIX.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        guard info.st_size <= maximumBytes else { throw Failure.tooLarge }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              image.width <= maximumEdge, image.height <= maximumEdge else { throw Failure.invalidImage }
        return Snapshot(image: image, bytes: bytes)
    }
}
#endif
