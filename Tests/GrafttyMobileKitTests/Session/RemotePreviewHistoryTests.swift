import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
struct RemotePreviewHistoryTests {
    private let scope = TerminalBrowserRequest.Scope(hostID: UUID(), worktree: "/repo", sessionName: "pane", ownerDeviceID: .init(value: "phone"))

    private func offer() -> RemoteOpenOffer {
        .init(id: UUID(), filename: "context.html", byteCount: 4, paneSessionName: scope.sessionName,
              previewKind: "file", previewOwnerDeviceID: scope.ownerDeviceID)
    }

    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("context.html")
        try Data("test".utf8).write(to: url)
        return url
    }

    @Test("Downloaded previews remain available in their original scope independently of host offers")
    func retainsSnapshotsAndScope() throws {
        var history: RemotePreviewHistory? = RemotePreviewHistory()
        let url = try file()
        let original = offer()
        history?.record(offer: original, scope: scope, files: [url], byteCount: 4)
        #expect(history?.latest(in: scope)?.offer == original)
        #expect(history?.latest(in: scope)?.files == [url])
        for changed in [
            TerminalBrowserRequest.Scope(hostID: UUID(), worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: "/other", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: "other", ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: .init(value: "other"))
        ] { #expect(history?.latest(in: changed) == nil) }
        #expect(try Data(contentsOf: url) == Data("test".utf8))
        history = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Replacing cached previews retains snapshots held by an open presentation")
    func replacementWaitsForFinalOwner() throws {
        let history = RemotePreviewHistory()
        let oldURL = try file()
        var mounted: RemotePreviewHistory.Entry? = history.record(offer: offer(), scope: scope, files: [oldURL], byteCount: 4)
        let newURL = try file()
        history.record(offer: offer(), scope: scope, files: [newURL], byteCount: 4)
        #expect(mounted?.files == [oldURL])
        #expect(history.latest(in: scope)?.files == [newURL])
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        mounted = nil
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test("Session preview retention obeys both collection and byte limits")
    func retentionIsBounded() throws {
        let history = RemotePreviewHistory()
        let oldest = try file()
        history.record(offer: offer(), scope: scope, files: [oldest], byteCount: 4)
        for index in 0..<RemotePreviewHistory.maximumCollections {
            let other = TerminalBrowserRequest.Scope(hostID: scope.hostID, worktree: "/repo-\(index)", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID)
            history.record(offer: offer(), scope: other, files: [try file()], byteCount: 4)
        }
        #expect(history.latest(in: scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        let large = TerminalBrowserRequest.Scope(hostID: scope.hostID, worktree: "/large", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID)
        history.record(offer: offer(), scope: large, files: [try file()], byteCount: RemotePreviewHistory.maximumBytes)
        #expect(history.latest(in: large) != nil)
        let previous = TerminalBrowserRequest.Scope(hostID: scope.hostID, worktree: "/repo-0", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID)
        #expect(history.latest(in: previous) == nil)
    }

    @Test("Forgetting a host releases its retained previews without clearing another host")
    func forgetClearsOnlyMatchingHost() throws {
        let history = RemotePreviewHistory()
        let removed = try file()
        history.record(offer: offer(), scope: scope, files: [removed], byteCount: 4)
        let other = TerminalBrowserRequest.Scope(hostID: UUID(), worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID)
        history.record(offer: offer(), scope: other, files: [try file()], byteCount: 4)
        history.remove(hostID: scope.hostID)
        #expect(history.latest(in: scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(history.latest(in: other) != nil)
    }

}
