import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GrafttyKit

struct ProjectIconDiscoveryTests {
    @Test("@spec PROJECT-3.5: When a project icon has colored pixels, the application shall derive a stable accent from the icon for tinted Attention cards and project initials.")
    func iconAccentFollowsColor() throws {
        let red = try #require(ProjectIconDiscovery.accentHex(png(red: 1, blue: 0)))
        let blue = try #require(ProjectIconDiscovery.accentHex(png(red: 0, blue: 1)))
        #expect(red != blue)
        #expect(ProjectIconDiscovery.accentHex(try png(red: 0, blue: 0)) == nil)
    }
    @Test("@spec PROJECT-3.4: When discovering a project icon, the application shall prefer valid favicons and app icons, then search project asset directories for supported images containing logo in their filename before falling back to initials.")
    func discoversNestedIconsAndLogoFallback() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logo = try png(red: 1, blue: 0)
        let favicon = try png(red: 0, blue: 1)
        try write(logo, "frontend/src/assets/Brand-LOGO.png", in: root)
        #expect(ProjectIconDiscovery.discover(at: root) == ProjectIconDiscovery.thumbnail(logo))
        try write(favicon, "frontend/public/favicon.png", in: root)
        #expect(ProjectIconDiscovery.discover(at: root) == ProjectIconDiscovery.thumbnail(favicon))
        try write(Data("invalid favicon".utf8), "frontend/public/favicon.png", in: root)
        #expect(ProjectIconDiscovery.discover(at: root) == ProjectIconDiscovery.thumbnail(logo))
        try write(favicon, "Resources/AppIcon.png", in: root)
        #expect(ProjectIconDiscovery.discover(at: root) == ProjectIconDiscovery.thumbnail(favicon))
    }

    @Test("Logo discovery skips dependencies, build products, hidden paths, and symbolic links")
    func excludesUnrelatedLogos() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let image = try png(red: 1, blue: 0)
        for directory in ["node_modules", "vendor", "Pods", ".worktrees", ".build", ".hidden", "build", "dist"] {
            try write(image, directory + "/logo.png", in: root)
        }
        try write(image, "logo.png", in: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("assets"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("logo.png"), withDestinationURL: external.appendingPathComponent("logo.png"))
        #expect(ProjectIconDiscovery.discover(at: root) == nil)
    }

    private func write(_ data: Data, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func png(red: CGFloat, blue: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
