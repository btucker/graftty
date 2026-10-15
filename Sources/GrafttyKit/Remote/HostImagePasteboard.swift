#if canImport(AppKit)
import AppKit
import ImageIO
import GrafttyProtocol

enum HostImagePasteboard {
    /// Decode before replacing the clipboard. Bound decoded dimensions as
    /// well as wire size so a small compressed image cannot exhaust memory.
    @MainActor
    static func write(_ data: Data, to destination: NSPasteboard? = nil) -> Bool {
        guard !data.isEmpty, data.count <= ImagePasteMessage.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let pasteboard = destination ?? NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }
}
#else
import Foundation

enum HostImagePasteboard {
    @MainActor static func write(_ data: Data) -> Bool { false }
}
#endif
