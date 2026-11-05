#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import GrafttyCommandUI

@MainActor
private func png() throws -> Data {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(rep.representation(using: .png, properties: [:]))
}

@MainActor
@Suite("@spec IOS-4.65: When a mobile client fetches a worktree drawing, the application shall keep only a decodable image of at most 262144 bytes for that revision, fetch each revision once at a time, and discard every drawing when the selected host changes.")
struct WorktreeDrawingCacheTests {
    @Test func cacheStoresVerifiedDrawing() async throws {
        let cache = WorktreeDrawingCache()
        let data = try png()
        await cache.load(revision: "r:25") { data }
        #expect(cache.images["r:25"] == data)
        var fetched = false
        await cache.load(revision: "r:25") { fetched = true; return data }
        #expect(!fetched)
    }

    @Test func cacheRejectsOversizedPayload() async throws {
        let cache = WorktreeDrawingCache()
        await cache.load(revision: "big") { Data(count: 262_145) }
        await cache.load(revision: "junk") { Data("not an image".utf8) }
        #expect(cache.images.isEmpty)
    }

    @Test func cacheResetDropsDrawings() async throws {
        let cache = WorktreeDrawingCache()
        let data = try png()
        await cache.load(revision: "r:25") { data }
        cache.reset()
        #expect(cache.images.isEmpty)
    }
}
#endif
