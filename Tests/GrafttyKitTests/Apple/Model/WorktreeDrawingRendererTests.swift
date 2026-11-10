#if canImport(AppKit)
import AppKit
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

/// RGBA bytes of a PNG, top row first.
private func pixels(_ png: Data) throws -> (width: Int, bytes: [UInt8]) {
    let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, bytes)
}

private func pixel(_ image: (width: Int, bytes: [UInt8]), x: Int, y: Int) -> [UInt8] {
    let offset = (y * image.width + x) * 4
    return Array(image.bytes[offset..<offset + 4])
}

private let square = WorktreeDrawingSVGTests.svg("<rect x=\"16\" y=\"16\" width=\"32\" height=\"32\" fill=\"primary\"/>")

@Suite("@spec LAYOUT-2.201: When a host serves a worktree drawing, the application shall fill its palette tokens from the worktree's hue, render it to a PNG 256 pixels tall that keeps the drawing's width-to-height ratio, with a white outline, and answer only requests whose revision matches the current drawing.")
struct WorktreeDrawingRendererTests {
    @Test func rendersOpaquePixelsForTokenDrawing() throws {
        let png = try #require(WorktreeDrawingRenderer.png(svg: square, hue: 25))
        let image = try pixels(png)
        #expect(image.width == 256)
        #expect(pixel(image, x: 128, y: 128)[3] == 255)
        #expect(pixel(image, x: 4, y: 4)[3] == 0)
    }

    @Test func wideDrawingKeepsItsShape() throws {
        let wide = WorktreeDrawingSVGTests.svg("<rect x=\"8\" y=\"16\" width=\"32\" height=\"32\" fill=\"primary\"/>", viewBox: "0 0 96 64")
        let image = try pixels(#require(WorktreeDrawingRenderer.png(svg: wide, hue: 25)))
        #expect(image.width == 384)
        // A square stays square: 32 units at 4 pixels each, starting 8 units in.
        #expect(pixel(image, x: 32 + 64, y: 128)[3] == 255)
        #expect(pixel(image, x: 200, y: 128)[3] == 0)
    }

    @Test func primaryTokenUsesHue() throws {
        let warm = try pixels(#require(WorktreeDrawingRenderer.png(svg: square, hue: 25)))
        let cool = try pixels(#require(WorktreeDrawingRenderer.png(svg: square, hue: 200)))
        #expect(pixel(warm, x: 128, y: 128) != pixel(cool, x: 128, y: 128))
        #expect(WorktreeDrawingRenderer.palette(hue: 25)["ink"] == "#24242c")
    }

    @Test func singleQuotedTokensAreColored() throws {
        let quoted = WorktreeDrawingSVGTests.svg("<rect x='16' y='16' width='32' height='32' fill='primary'/>")
        let single = try pixels(#require(WorktreeDrawingRenderer.png(svg: quoted, hue: 25)))
        let double = try pixels(#require(WorktreeDrawingRenderer.png(svg: square, hue: 25)))
        #expect(pixel(single, x: 128, y: 128) == pixel(double, x: 128, y: 128))
    }

    @Test func whiteEdgeSurroundsShape() throws {
        let image = try pixels(#require(WorktreeDrawingRenderer.png(svg: square, hue: 25)))
        let edge = pixel(image, x: 196, y: 128)
        #expect(edge == [255, 255, 255, 255])
    }

    @Test func staleRevisionReturnsNil() throws {
        var worktree = WorktreeEntry(path: "/repo/parser-cache", branch: "parser-cache")
        worktree.drawingHue = 25
        worktree.drawing = WorktreeDrawing(svg: square, hue: 25)
        let repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [WorktreeEntry(path: "/repo", branch: "main"), worktree])]
        let revision = try #require(worktree.drawing?.revision)
        #expect(WorktreeDrawingRenderer.iconResponse(for: repos, worktreeID: "/repo/parser-cache", revision: revision) != nil)
        #expect(WorktreeDrawingRenderer.iconResponse(for: repos, worktreeID: "/repo/parser-cache", revision: "stale") == nil)
        #expect(WorktreeDrawingRenderer.iconResponse(for: repos, worktreeID: "/repo/missing", revision: revision) == nil)
    }

    @Test func dominantHueOfBlueIcon() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<8 { rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let hue = try #require(WorktreeDrawingRenderer.dominantHue(ofImage: png))
        #expect(hue > 255 && hue < 275)
        let gray = try #require(NSBitmapImageRep(data: png))
        for x in 0..<8 { for y in 0..<8 { gray.setColor(NSColor(deviceRed: 0.5, green: 0.5, blue: 0.5, alpha: 1), atX: x, y: y) } }
        #expect(WorktreeDrawingRenderer.dominantHue(ofImage: try #require(gray.representation(using: .png, properties: [:]))) == nil)
    }
}
#endif
