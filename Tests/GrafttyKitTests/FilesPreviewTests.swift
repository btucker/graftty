import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct FilesPreviewTests {
    @Test("@spec PREVIEW-2.7: When the host evicts or withdraws a preview collection, the application shall remove the whole collection so mobile cannot receive a partial set of files.")
    func evictionAndWithdrawalRemoveWholeCollections() async throws {
        let store = RemoteOpenStore()
        let snapshots = ["one.html", "two.csv"].map { FilePreviewLoader.Snapshot(filename: $0, bytes: Data()) }
        let collection = try await store.offerPreviews(snapshots, worktree: "/a", paneSessionName: "pane", previewRevision: 1, ownerDeviceID: .init(value: "phone"))
        for index in 0..<19 {
            _ = try await store.offerSnapshot(bytes: Data(), filename: "file-\(index).txt", worktree: "/a")
        }
        let listed = await store.list(worktree: "/a")
        #expect(listed.count == 19)
        #expect(!listed.contains { $0.previewGroupID == collection[0].previewGroupID })
        let next = try await store.offerPreviews(snapshots, worktree: "/a", paneSessionName: "pane", previewRevision: 2, ownerDeviceID: .init(value: "phone"))
        await store.withdraw(id: next[0].id, worktree: "/a")
        let remaining = await store.list(worktree: "/a")
        #expect(!remaining.contains { $0.previewGroupID == next[0].previewGroupID })
    }

    @Test("@spec PREVIEW-1.2: When files are requested for native preview, the application shall snapshot readable regular files of any type in order and reject empty collections, more than 20 files, files over 20 MB, or collections over 50 MB.")
    func snapshotsAnyFileTypeAndBoundsResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["explanation.html", "data.csv", "movie.mov", "unknown.custom"].map { root.appendingPathComponent($0) }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
        let snapshots = try FilePreviewLoader.snapshots(files)
        #expect(snapshots.map(\.filename) == files.map(\.lastPathComponent))
        try Data("changed".utf8).write(to: files[0])
        #expect(snapshots[0].bytes == Data("explanation.html".utf8))
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots([]) }
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots(Array(repeating: files[0], count: 21)) }
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots([root]) }
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots([root.appendingPathComponent("missing")]) }
        let large = root.appendingPathComponent("large.bin")
        try Data(count: RemoteOpenOffer.maxBytes + 1).write(to: large)
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots([large]) }
        try Data(count: RemoteOpenOffer.maxBytes).write(to: large)
        #expect(throws: (any Error).self) { try FilePreviewLoader.snapshots([large, large, large]) }
    }

    @Test("@spec PREVIEW-2.2: When a mobile preview collection is offered, the host shall publish all files atomically with a shared collection identity, preserve their order and recipient, and replace only older previews from that pane.")
    func offersOrderedCollectionAndRejectsStaleReplacement() async throws {
        let store = RemoteOpenStore()
        let device = RemoteDeviceID(value: "phone")
        let snapshots = ["one.html", "two.pdf"].map { FilePreviewLoader.Snapshot(filename: $0, bytes: Data($0.utf8)) }
        let other = try await store.offerSnapshot(bytes: Data(), filename: "other", worktree: "/a", paneSessionName: "other")
        let offers = try await store.offerPreviews(snapshots, worktree: "/a", paneSessionName: "pane", previewRevision: 2, ownerDeviceID: device)
        #expect(offers.map(\.filename) == ["one.html", "two.pdf"])
        #expect(offers[0].previewGroupID != nil && offers[0].previewGroupID == offers[1].previewGroupID)
        #expect(offers.allSatisfy { $0.isNativePreview && $0.previewOwnerDeviceID == device })
        await #expect(throws: RemoteOpenStore.Failure.superseded) {
            try await store.offerPreviews(snapshots, worktree: "/a", paneSessionName: "pane", previewRevision: 1, ownerDeviceID: device)
        }
        let replacement = try await store.offerPreviews([snapshots[0]], worktree: "/a", paneSessionName: "pane", previewRevision: 3, ownerDeviceID: device)
        #expect(replacement[0].previewGroupID != offers[0].previewGroupID)
        let listed = await store.list(worktree: "/a")
        #expect(listed == [other] + replacement)
    }
}
