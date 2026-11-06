#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
private func solidPNG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<16 { for y in 0..<16 { rep.setColor(NSColor(deviceRed: red, green: green, blue: blue, alpha: 1), atX: x, y: y) } }
    return try #require(rep.representation(using: .png, properties: [:]))
}

private let drawing = WorktreeIconIdentity.drawing(revision: "r:25", emoji: "🗃️")

@MainActor
@Suite("@spec LAYOUT-2.203: When the selected linked worktree has a drawing whose image is available, the application shall draw the header wash from that image without clipping it, and otherwise from its emoji.")
struct WorktreeDrawingWashTests {
    @Test func washUsesDrawingImage() throws {
        let png = try solidPNG(red: 1, green: 0, blue: 0)
        let wash = WorktreeHeaderWash(identity: drawing, project: nil, iconData: png, background: .black, isDark: true)
        #expect(wash?.glyph == .drawing(png))
    }

    @Test func drawingFallsBackToEmoji() {
        #expect(WorktreeHeaderWash(identity: drawing, project: nil, iconData: nil, background: .black, isDark: true)?.glyph == .emoji("🗃️"))
        #expect(WorktreeHeaderWash(identity: .drawing(revision: "r", emoji: nil), project: nil, iconData: nil,
                                   background: .black, isDark: true) == nil)
    }
}

@MainActor
@Suite("@spec LAYOUT-2.202: While a linked worktree with a drawing appears in the Mac sidebar or breadcrumb, the application shall show its rendered drawing in place of the emoji.")
struct WorktreeDrawingIdentityViewTests {
    @Test func identityViewShowsDrawing() throws {
        let png = try solidPNG(red: 1, green: 0, blue: 0)
        let project = SidebarProject(id: "p", repositoryID: "/repo", name: "Repo")
        let renderer = ImageRenderer(content: WorktreeIdentityView(identity: drawing, project: project, imageData: png, size: 40)
            .background(Color.white))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9 && color.greenComponent < 0.2 && color.blueComponent < 0.2)
    }
}
#endif
