import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("@spec IOS-12.1: When graftty open offers a regular file, the application shall retain a bounded temporary snapshot scoped to the caller's worktree and allow paired clients to retrieve only that offered snapshot in bounded chunks.")
struct RemoteOpenStoreTests {
    @Test("@spec IMAGE-2.7: When validated image snapshots are offered to mobile, the application shall attach explicit image intent and recipient metadata, preserve revision ordering and replace only older image snapshots in the same worktree and pane.")
    func imageSnapshotMetadataAndReplacement() async throws {
        let store = RemoteOpenStore()
        let bytes = Data([1, 2, 3])
        let phone = RemoteDeviceID(value: "phone")
        let file = try await store.offerSnapshot(bytes: bytes, filename: "file.png", worktree: "/a", paneSessionName: "pane")
        let old = try await store.offerSnapshot(bytes: bytes, filename: "old.png", worktree: "/a", paneSessionName: "pane", previewRevision: 1, previewKind: "image", previewOwnerDeviceID: phone)
        let other = try await store.offerSnapshot(bytes: bytes, filename: "other.png", worktree: "/b", paneSessionName: "pane", previewRevision: 1, previewKind: "image", previewOwnerDeviceID: phone)
        let latest = try await store.offerSnapshot(bytes: bytes, filename: "latest.png", worktree: "/a", paneSessionName: "pane", previewRevision: 2, previewKind: "image", previewOwnerDeviceID: phone)
        #expect(latest.previewKind == "image")
        #expect(latest.previewOwnerDeviceID == phone)
        #expect(latest.browserOwnerDeviceID == nil)
        #expect(file.previewKind == nil)
        #expect(await store.list(worktree: "/a") == [file, latest])
        #expect(await store.list(worktree: "/b") == [other])
        await #expect(throws: RemoteOpenStore.Failure.self) {
            try await store.read(id: old.id, worktree: "/a", offset: 0)
        }
        await #expect(throws: RemoteOpenStore.Failure.self) {
            try await store.offerSnapshot(bytes: bytes, filename: "stale.png", worktree: "/a", paneSessionName: "pane", previewRevision: 1, previewKind: "image", previewOwnerDeviceID: phone)
        }
    }
    @Test func snapshotsAndScopesFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(repeating: 65, count: RemoteOpenOffer.chunkBytes + 3)
        try original.write(to: url)
        let store = RemoteOpenStore()
        let offer = try await store.offer(file: url, worktree: "/project", now: Date(timeIntervalSince1970: 0))
        try Data("changed".utf8).write(to: url)
        #expect(await store.list(worktree: "/other", now: Date(timeIntervalSince1970: 1)).isEmpty)
        #expect(await store.list(worktree: "/project", now: Date(timeIntervalSince1970: 1)) == [offer])
        let first = try await store.read(id: offer.id, worktree: "/project", offset: 0, now: Date(timeIntervalSince1970: 1))
        let last = try await store.read(id: offer.id, worktree: "/project", offset: first.count, now: Date(timeIntervalSince1970: 1))
        #expect(first + last == original)
        await #expect(throws: (any Error).self) {
            try await store.read(id: offer.id, worktree: "/other", offset: 0, now: Date(timeIntervalSince1970: 1))
        }
        await #expect(throws: (any Error).self) {
            try await store.read(id: offer.id, worktree: "/project", offset: -1, now: Date(timeIntervalSince1970: 1))
        }
        #expect(await store.list(worktree: "/project", now: Date(timeIntervalSince1970: 901)).isEmpty)
    }

    @Test func rejectsDirectoriesAndOversizedFiles() async throws {
        let store = RemoteOpenStore()
        await #expect(throws: (any Error).self) {
            try await store.offer(file: FileManager.default.temporaryDirectory, worktree: "/project")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: RemoteOpenOffer.maxBytes + 1).write(to: url)
        await #expect(throws: (any Error).self) {
            try await store.offer(file: url, worktree: "/project")
        }
    }

    @Test("@spec REMOTE-4.3: When graftty open offers a URL to a mobile pane, the application shall approve browser tunnels only for the paired device owning that pane until the offer expires.")
    func urlOfferCreatesDeviceScopedTunnelApproval() async throws {
        let store = RemoteOpenStore()
        await #expect(throws: RemoteOpenStore.Failure.self) {
            try await store.offer(file: URL(string: "https://example.com")!, worktree: "/project")
        }
        let approvals = BrowserTunnelApprovalStore()
        let expiry = Date(timeIntervalSince1970: 900)
        let owner = DisplayClientID("ssh-phone-\(UUID().uuidString)")
        let phone = RemoteDeviceID(value: "phone")
        let other = RemoteDeviceID(value: "other")
        #expect(!approvals.isApproved(deviceID: phone, now: Date(timeIntervalSince1970: 0)))
        #expect(approvals.approve(ownerClientID: owner, until: expiry))
        #expect(approvals.isApproved(deviceID: phone, now: Date(timeIntervalSince1970: 899)))
        #expect(!approvals.isApproved(deviceID: other, now: Date(timeIntervalSince1970: 899)))
        #expect(!approvals.isApproved(deviceID: phone, now: expiry))
        let overlappingID = BrowserTunnelApprovalStore()
        #expect(overlappingID.approve(
            ownerClientID: DisplayClientID("ssh-phone-\(UUID().uuidString)-\(UUID().uuidString)"),
            until: expiry
        ))
        #expect(!overlappingID.isApproved(deviceID: phone, now: Date(timeIntervalSince1970: 899)))
        #expect(!overlappingID.approve(ownerClientID: DisplayClientID("ssh-phone-invalid"), until: expiry))
    }
}
