#if os(macOS)
import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WideIdentitySlotTests {
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> (Int, Int) -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height, alignment: .topLeading))
        renderer.scale = 1
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return { x, y in rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear }
    }

    private func widePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 96, height: 64), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); rect.fill(); return true
        }
        return try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
    }

    @Test("@spec LAYOUT-2.230: While a worktree row is shown, the application shall give its identity a 60 by 40 point slot that a wide drawing fills, start the row's text after that slot, and keep emoji and project icons at most 32 points.")
    func wideSlotHoldsTheDrawingAndTextFollowsIt() throws {
        let project = SidebarProject(id: "p", repositoryID: "/p", name: "Project")
        let row = SidebarWorktreeRowLayout {
            WorktreeIdentityView(identity: .drawing(revision: "r", emoji: nil), project: project, imageData: try? widePNG(),
                                 size: SidebarWorktreeRowLayout<EmptyView, EmptyView>.identityHeight,
                                 maxWidth: SidebarWorktreeRowLayout<EmptyView, EmptyView>.identityWidth)
        } content: {
            Color.blue.frame(height: 20)
        }
        let pixel = try render(row, width: 300, height: 44)
        // The drawing spans the slot's width and height.
        #expect(pixel(3, 20).redComponent > 0.9)
        #expect(pixel(56, 20).redComponent > 0.9)
        #expect(pixel(30, 3).redComponent > 0.9)
        // Text begins after the slot.
        #expect(pixel(70, 10).blueComponent > 0.9)
        #expect(pixel(63, 10).blueComponent < 0.1)

        let emoji = WorktreeIdentityView(identity: .emoji("🔥"), project: project, size: 40, maxWidth: 60)
        let host = NSHostingView(rootView: emoji)
        #expect(host.fittingSize.height <= WorktreeIdentityView.maxGlyphSize)
    }
}
#endif
