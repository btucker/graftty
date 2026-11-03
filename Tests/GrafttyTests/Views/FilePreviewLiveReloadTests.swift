import AppKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

/// Real files and a real store: the behavior under test is the save-to-display path.
@MainActor @Suite(.serialized)
struct FilePreviewLiveReloadTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store: RemoteOpenStore
        let history = FilePreviewHistory()
        let inline = ImagePreviewStore()
        lazy var windows = FilePreviewWindows(history: history, inline: inline)
        lazy var reload = FilePreviewLiveReload(store: store, history: history, windows: windows, pollInterval: .milliseconds(20))
        let pane = PaneSlotID()

        init(previewDirectory: URL? = nil) throws {
            store = RemoteOpenStore(previewDirectory: previewDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func write(_ text: String, to name: String = "plan.html") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        }

        @discardableResult
        func request(_ urls: [URL], session: String = "agent") async throws -> FilePreviewHistory.Entry {
            let snapshots = try FilePreviewLoader.snapshots(urls)
            let offers = try await store.publishPreviews(snapshots, worktree: "/w", paneSessionName: session, ownerDeviceID: nil)
            let files = try zip(snapshots, urls).map { try FilePreviewFile($0.0, sourceURL: $0.1) }
            let entry = history.record(files: files, pane: pane, worktreePath: "/w",
                id: try #require(offers.first?.previewGroupID), createdAt: offers.first?.createdAt)
            reload.follow(group: entry.id, urls: urls, snapshots: snapshots, worktreePath: "/w", paneSessionName: session)
            return entry
        }

        func text(of entry: FilePreviewHistory.Entry, at index: Int = 0) throws -> String {
            String(decoding: try Data(contentsOf: entry.preview.files[index].url), as: UTF8.self)
        }

        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition())
        }

        /// A pane the request router can resolve, for tests that go through `FilePreviewRequest.handle`.
        func trackedPane() -> (state: AppState, path: String, pane: PaneSlotID, session: String) {
            let pane = PaneSlotID(id: UUID()), session = PaneSessionID(id: UUID())
            var worktree = WorktreeEntry(path: "/live-reload/\(UUID().uuidString)", branch: "test")
            worktree.splitTree = SplitTree(root: .leaf(pane))
            worktree.paneSessions[pane] = session
            let state = AppState(repos: [RepoEntry(path: "/live-reload", displayName: "Live", worktrees: [worktree])])
            return (state, worktree.path, pane, ZmxLauncher.sessionName(for: session))
        }

        func phoneOwnedManager(session: String) throws -> TerminalManager {
            let manager = TerminalManager(socketPath: "/tmp/unused-live-reload-socket")
            let ownership = SessionDisplayOwnershipStore()
            manager.displayOwnershipStore = ownership
            let phone = DisplayClientID("ssh-live-phone-\(UUID().uuidString)"), grid = try DisplayGrid(cols: 80, rows: 24)
            _ = ownership.attachClient(sessionName: session, clientID: phone, kind: .ios, role: .interactive, visible: true, grid: grid)
            _ = ownership.claimOwner(sessionName: session, clientID: phone, kind: .ios, grid: grid)
            return manager
        }
    }

    /// Set from a `Data` deallocator or a detached task, and read while polling on the main actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        var value: Bool { lock.withLock { isSet } }
        func set() { lock.withLock { isSet = true } }
    }

    @MainActor private final class RequestGate {
        var released = false
        var requests = 0
    }

    @Test("@spec PREVIEW-1.17: When a source file of the latest preview from a pane changes, whether written in place or atomically replaced, the application shall update that preview and its stored collection without adding a history entry.")
    func savedFileRevisesPreviewInPlace() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("one")
        let entry = try await fixture.request([url])
        fixture.inline.present(entry.preview, for: fixture.pane, worktreePath: "/w")

        _ = try fixture.write("two")
        try await fixture.wait { fixture.history.entries.first?.preview.contentRevision == 1 }
        let revised = try #require(fixture.history.entries.first)
        #expect(fixture.history.entries.count == 1)
        #expect(revised.id == entry.id)
        #expect(try fixture.text(of: revised) == "two")
        #expect(revised.preview.sourceURL == url)
        #expect(fixture.inline.previews[fixture.pane]?.contentRevision == 1)
        #expect(fixture.inline.previews[fixture.pane]?.files.first?.url == revised.preview.files.first?.url)

        // In-place writes never produce a directory event; they must be seen as well.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("three!".utf8))
        try handle.close()
        try await fixture.wait { fixture.history.entries.first?.preview.contentRevision == 2 }
        #expect(try fixture.text(of: try #require(fixture.history.entries.first)) == "three!")
        fixture.reload.stopAll()
    }

    @Test("@spec PREVIEW-1.18: When a newer preview replaces a pane's latest preview, the application shall stop following the earlier preview so that it remains an unchanged snapshot in history.")
    func supersededPreviewStaysFrozen() async throws {
        let fixture = try Fixture()
        let first = try fixture.write("first", to: "first.html")
        let second = try fixture.write("second", to: "second.html")
        let old = try await fixture.request([first])
        let new = try await fixture.request([second])
        _ = try fixture.write("first changed", to: "first.html")
        _ = try fixture.write("second changed", to: "second.html")
        try await fixture.wait { fixture.history.entries.first { $0.id == new.id }?.preview.contentRevision == 1 }
        try await Task.sleep(for: .milliseconds(100))
        let frozen = try #require(fixture.history.entries.first { $0.id == old.id })
        #expect(frozen.preview.contentRevision == 0)
        #expect(try fixture.text(of: frozen) == "first")
        fixture.reload.stopAll()
    }

    @Test("@spec PREVIEW-1.19: If a followed source file is removed, unreadable, or too large, then the application shall keep showing the last good content and resume updating when the file becomes readable again.")
    func missingSourceKeepsLastGoodContent() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("good")
        _ = try await fixture.request([url])
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.history.entries.first?.preview.contentRevision == 0)
        #expect(try fixture.text(of: try #require(fixture.history.entries.first)) == "good")
        _ = try fixture.write("back")
        try await fixture.wait { fixture.history.entries.first?.preview.contentRevision == 1 }
        #expect(try fixture.text(of: try #require(fixture.history.entries.first)) == "back")
        fixture.reload.stopAll()
    }

    @Test("A graftty preview request delivered to a phone follows its source, keeping the same offer for its recipient.")
    func requestRouteFollowsSourceForMobile() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("one")
        let tracked = fixture.trackedPane()
        let manager = try fixture.phoneOwnedManager(session: tracked.session)
        defer { fixture.reload.stopAll() }

        let response = await FilePreviewRequest.handle(path: tracked.path, targets: [url.path], paneSessionName: tracked.session,
            state: { tracked.state }, terminalManager: manager, store: fixture.store, liveReload: fixture.reload)
        #expect(response == .ok)
        let original = try #require(await fixture.store.list(worktree: tracked.path).first)

        _ = try fixture.write("two!")
        let deadline = ContinuousClock.now + .seconds(5)
        var latest = original
        while latest.contentRevision == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            latest = try #require(await fixture.store.list(worktree: tracked.path).first)
        }
        #expect(latest.id == original.id)
        #expect(latest.contentRevision == 1)
        #expect(latest.previewOwnerDeviceID != nil)
        #expect(try await fixture.store.read(id: latest.id, worktree: tracked.path, offset: 0) == Data("two!".utf8))
    }

    @Test("A graftty preview shown on the Mac follows its source.")
    func requestRouteFollowsSourceForMac() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        let url = try fixture.write("one")
        let tracked = fixture.trackedPane()
        let manager = TerminalManager(socketPath: "/tmp/unused-live-reload-socket")
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(terminalID: tracked.pane, app: fakeApp(), worktreePath: tracked.path,
            socketPath: "/tmp/graftty.sock", zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory, zmxBackendFactory: { _, _, _, _ in FakeSurfaceHandleZmxBackend() }))
        manager.insertSurfaceForTesting(handle, for: tracked.pane)
        defer { fixture.reload.stopAll(); FilePreviewWindows.shared.closeAll() }

        let response = await FilePreviewRequest.handle(path: tracked.path, targets: [url.path], paneSessionName: tracked.session,
            state: { tracked.state }, terminalManager: manager, store: fixture.store, liveReload: fixture.reload)
        #expect(response == .ok)
        #expect(FilePreviewWindows.shared.selectedEntry(for: tracked.path) != nil)
        try #require(fixture.reload.followedCount == 1)

        _ = try fixture.write("two!")
        let deadline = ContinuousClock.now + .seconds(5)
        var revision: Int?
        while revision == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            revision = await fixture.store.list(worktree: tracked.path).first?.contentRevision
        }
        #expect(revision == 1)
    }

    @Test("A published request whose delivery then fails still replaces the earlier follow.")
    func publishedRequestReplacesFollowWhenDeliveryFails() async throws {
        let fixture = try Fixture()
        let earlier = try fixture.write("earlier", to: "earlier.html")
        let later = try fixture.write("later", to: "later.html")
        let tracked = fixture.trackedPane()
        let manager = try fixture.phoneOwnedManager(session: tracked.session)
        defer { fixture.reload.stopAll() }
        let first = await FilePreviewRequest.handle(path: tracked.path, targets: [earlier.path], paneSessionName: tracked.session,
            state: { tracked.state }, terminalManager: manager, store: fixture.store, liveReload: fixture.reload)
        #expect(first == .ok)

        // The pane disappears after publishing, on the delivery route's third look at the state.
        var looks = 0
        let second = await FilePreviewRequest.handle(path: tracked.path, targets: [later.path], paneSessionName: tracked.session,
            state: { looks += 1; return looks < 3 ? tracked.state : AppState(repos: []) },
            terminalManager: manager, store: fixture.store, liveReload: fixture.reload)
        guard case .error = second else { Issue.record("Delivery should have failed after publishing"); return }

        _ = try fixture.write("earlier changed", to: "earlier.html")
        _ = try fixture.write("later changed", to: "later.html")
        func revision(of title: String) async -> Int? {
            RemoteOpenOffer.previewCollections(in: await fixture.store.list(worktree: tracked.path))
                .first { $0.title == title }?.contentRevision
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await revision(of: "later.html") != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await revision(of: "later.html") == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await revision(of: "earlier.html") == 0)
    }

    @Test("A file changed while unreadable updates the preview once its permissions are restored.")
    func regainedPermissionResumesUpdates() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("one")
        _ = try await fixture.request([url])
        defer { fixture.reload.stopAll() }
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("two".utf8))
        try handle.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.history.entries.first?.preview.contentRevision == 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try await fixture.wait { fixture.history.entries.first?.preview.contentRevision == 1 }
        #expect(try fixture.text(of: try #require(fixture.history.entries.first)) == "two")
    }

    @Test("A revision the store could not save is retried without another change to the source.")
    func failedRevisionIsRetried() async throws {
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixture = try Fixture(previewDirectory: previews)
        defer {
            fixture.reload.stopAll()
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: previews.path)
            try? FileManager.default.removeItem(at: previews)
        }
        let url = try fixture.write("one")
        _ = try await fixture.request([url])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: previews.path)
        _ = try fixture.write("two")
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.history.entries.first?.preview.contentRevision == 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: previews.path)
        try await fixture.wait { fixture.history.entries.first?.preview.contentRevision == 1 }
        #expect(try fixture.text(of: try #require(fixture.history.entries.first)) == "two")
    }

    @Test("A source written during a read is read again rather than shown torn.")
    func writeDuringReadIsDiscarded() throws {
        let fixture = try Fixture()
        let url = try fixture.write("one")
        let torn = try FilePreviewLiveReload.untornSnapshots(of: [url], observed: [FilePreviewSourceSignature(url: url)]) { urls in
            let snapshots = try FilePreviewLoader.snapshots(urls)
            try Data("one and more".utf8).write(to: urls[0])
            return snapshots
        }
        #expect(torn == nil)
        let settled = try FilePreviewLiveReload.untornSnapshots(of: [url], observed: [FilePreviewSourceSignature(url: url)])
        #expect(settled?.first?.bytes == Data("one and more".utf8))
    }

    @Test("Following a preview does not keep its published bytes in memory.")
    func followReleasesPublishedBytes() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("v")
        defer { fixture.reload.stopAll() }
        let released = Flag()
        func follow() {
            let count = 64 * 1024
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
            let bytes = Data(bytesNoCopy: pointer, count: count, deallocator: .custom { memory, _ in
                memory.deallocate()
                released.set()
            })
            fixture.reload.follow(group: UUID(), urls: [url], snapshots: [.init(filename: "plan.html", bytes: bytes)],
                                  worktreePath: "/w", paneSessionName: "agent")
        }
        follow()
        try await fixture.wait { released.value }
    }

    @Test("A follow ends once its owner is gone.")
    func followEndsWithItsOwner() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("v")
        var reload: FilePreviewLiveReload? = FilePreviewLiveReload(store: fixture.store, history: fixture.history,
            windows: fixture.windows, pollInterval: .milliseconds(10))
        let task = try #require(reload?.follow(group: UUID(), urls: [url], snapshots: [], worktreePath: "/w", paneSessionName: "agent"))
        reload = nil
        let finished = Flag()
        Task { await task.value; finished.set() }
        try await fixture.wait { finished.value }
    }

    @Test("A catalog download overtaken by a newer revision does not replace it, and an older listing starts none.")
    func staleCatalogDownloadDoesNotRegressPreview() async throws {
        let fixture = try Fixture()
        let remote = RemoteOpenStore()
        let snapshot = FilePreviewLoader.Snapshot(filename: "plan.html", bytes: Data("one".utf8))
        let published = try await remote.publishPreviews([snapshot], worktree: "/w", paneSessionName: "agent", ownerDeviceID: nil)
        let group = try #require(published.first?.previewGroupID)
        let entry = fixture.history.record(files: [try FilePreviewFile(snapshot)], pane: fixture.pane, worktreePath: "/w",
                                           id: group, createdAt: published.first?.createdAt)
        fixture.inline.present(entry.preview, for: fixture.pane, worktreePath: "/w")
        _ = try await remote.revisePreview(group: group, snapshots: [.init(filename: "plan.html", bytes: Data("two".utf8))], worktree: "/w")
        let catalog = RemoteOpenOffer.previewCollections(in: await remote.list(worktree: "/w"))

        let gate = RequestGate()
        let request: (RemoteOpenRequest) async throws -> RemoteOpenResponse = { request in
            gate.requests += 1
            while !gate.released { try await Task.sleep(for: .milliseconds(5)) }
            guard case let .read(id, offset) = request else { throw RemoteOpenStore.Failure.invalidFile }
            return .chunk(try await remote.read(id: id, worktree: "/w", offset: offset))
        }
        fixture.windows.syncCatalog(catalog, worktreePath: "/w", request: request)
        let newer = [try FilePreviewFile(.init(filename: "plan.html", bytes: Data("three".utf8)))]
        fixture.windows.applyRevision(previewID: group, worktreePath: "/w", files: newer, contentRevision: 2)
        gate.released = true
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(fixture.inline.previews[fixture.pane])
        #expect(shown.contentRevision == 2)
        #expect(String(decoding: try Data(contentsOf: shown.files[0].url), as: UTF8.self) == "three")

        let requests = gate.requests
        fixture.windows.syncCatalog(catalog, worktreePath: "/w", request: request)
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.requests == requests)
    }

    @Test("A touched file with identical bytes does not revise the preview.")
    func identicalContentIsNotARevision() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("same")
        _ = try await fixture.request([url])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.history.entries.first?.preview.contentRevision == 0)
        fixture.reload.stopAll()
    }

    @Test("Follows are bounded, evicting the least recently requested pane.")
    func followsAreBounded() async throws {
        let fixture = try Fixture()
        let urls = try (0...FilePreviewLiveReload.maximumFollowed).map { try fixture.write("v", to: "f\($0).html") }
        for (index, url) in urls.enumerated() { try await fixture.request([url], session: "s\(index)") }
        #expect(fixture.reload.followedCount == FilePreviewLiveReload.maximumFollowed)
        fixture.reload.stopAll()
    }

    @Test("@spec PREVIEW-1.20: When a preview revision reaches an open native preview, the application shall show the new content in the same preview, keeping the selected file of its collection and the retained old snapshot until Quick Look has switched.")
    func trayKeepsSelectionAcrossRevision() throws {
        _ = NSApplication.shared
        let files = try ["one.html", "two.html"].map { try FilePreviewFile(.init(filename: $0, bytes: Data("v1".utf8))) }
        let preview = ImagePreviewStore.Preview(files: files)
        let tray = NativeFilePreviewTray(preview: preview, onDismiss: {}, onInteraction: { _ in })
        defer { tray.tearDown() }
        tray.nextFile()
        let revisedFiles = try ["one.html", "two.html"].map { try FilePreviewFile(.init(filename: $0, bytes: Data("v2".utf8))) }
        tray.update(preview.revised(files: revisedFiles, contentRevision: 1))
        #expect(tray.selectedIndex == 1)
        #expect(tray.quickLook.previewItem?.previewItemURL == revisedFiles[1].url)
        // Reapplying the same SwiftUI value does not reload Quick Look.
        tray.update(preview.revised(files: revisedFiles, contentRevision: 1))
        #expect(tray.quickLook.previewItem?.previewItemURL == revisedFiles[1].url)
    }

    @Test("@spec PREVIEW-1.21: When a remote host's catalog reports a newer revision of a displayed preview, the application shall download it and update that preview in place.")
    func remoteCatalogRevisionRefreshesDisplayedPreview() async throws {
        let fixture = try Fixture()
        let snapshots: [FilePreviewLoader.Snapshot] = [.init(filename: "plan.html", bytes: Data("one".utf8))]
        let remote = RemoteOpenStore()
        let published = try await remote.publishPreviews(snapshots, worktree: "/w", paneSessionName: "agent", ownerDeviceID: nil)
        let group = try #require(published.first?.previewGroupID)
        let source = URL(fileURLWithPath: "/original/plan.html")
        let files = try snapshots.map { try FilePreviewFile($0, sourceURL: source) }
        let entry = fixture.history.record(files: files, pane: fixture.pane, worktreePath: "/w", id: group, createdAt: published.first?.createdAt)
        fixture.inline.present(entry.preview, for: fixture.pane, worktreePath: "/w")

        _ = try await remote.revisePreview(group: group, snapshots: [.init(filename: "plan.html", bytes: Data("two".utf8))], worktree: "/w")
        let catalog = RemoteOpenOffer.previewCollections(in: await remote.list(worktree: "/w"))
        fixture.windows.syncCatalog(catalog, worktreePath: "/w") { request in
            guard case let .read(id, offset) = request else { throw RemoteOpenStore.Failure.invalidFile }
            return .chunk(try await remote.read(id: id, worktree: "/w", offset: offset))
        }
        try await fixture.wait { fixture.inline.previews[fixture.pane]?.contentRevision == 1 }
        let shown = try #require(fixture.inline.previews[fixture.pane])
        #expect(String(decoding: try Data(contentsOf: shown.files[0].url), as: UTF8.self) == "two")
        #expect(shown.sourceURL == source)
        #expect(fixture.history.entries.count == 1)
    }
}
