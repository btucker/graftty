import AppKit
import CryptoKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
import GrafttyRemoteClient
@testable import Graftty

@MainActor
private final class RemoteScrollHarness: ObservableObject {
    @Published var expansion = RemoteSidebarExpansion()
    @Published var heights: [String: CGFloat] = [:]
    let model: RemoteMacsModel
    let remote: RemoteMac
    let directory: URL
    var rows: [WorktreePanes]

    init(metadata: Bool) throws {
        directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = RemoteMacStore(storeURL: directory.appendingPathComponent("remotes.json"))
        remote = RemoteMac(id: .init(value: UUID().uuidString), label: "Test Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x22, count: 32)),
            lastKnownBaseURL: nil, addedAt: Date())
        try store.add(remote)
        model = RemoteMacsModel(store: store)
        let projectID = remote.id.value + ":repo"
        rows = (0..<8).map { index in
            WorktreePanes(path: "/remote/row-\(index)", displayName: "Row \(index)", repoDisplayName: "Remote repo",
                repositoryID: "repo", displayBranch: "row-\(index)", state: .closed, isMainCheckout: index == 0,
                prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: metadata ? .init(id: "row-\(index)", projectID: projectID, isPinned: index < 3) : nil)
        }
    }
}

private struct RemoteScrollRegions: View {
    @ObservedObject var harness: RemoteScrollHarness
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(.pinned).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { harness.heights["pinned"] = $0 }
            section(.tasks).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { harness.heights["tasks"] = $0 }
            Spacer(minLength: 0)
        }
    }
    private func section(_ section: GrafttyCommandUI.SidebarWorktreeSection) -> some View {
        RemoteMacsSection(model: harness.model, expansion: $harness.expansion,
            worktreePanesByRemote: [RemoteMacIdentity(harness.remote): harness.rows], selectedRemoteIdentity: nil,
            theme: .fallback, onSelectRemoteMac: { _ in }, onAddRemoteMac: {}, section: section)
    }
}

@Suite("Remote sidebar scroll regions", .serialized)
@MainActor
struct SidebarRemoteScrollTests {
    @Test(arguments: [false, true])
    func remoteHierarchySharesExpansionAcrossRegions(repository: Bool) async throws {
        let harness = try RemoteScrollHarness(metadata: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await harness.model.loadSavedRemotes()
        let hosted = NSHostingView(rootView: RemoteScrollRegions(harness: harness))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(hosted)
        let before = harness.heights
        if repository {
            harness.expansion.collapsedRepositories.insert(.init(identity: RemoteMacIdentity(harness.remote), id: "repo"))
        } else {
            harness.expansion.collapsedMacs.insert(RemoteMacIdentity(harness.remote))
        }
        try await settle(hosted)
        #expect(try #require(harness.heights["pinned"]) < #require(before["pinned"]))
        #expect(try #require(harness.heights["tasks"]) < #require(before["tasks"]))
    }

    @Test(arguments: [false, true], [false, true])
    func hostsWithoutPinMetadataDoNotOccupyPinnedRegion(disconnected: Bool, hierarchy: Bool) async throws {
        let harness = try RemoteScrollHarness(metadata: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        if disconnected { harness.rows = [] }
        await harness.model.loadSavedRemotes()
        let host = NSHostingController(rootView: RemoteMacsSection(model: harness.model, expansion: .constant(.init()),
            worktreePanesByRemote: [RemoteMacIdentity(harness.remote): harness.rows], selectedRemoteIdentity: nil,
            theme: .fallback, onSelectRemoteMac: { _ in }, onAddRemoteMac: {}, showsMacHierarchy: hierarchy,
            showsRepositoryHeaders: true, section: .pinned))
        #expect(host.sizeThatFits(in: CGSize(width: 320, height: 1000)).height == 0)
    }

    private func settle<V: View>(_ hosted: NSHostingView<V>) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            hosted.layoutSubtreeIfNeeded()
        }
    }
}
