import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct SidebarRefreshTests {
    private let owner = WorktreeOrigin(deviceID: .init(value: "sidebar-test"), deviceLabel: "Test", relayDepth: 0)

    @Test("@spec LAYOUT-2.146: When a periodic sidebar snapshot leaves application state unchanged, the application shall avoid writing back the state binding.")
    func unchangedSnapshotDoesNotPublishState() {
        var repo = RepoEntry(path: "/repo", displayName: "Project", worktrees: [WorktreeEntry(path: "/repo", branch: "main")])
        repo.iconOverride = .initials("PR")
        var state = AppState(repos: [repo])
        var writes = 0
        let binding = Binding(get: { state }, set: { state = $0; writes += 1 })
        let controller = SidebarHostController()
        let initial = controller.snapshot(state: binding, owner: owner, remote: [])
        #expect(writes == 1)
        writes = 0
        for _ in 0..<5 {
            #expect(controller.snapshot(state: binding, owner: owner, remote: []) == initial)
        }
        #expect(writes == 0)
    }

    @Test("@spec LAYOUT-2.147: While a project's icon bytes remain unchanged, the application shall reuse its derived sidebar color and revision across refreshes and recalculate them when the icon changes.")
    func iconMetadataIsReusedUntilBytesChange() throws {
        var computations = 0
        let controller = SidebarHostController(resolveAccent: { data in
            computations += 1
            return ProjectIconDiscovery.accentHex(data)
        })
        var repo = RepoEntry(path: "/repo", displayName: "Project", worktrees: [])
        func png(_ color: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: 16, height: 16))
            image.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
            image.unlockFocus()
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        repo.iconOverride = .image(try png(.red))
        controller.refreshIcons([repo])
        let first = controller.project(for: repo, owner: owner)
        for _ in 0..<5 { #expect(controller.project(for: repo, owner: owner) == first) }
        #expect(computations == 1)
        repo.iconOverride = .image(try png(.blue))
        controller.refreshIcons([repo])
        let changed = controller.project(for: repo, owner: owner)
        #expect(changed.iconRevision != first.iconRevision)
        #expect(changed.accentHex != first.accentHex)
        #expect(computations == 2)
        repo.iconOverride = .initials("PR")
        controller.refreshIcons([repo])
        #expect(controller.project(for: repo, owner: owner).accentHex == nil)
        #expect(controller.project(for: repo, owner: owner).iconRevision == nil)
    }
}
