import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct PinnedTileGridTests {
    private func row(_ path: String, host: String) -> MergedWorktreeRow {
        let panes = WorktreePanes(path: path, displayName: "main", repoDisplayName: "app", displayBranch: "main", state: .running,
            isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: host), deviceLabel: host, relayDepth: 0),
            sidebar: .init(id: "\(host):app:main", projectID: "\(host):app"))
        return MergedWorktreeList.build(rows: [panes], availability: { _ in .reachable }, projectIsOnSeveralHosts: true).pinned[0]
    }

    @Test("@spec LAYOUT-2.232: While a project is on several hosts whose checkouts share a path, the application shall draw a tile for each host's pinned agent rather than leaving an empty cell for the second.")
    func tilesWithTheSamePathOnDifferentHostsBothDraw() throws {
        // Two Macs keep the project at the same path. Tiles are keyed by row,
        // which names the host; a tile that set its own path `.id` would blank
        // its twin, so production tiles set none.
        let rows = [row("/Users/me/app", host: "mac"), row("/Users/me/app", host: "studio")]
        #expect(rows[0].id != rows[1].id)
        let grid = PinnedTileGrid(rows: rows) { row in
            Color.red.frame(height: 40)
        }
        .frame(width: 260, alignment: .topLeading)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 1
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        // The adaptive grid puts the two tiles side by side from the left.
        let firstX = Int(PinnedTile.minimumWidth / 2), secondX = Int(PinnedTile.minimumWidth * 1.5) + 6
        for x in [firstX, secondX] {
            let color = try #require(rep.colorAt(x: x, y: 20)?.usingColorSpace(.sRGB))
            #expect(color.redComponent > 0.9 && color.alphaComponent > 0.9, "no tile at x=\(x)")
        }
    }
}

struct SidebarRowIdentityTests {
    @Test("@spec LAYOUT-2.233: While two hosts have worktrees at the same path, the application shall identify each list row by its host and worktree, so neither row hides the other.")
    func sameRowPathOnTwoHostsGetsTwoIdentities() {
        func row(_ host: String) -> WorktreePanes {
            WorktreePanes(path: "/Users/me/app/.worktrees/fix", displayName: "fix", repoDisplayName: "app", displayBranch: "fix",
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: host), deviceLabel: host, relayDepth: 0),
                sidebar: .init(id: "\(host):app:fix", projectID: "\(host):app"))
        }
        let ids = [SidebarRowIdentity.id(for: row("mac")), SidebarRowIdentity.id(for: row("studio"))]
        #expect(Set(ids).count == 2)
        #expect(!ids.contains("/Users/me/app/.worktrees/fix"))
    }
}
