import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct ProjectIconCacheTests {
    @Test("@spec REMOTE-22.19: When a headless host sends a bounded source image, the application shall verify its revision and cache a thumbnail no larger than 64 pixels while rejecting invalid or oversized images.")
    func sourceImagesBecomeThumbnails() async throws {
        // Valid large PNG with an uncompressed ancillary payload to exceed the old 64 KiB wire limit.
        let pixels = [UInt8](repeating: 128, count: 128 * 128 * 4)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: String(repeating: "a", count: 70000)]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        #expect(data.count > 65536)
        let cache = ProjectIconCache()
        func project(_ data: Data) -> SidebarProject {
            SidebarProject(id: "project", repositoryID: "/project", name: "Project", owner: nil,
                iconRevision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let valid = project(data)
        cache.reconcile([valid])
        await cache.load(for: valid) { Data("wrong revision".utf8) }
        #expect(cache.icons[valid.id] == nil)
        await cache.load(for: valid) { data }
        let thumbnail = try #require(cache.icons[valid.id])
        #expect(thumbnail.count <= 65536)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64 && decoded.height == 64)
        for invalid in [Data("not an image".utf8), Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
            let item = project(invalid)
            cache.reconcile([item])
            await cache.load(for: item) { invalid }
            #expect(cache.icons[item.id] == nil)
        }
    }
}
