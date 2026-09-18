import AppKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree row artwork")
@MainActor
struct WorktreeArtworkBackgroundTests {
    @Test("@spec LAYOUT-2.103: While map artwork appears behind sidebar text, the application shall draw translucent dark backing fitted to each title without changing row dimensions or hiding the full map behind a text column.")
    func backingProtectsTextWithoutChangingItsLayout() throws {
        func render(_ enabled: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: Color.clear.frame(width: 60, height: 20)
                .modifier(ArtworkTextBacking(enabled: enabled)).padding(10).background(.white))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let plain = try render(false), backed = try render(true)
        #expect(plain.pixelsWide == backed.pixelsWide)
        #expect(plain.pixelsHigh == backed.pixelsHigh)
        let center = try #require(backed.colorAt(x: 40, y: 20)?.usingColorSpace(.deviceRGB))
        let outside = try #require(backed.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        #expect(center.redComponent < 0.6)
        #expect(outside.redComponent > 0.95)
    }

    @Test func expandingSidebarKeepsMapPixelsAtTheSameCoordinates() throws {
        let image = NSImage(size: NSSize(width: 320, height: 80))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 80).fill()
        NSColor.blue.setFill()
        NSRect(x: 80, y: 0, width: 240, height: 80).fill()
        image.unlockFocus()
        func render(_ width: CGFloat) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: WorktreeArtworkBackground(image: image,
                backgroundColor: .black, selectionColor: .clear).frame(width: width, height: 140))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let narrow = try render(240), wide = try render(450)
        for x in [30, 90, 170] {
            let a = try #require(narrow.colorAt(x: x, y: 20)?.usingColorSpace(.deviceRGB))
            let b = try #require(wide.colorAt(x: x, y: 20)?.usingColorSpace(.deviceRGB))
            #expect(abs(a.redComponent - b.redComponent) < 0.01)
            #expect(abs(a.blueComponent - b.blueComponent) < 0.01)
        }
        let beyondRight = try #require(wide.colorAt(x: 400, y: 20)?.usingColorSpace(.deviceRGB))
        let beyondBottom = try #require(wide.colorAt(x: 40, y: 120)?.usingColorSpace(.deviceRGB))
        #expect(beyondRight.redComponent < 0.01 && beyondRight.blueComponent < 0.01)
        #expect(beyondBottom.redComponent < 0.01 && beyondBottom.blueComponent < 0.01)
    }

    @Test("@spec LAYOUT-2.104: When a worktree's pane count changes, the application shall retain its landmark in the first 80 points of the map section and sample terminal colors from that area rather than the surrounding terrain.")
    func terminalPaletteIgnoresExtraTerrainBelowLandmark() throws {
        let short = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
        let tall = try WorktreeMapRaster.draw(size: .init(width: 320, height: 500)) { context in
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 500))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
        #expect(WorktreeArtworkPalette.colors(short) == WorktreeArtworkPalette.colors(tall))
    }

    @Test func finalMapSectionFadesEvenWhenItsBlockMatchesImageHeight() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
        let renderer = ImageRenderer(content: WorktreeArtworkBackground(image: image,
            backgroundColor: .black, selectionColor: .clear, fadesBottom: true).frame(width: 320, height: 80))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let top = try #require(bitmap.colorAt(x: 40, y: 10)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(bitmap.colorAt(x: 40, y: 79)?.usingColorSpace(.deviceRGB))
        #expect(top.redComponent > 0.95)
        #expect(bottom.redComponent < 0.25)
    }

    @Test("@spec LAYOUT-2.73: When a worktree has generated artwork, the application shall display its project map section behind its heading and pane rows at a fixed scale and top-left origin, fading its right edge into the sidebar theme without changing block dimensions.", arguments: [false, true], [44, 160])
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
        let leading = try #require(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        let trailing = try #require(bitmap.colorAt(x: 260, y: 20)?.usingColorSpace(.deviceRGB))
        if isDark {
            #expect(leading.redComponent > trailing.redComponent)
            #expect(leading.redComponent > 0.8)
        } else {
            #expect(leading.redComponent < trailing.redComponent)
            #expect(leading.redComponent < 0.2)
        }
    }

    @Test("Pending regeneration dims the terminal gradient and blurs the sidebar map", arguments: [false, true])
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
        if !terminal { #expect(try brightness(pending, 196, 30) > brightness(normal, 196, 30) + 0.01) }
        #expect(try brightness(pending, 260, 30) < brightness(normal, 260, 30) * 0.8)
        #expect(pending.pixelsWide == normal.pixelsWide)
        #expect(pending.pixelsHigh == normal.pixelsHigh)
        if terminal { #expect(try brightness(pending, 260, 150) < 0.01) }
    }

    @Test("@spec LAYOUT-2.74: When preparing Apple fallback artwork, the application shall preserve its aspect ratio and retain up to 512 pixels on its longest edge before composing it into a project map.")
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
