import AppKit
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Worktree row artwork")
@MainActor
struct WorktreeArtworkBackgroundTests {
    @Test("@spec LAYOUT-2.112: While Git divergence counts appear over map artwork, the application shall place them on a compact translucent backing without adding a backing when artwork is absent.")
    func gitStatsBackingProtectsCountsOnBrightTerrain() throws {
        let theme = GhosttyTheme(core: .init(backgroundRGB: .init(r: 1, g: 1, b: 1), foregroundRGB: .init(r: 0, g: 0, b: 0)))
        func render(_ artwork: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: WorktreeRowGutter(stats: .init(ahead: 3, behind: 22, insertions: 0, deletions: 0),
                baseRef: "main", theme: theme, hasArtwork: artwork).padding(4).background(.white))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let backed = try render(true), plain = try render(false)
        let protected = try #require(backed.colorAt(x: 7, y: 7)?.usingColorSpace(.deviceRGB))
        #expect(protected.redComponent < 0.6)
        let outside = try #require(plain.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        #expect(outside.redComponent > 0.95)
    }

    @Test("@spec LAYOUT-2.113: When a project has an avatar, the application shall display it above the worktree-panel search field with a contrast backing and its original aspect ratio.")
    func avatarKeepsAspectRatioOnItsOwnBacking() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 90, height: 30)) { context in
            context.setFillColor(NSColor.green.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 30))
        }
        let renderer = ImageRenderer(content: ProjectMapHeaderAvatar(image: image, backgroundColor: .black, projectName: "Project").background(.white))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        #expect(bitmap.pixelsWide == 46 && bitmap.pixelsHigh == 46)
        let center = try #require(bitmap.colorAt(x: 23, y: 23)?.usingColorSpace(.deviceRGB))
        let margin = try #require(bitmap.colorAt(x: 23, y: 8)?.usingColorSpace(.deviceRGB))
        #expect(center.greenComponent > 0.95)
        #expect(margin.greenComponent < 0.3)
    }

    @Test("@spec LAYOUT-2.103: While map artwork appears behind sidebar text, the application shall retain most of the map brightness beneath subtle continuous shading, use localized shadows for text contrast, and separate neighboring blocks without individual label boxes.")
    func sharedBackingGroupsTitleAndPanesWithoutChangingDimensions() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
        func render(_ enabled: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: WorktreeArtworkBackground(image: image,
                backgroundColor: .black, selectionColor: .clear, groupsText: enabled)
                .frame(width: 280, height: 80))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let plain = try render(false), backed = try render(true)
        #expect(plain.pixelsWide == backed.pixelsWide)
        #expect(plain.pixelsHigh == backed.pixelsHigh)
        let title = try #require(backed.colorAt(x: 40, y: 15)?.usingColorSpace(.deviceRGB))
        let pane = try #require(backed.colorAt(x: 40, y: 45)?.usingColorSpace(.deviceRGB))
        let unshaded = try #require(plain.colorAt(x: 40, y: 15)?.usingColorSpace(.deviceRGB))
        #expect(title.redComponent > unshaded.redComponent * 0.75)
        #expect(title.redComponent < unshaded.redComponent - 0.05)
        #expect(abs(title.redComponent - pane.redComponent) < 0.01)
    }

    @Test func headerTerrainFillsTheHeaderWithoutFadingAtTheWindowTop() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 320, height: 128)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 128))
        }
        let renderer = ImageRenderer(content: WorktreeMapHeaderBackground(image: image, backgroundColor: .black)
            .frame(width: 400, height: 150))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        for y in [1, 75, 148] {
            let color = try #require(bitmap.colorAt(x: 40, y: y)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.5)
            #expect(color.redComponent > color.greenComponent + 0.4)
        }
        let beyondMap = try #require(bitmap.colorAt(x: 380, y: 50)?.usingColorSpace(.deviceRGB))
        #expect(beyondMap.redComponent < 0.01)
    }

    @Test("@spec LAYOUT-2.110: While unused sidebar space remains below the last worktree, the application shall repeat only a decorative map footer at a fixed scale, join repeats without hard seams, and continue the artwork to the bottom edge without fading.")
    func footerRepeatsAtFixedScaleThroughRemainingSpace() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 40))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 40, width: 320, height: 40))
        }
        func render(_ height: CGFloat) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: WorktreeMapTailBackground(image: image, backgroundColor: .black)
                .frame(width: 400, height: height))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let short = try render(320), tall = try render(480)
        func color(_ bitmap: NSBitmapImageRep, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: 40, y: y)?.usingColorSpace(.deviceRGB))
        }
        for y in [10, 70, 90, 150, 170, 230] {
            let a = try color(short, y), b = try color(tall, y)
            #expect(abs(a.redComponent - b.redComponent) < 0.01)
            #expect(abs(a.blueComponent - b.blueComponent) < 0.01)
        }
        #expect(try color(short, 10).redComponent > 0.3)
        #expect(try color(short, 90).blueComponent > 0.3)
        #expect(try color(short, 170).redComponent > 0.3)
        #expect(try color(short, 10).blueComponent < 0.01)
        #expect(try color(short, 90).redComponent < 0.05)
        let before = try color(short, 79), after = try color(short, 80)
        #expect(abs(before.blueComponent - after.blueComponent) < 0.01)
        #expect(try color(short, 319).redComponent > 0.75)
        let beyondRight = try #require(short.colorAt(x: 380, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(beyondRight.redComponent < 0.01)
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

    @Test("@spec LAYOUT-2.105: When the sidebar map ends, the application shall fade the artwork and selection tint into the sidebar background using native rendering.")
    func finalMapSectionFadesEvenWhenItsBlockMatchesImageHeight() throws {
        let image = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
        let renderer = ImageRenderer(content: WorktreeArtworkBackground(image: image,
            backgroundColor: .black, selectionColor: .white.opacity(0.16), fadesBottom: true).frame(width: 320, height: 80))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let top = try #require(bitmap.colorAt(x: 40, y: 10)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(bitmap.colorAt(x: 40, y: 79)?.usingColorSpace(.deviceRGB))
        #expect(top.redComponent > 0.95)
        #expect(bottom.redComponent < 0.06)
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
