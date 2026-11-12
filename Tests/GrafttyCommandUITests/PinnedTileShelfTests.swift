#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct PinnedTileShelfTests {
    private static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func face(selected: Bool, host: String? = nil) -> PinnedTileFace {
        PinnedTileFace(identity: .none, project: SidebarProject(id: "p", repositoryID: "p", name: "app"), word: "data",
                       hostBadge: host, state: .waiting, isSelected: selected)
    }

    /// Renders `view` over solid red and returns the sRGB colour at a point in points.
    private func pixel<V: View>(_ view: V, size: CGSize, at point: CGPoint) throws -> NSColor {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: Self.red)))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / size.width
        return try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    /// Counts pixels close to the working blue in a render of `view`.
    private func bluePixels<V: View>(_ view: V, size: CGSize) throws -> Int {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // The working blue at any point of its pulse (35–100% opacity) over black.
                if c.blueComponent > 0.25 && c.blueComponent > c.greenComponent + 0.05 && c.greenComponent > c.redComponent { count += 1 }
            }
        }
        return count
    }

    @Test func workingTileShowsItsDot() throws {
        let size = CGSize(width: 80, height: PinnedTileFace.height)
        func tile(_ state: PinnedTileState) -> PinnedTileFace {
            PinnedTileFace(identity: .none, project: SidebarProject(id: "p", repositoryID: "p", name: "app"), word: "data",
                           hostBadge: nil, state: state, isSelected: false)
        }
        #expect(try bluePixels(tile(.working), size: size) > 10, "A working tile draws its blue dot")
        #expect(try bluePixels(tile(.idle), size: size) == 0)
    }

    /// The selected pad must read on a dark glass sidebar without an outline.
    @Test func selectedPadStandsOutOnADarkSidebar() throws {
        let size = CGSize(width: 80, height: PinnedTileFace.height)
        let sidebar = Color(white: 0.2)
        func brightness<V: View>(_ view: V) throws -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(sidebar).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = Double(bitmap.pixelsWide) / size.width
            return try #require(bitmap.colorAt(x: Int(8 * scale), y: Int(8 * scale))?.usingColorSpace(.sRGB)).brightnessComponent
        }
        let plain = try brightness(Color.clear)
        let selected = try brightness(face(selected: true))
        #expect(selected - plain > 0.08, "Selected pad is \(selected) on a \(plain) sidebar")
    }

    @Test("@spec LAYOUT-2.242: While pinned agents are shown as tiles on Mac or mobile, the application shall place them on one shared glass surface and draw each tile as its icon with its name below, without a fill, band, or frame of its own, raising only the selected tile on a borderless pad concentric with the shelf, and naming a tile's host only when another tile shows the same caption.")
    func tilesAreBareOnOneShelf() throws {
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
                && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        let size = CGSize(width: 80, height: PinnedTileFace.height)
        // The bare background, read back through the same colour conversion.
        let background = try pixel(Color.clear, size: size, at: CGPoint(x: 3, y: 3))
        let bare = try pixel(face(selected: false), size: size, at: CGPoint(x: 3, y: 3))
        #expect(same(bare, background), "An unselected tile draws nothing of its own: \(bare) vs \(background)")
        let raised = try pixel(face(selected: true), size: size, at: CGPoint(x: 8, y: 8))
        #expect(!same(raised, background), "The selected tile sits on its own pad: \(raised)")

        // Like a selected toolbar item, the selected tile's pad is concentric with the shelf.
        #expect(PinnedTileFace.cornerRadius == PinnedTileShelf.cornerRadius - PinnedTileShelf.inset)

        // A tile names its host only when another tile shows the same caption.
        #expect(PinnedTile.hostBadges(words: ["main", "main", "data"], hosts: ["KFH6", "MacBook", "KFH6"])
            == ["KFH6", "MacBook", nil])
        #expect(PinnedTile.hostBadges(words: ["main", "data"], hosts: [nil, "KFH6"]) == [nil, nil])

        // Liquid Glass is drawn by the window compositor, which an offscreen snapshot
        // cannot see, so check the shelf's shape: one surface around the whole grid.
        let grid = NSHostingView(rootView: Color.clear.frame(width: 200, height: 120).pinnedTileShelf())
        #expect(grid.fittingSize == CGSize(width: 200 + 2 * PinnedTileShelf.inset, height: 120 + 2 * PinnedTileShelf.inset))
    }
}
#endif
