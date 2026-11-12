import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("@spec LAYOUT-2.243: When a connected remote worktree advertises a drawing, the Mac application shall fetch its matching revision through the delivering host, cache the image, and show it in sidebar rows, pinned tiles, and the selected worktree header, while preserving user-chosen emoji and home checkout icons.")
struct RemoteWorktreeDrawingTests {
    private func row(revision: String = "drawing:25", isMainCheckout: Bool = false) -> WorktreePanes {
        var metadata = SidebarWorktreeMetadata(id: "worker:feature", projectID: "worker:repo", emoji: "🖼️")
        metadata.drawingRevision = revision
        return WorktreePanes(path: "relay-feature", displayName: "feature", repoDisplayName: "Repo",
            displayBranch: "feature", state: .running, isMainCheckout: isMainCheckout,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
    }

    private func png() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try #require(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func fetchesPromotedPathAndRevisionOnce() async throws {
        let controller = SidebarHostController()
        let row = row()
        let image = try png()
        var requests: [WorktreeManagementRequest] = []
        for _ in 0..<2 {
            await controller.loadRemoteDrawings([row]) { request in
                requests.append(request)
                return .icon(image)
            }
        }
        #expect(requests == [.worktreeIcon(worktreeID: row.path, revision: "drawing:25")])
        #expect(controller.remoteDrawingData(for: row) != nil)
        #expect(controller.remoteDrawingData(for: self.row(revision: "new:25")) == nil)
        var userMetadata = try #require(row.sidebar)
        userMetadata.emojiChosenByUser = true
        let userEmoji = row.with(sidebar: userMetadata)
        #expect(controller.remoteDrawingData(for: userEmoji) == nil)
        let home = self.row(isMainCheckout: true)
        #expect(controller.remoteDrawingData(for: home) == nil)
    }

    @Test func unavailableImageCanBeRetried() async throws {
        let controller = SidebarHostController()
        let row = row()
        await controller.loadRemoteDrawings([row]) { _ in .icon(nil) }
        #expect(controller.remoteDrawingData(for: row) == nil)
        let image = try png()
        await controller.loadRemoteDrawings([row]) { _ in .icon(image) }
        #expect(controller.remoteDrawingData(for: row) != nil)
    }

    @Test func rowUsesRemoteDrawingIdentityWithoutLocalSVG() throws {
        let row = row()
        var entry = WorktreeEntry(path: row.path, branch: row.displayBranch)
        entry.emoji = row.sidebar?.emoji
        let slot = WorktreeRowIdentitySlot(entry: entry, displayName: row.displayName,
            isMainCheckout: false, theme: .fallback, prBadge: nil, status: .working("Rendering"),
            drawingData: try png(), identity: row.iconIdentity)
        let renderer = ImageRenderer(content: slot.frame(width: 48, height: 40).background(Color.white))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let color = try #require(bitmap.colorAt(x: 24, y: 20)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9)
        #expect(color.greenComponent < 0.2)
        #expect(color.blueComponent < 0.2)
    }
}
