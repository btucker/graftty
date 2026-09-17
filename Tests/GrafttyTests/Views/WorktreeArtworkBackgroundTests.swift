import AppKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree row artwork")
@MainActor
struct WorktreeArtworkBackgroundTests {
    @Test("@spec LAYOUT-2.73: When a worktree has generated artwork, the application shall display one continuous background behind its heading and pane rows without changing block dimensions and apply a theme-colored scrim that protects text on the leading side.", arguments: [false, true], [44, 160])
    func backgroundFitsBlockAndProtectsText(isDark: Bool, height: Int) throws {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        (isDark ? NSColor.white : NSColor.black).setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        image.unlockFocus()
        let renderer = ImageRenderer(content: WorktreeArtworkBackground(
            image: image,
            backgroundColor: isDark ? .black : .white,
            selectionColor: .clear
        ).frame(width: 280, height: CGFloat(height)))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == 280)
        #expect(rendered.height == height)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let leading = try #require(bitmap.colorAt(x: 20, y: height / 2)?.usingColorSpace(.deviceRGB))
        let trailing = try #require(bitmap.colorAt(x: 260, y: height / 2)?.usingColorSpace(.deviceRGB))
        if isDark {
            #expect(leading.redComponent < trailing.redComponent)
            #expect(leading.redComponent < 0.2)
        } else {
            #expect(leading.redComponent > trailing.redComponent)
            #expect(leading.redComponent > 0.8)
        }
    }

    @Test("Pending regeneration blurs and dims only the artwork in both backgrounds", arguments: [false, true])
    func pendingArtworkSoftensEdges(terminal: Bool) throws {
        let context = try #require(CGContext(data: nil, width: 400, height: 200,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        let image = NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 400, height: 200))
        func render(pending: Bool) throws -> NSBitmapImageRep {
            let content: AnyView
            if terminal {
                content = AnyView(WorktreeTerminalBackground(image: image, backgroundColor: .black,
                                                             isRegenerating: pending))
            } else {
                content = AnyView(WorktreeArtworkBackground(image: image, backgroundColor: .black,
                    selectionColor: .clear, isRegenerating: pending))
            }
            let renderer = ImageRenderer(content: content.frame(width: 400, height: 200).background(.black))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let normal = try render(pending: false)
        let pending = try render(pending: true)
        func brightness(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
            try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).redComponent
        }
        // Blur spreads the white half across the formerly sharp boundary.
        #expect(try brightness(pending, 196, 30) > brightness(normal, 196, 30) + 0.01)
        #expect(try brightness(pending, 260, 30) < brightness(normal, 260, 30) * 0.8)
        #expect(pending.pixelsWide == normal.pixelsWide)
        #expect(pending.pixelsHigh == normal.pixelsHigh)
        if terminal { #expect(try brightness(pending, 260, 150) < 0.01) }
    }

    @Test("@spec LAYOUT-2.74: When caching generated worktree artwork, the application shall preserve its aspect ratio and retain up to 512 pixels on its longest edge for row backgrounds.")
    func backgroundThumbnailPreservesDetailAndAspectRatio() throws {
        let context = try #require(CGContext(data: nil, width: 1024, height: 512,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try #require(context.makeImage())
        let data = try ImageCreatorWorktreeIcon.thumbnailData(from: source)
        let thumbnail = try #require(NSBitmapImageRep(data: data))
        #expect(thumbnail.pixelsWide == 512)
        #expect(thumbnail.pixelsHigh == 256)
    }
}
