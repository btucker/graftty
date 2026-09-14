import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public enum ProjectIconDiscovery {
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
        func load(_ candidate: String) -> Data? {
            let url = root.appendingPathComponent(candidate)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            return thumbnail(data)
        }
        for candidate in candidates { if let image = load(candidate) { return image } }
        candidates.removeAll()
        // Search a bounded set of directories for asset catalogs. Never descend
        // into dependencies, worktrees, or build products to find an icon.
        let excluded: Set<String> = [".git", ".worktrees", ".build", "node_modules", "vendor", "Pods"]
        var pending: [(URL, Int)] = [(root, 0)]
        var visited = 0
        while let (directory, depth) = pending.popLast(), visited < 200 {
            visited += 1
            guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { continue }
            for url in urls.sorted(by: { $0.path < $1.path }) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                if directory.lastPathComponent == "AppIcon.appiconset", url.pathExtension.lowercased() == "png" {
                    candidates.append(String(url.path.dropFirst(root.path.count + 1)))
                } else if values?.isDirectory == true, depth < 5, !excluded.contains(url.lastPathComponent) {
                    pending.append((url, depth + 1))
                }
            }
        }
        for candidate in candidates { if let image = load(candidate) { return image } }
        return nil
    }
    public static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
