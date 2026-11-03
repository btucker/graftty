import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

struct PreviewRevisionTests {
    @Test("@spec PREVIEW-2.12: When a followed preview's source files change, the host shall revise its stored collection in place, keeping its collection and offer identities and raising its content revision so that clients can refresh without treating it as a new request.")
    func revisionKeepsIdentityAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteOpenStore(previewDirectory: root)
        let published = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("one".utf8))],
            worktree: "/a", paneSessionName: "agent", ownerDeviceID: .init(value: "phone"))
        let original = try #require(published.first)
        let group = try #require(original.previewGroupID)
        let revised = try await store.revisePreview(group: group,
            snapshots: [.init(filename: "plan.html", bytes: Data("second".utf8))], worktree: "/a")
        #expect(revised.first?.id == original.id)
        #expect(revised.first?.previewGroupID == group)
        #expect(revised.first?.contentRevision == 1)
        #expect(revised.first?.byteCount == 6)
        #expect(revised.first?.createdAt == original.createdAt)

        let listed = await store.list(worktree: "/a")
        #expect(listed.count == 1)
        // The temporary delivery keeps its recipient while tracking the new bytes.
        #expect(listed.first?.previewOwnerDeviceID == .init(value: "phone"))
        #expect(listed.first?.contentRevision == 1)
        #expect(try await store.read(id: original.id, worktree: "/a", offset: 0) == Data("second".utf8))

        let restored = RemoteOpenStore(previewDirectory: root)
        #expect(await restored.list(worktree: "/a").first?.contentRevision == 1)
        #expect(try await restored.read(id: original.id, worktree: "/a", offset: 0) == Data("second".utf8))
    }

    @Test("Revising rejects an unknown collection, another worktree, or changed file names.")
    func revisionRejectsMismatches() async throws {
        let store = RemoteOpenStore()
        let published = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("one".utf8))],
            worktree: "/a", paneSessionName: "agent", ownerDeviceID: nil)
        let group = try #require(published.first?.previewGroupID)
        let same = FilePreviewLoader.Snapshot(filename: "plan.html", bytes: Data("two".utf8))
        await #expect(throws: (any Error).self) { try await store.revisePreview(group: UUID(), snapshots: [same], worktree: "/a") }
        await #expect(throws: (any Error).self) { try await store.revisePreview(group: group, snapshots: [same], worktree: "/b") }
        await #expect(throws: (any Error).self) {
            try await store.revisePreview(group: group, snapshots: [.init(filename: "other.html", bytes: Data())], worktree: "/a")
        }
        #expect(try await store.read(id: try #require(published.first?.id), worktree: "/a", offset: 0) == Data("one".utf8))
    }

    @Test("A revision that cannot be saved leaves the stored collection readable.")
    func failedRevisionKeepsPriorBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteOpenStore(previewDirectory: root)
        let published = try await store.publishPreviews([.init(filename: "plan.html", bytes: Data("aaaa".utf8))],
            worktree: "/a", paneSessionName: "agent", ownerDeviceID: nil)
        let offer = try #require(published.first)
        // A directory blocks the index's atomic replacement, as a full disk would.
        let index = root.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index.appendingPathComponent("blocked"), withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await store.revisePreview(group: try #require(offer.previewGroupID),
                snapshots: [.init(filename: "plan.html", bytes: Data("cc".utf8))], worktree: "/a")
        }
        #expect(await store.list(worktree: "/a").first?.contentRevision == nil)
        #expect(try await store.read(id: offer.id, worktree: "/a", offset: 0) == Data("aaaa".utf8))
    }

    @Test("Offers without a content revision decode as an unrevised collection.")
    func legacyOffersAreUnrevised() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","filename":"a","byteCount":1,"previewKind":"file"}"#
        let offer = try JSONDecoder().decode(RemoteOpenOffer.self, from: Data(json.utf8))
        #expect(offer.contentRevision == nil)
        #expect(RemoteOpenOffer.previewCollections(in: [offer]).first?.contentRevision == 0)
    }
}
