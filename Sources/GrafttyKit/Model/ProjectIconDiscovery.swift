import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

public enum ProjectIconDiscovery {
    /// Open without following a final symlink or blocking on a FIFO, then
    /// validate the opened descriptor so replacing the path cannot bypass it.
    public static func readImageData(at url: URL) -> Data? {
        let limit = 2 * 1024 * 1024
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size <= limit,
              let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    public static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 65536 else { return nil }
        return output as Data
    }
    public static func discover(at root: URL) -> Data? {
        let fm = FileManager.default
        var candidates = [String]()
        for directory in ["", "public/", "static/", "app/", "src/app/"] {
            for ext in ["ico", "png"] { candidates.append(directory + "favicon." + ext) }
        }
        candidates += ["Resources/AppIcon.png", "Resources/AppIcon.icns"]
        func load(_ url: URL) -> Data? {
            guard let data = readImageData(at: url) else { return nil }
            return thumbnail(data)
        }
        for candidate in candidates { if let image = load(root.appendingPathComponent(candidate)) { return image } }
        // Search a bounded set of directories for nested icons and logos. Never descend
        // into dependencies, worktrees, or build products to find an icon.
        let excluded: Set<String> = [".git", ".worktrees", ".build", "node_modules", "vendor", "Pods", "build", "dist", "DerivedData", "Carthage"]
        let imageExtensions: Set<String> = ["png", "ico", "icns", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "bmp"]
        var favicons = [URL]()
        var appIcons = [URL]()
        var logos = [URL]()
        var pending: [(URL, Int)] = [(root, 0)]
        var visited = 0
        var inspected = 0
        while visited < pending.count, visited < 200, inspected < 10000 {
            let (directory, depth) = pending[visited]
            visited += 1
            guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { continue }
            for url in urls.sorted(by: { $0.path < $1.path }) {
                guard inspected < 10000 else { break }
                inspected += 1
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true {
                    if depth < 5, !excluded.contains(url.lastPathComponent) { pending.append((url, depth + 1)) }
                    continue
                }
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if name == "favicon" || name.hasPrefix("favicon-") || name.hasPrefix("favicon_") {
                    favicons.append(url)
                } else if directory.lastPathComponent == "AppIcon.appiconset" || name == "appicon" {
                    appIcons.append(url)
                } else if name.contains("logo") {
                    logos.append(url)
                }
            }
        }
        for candidate in favicons + appIcons + logos { if let image = load(candidate) { return image } }
        return nil
    }
    public static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
