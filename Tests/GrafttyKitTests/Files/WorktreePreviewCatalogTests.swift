import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

struct WorktreePreviewCatalogTests {
    @Test("@spec IMAGE-2.12: When files are previewed in a worktree, the host shall retain their immutable collections for all authorized clients of that worktree, independently of the originating pane, display owner, and temporary delivery expiry.")
    func sharedCollectionsSurviveNewRequestsAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteOpenStore(previewDirectory: root)
        let first = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("first".utf8))],
            worktree: "/a", paneSessionName: "agent-a", ownerDeviceID: nil)
        _ = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("second".utf8))],
            worktree: "/a", paneSessionName: "agent-b", ownerDeviceID: .init(value: "phone"))
        #expect(await store.list(worktree: "/a", now: .distantFuture).count == 2)
        #expect(await store.list(worktree: "/b").isEmpty)
        let restored = RemoteOpenStore(previewDirectory: root)
        #expect(await restored.list(worktree: "/a").count == 2)
        let id = try #require(first.first?.id)
        #expect(try await restored.read(id: id, worktree: "/a", offset: 0) == Data("first".utf8))
        await #expect(throws: (any Error).self) { try await restored.read(id: id, worktree: "/b", offset: 0) }
    }
    @Test("@spec IMAGE-2.13: When a preview's automatic delivery expires or is withdrawn, the host shall retain it in the worktree library without automatically reopening it on a device.")
    func deliveryIsTemporaryButLibraryIsDurable() async throws {
        let store = RemoteOpenStore()
        let offers = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("plan".utf8))],
            worktree: "/a", paneSessionName: "agent", ownerDeviceID: .init(value: "phone"))
        #expect(await store.list(worktree: "/a").first?.previewOwnerDeviceID != nil)
        await store.withdraw(id: try #require(offers.first?.id), worktree: "/a")
        #expect(await store.list(worktree: "/a").count == 1)
        #expect(await store.list(worktree: "/a").first?.previewOwnerDeviceID == nil)
        _ = try await store.publishPreviews([.init(filename: "next.html", bytes: Data())],
            worktree: "/a", paneSessionName: "agent", ownerDeviceID: .init(value: "phone"))
        #expect(await store.list(worktree: "/a", now: .distantFuture).allSatisfy { $0.previewOwnerDeviceID == nil })
    }
}
