import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol
import GrafttyCommandUI

@Suite
@MainActor
struct PanePreviewClientPoolTests {

    final class FakePreviewClient: PanePreviewClienting {
        let sessionName: String
        var startCount = 0
        var suspendCount = 0
        var resumeCount = 0
        var stopCount = 0

        init(sessionName: String) {
            self.sessionName = sessionName
        }

        func start() { startCount += 1 }
        func suspend() { suspendCount += 1 }
        func resume() { resumeCount += 1 }
        func stop() { stopCount += 1 }
    }

    @Test
    func updateStartsOnlyCappedPreviewClientsAndStopsRemovedClients() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "left", title: "Left", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .split(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(sessionName: "top", title: "Top", attentionText: nil, isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: "bottom", title: "Bottom", attentionText: nil, isBusy: false, attentionSource: nil)
            )
        )

        pool.update(layout: layout, maxLivePreviews: 2)

        #expect(made.map(\.sessionName) == ["left", "top"])
        #expect(made.allSatisfy { $0.startCount == 1 })

        pool.update(layout: .leaf(sessionName: "top", title: "Top", attentionText: nil, isBusy: false, attentionSource: nil), maxLivePreviews: 2)

        #expect(made.first { $0.sessionName == "top" }?.stopCount == 0)
        #expect(made.first { $0.sessionName == "left" }?.stopCount == 1)
        #expect(made.first { $0.sessionName == "bottom" } == nil)
    }

    @Test
    func stopAllStopsEveryActiveClient() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        pool.update(layout: .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "one", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "two", title: "", attentionText: nil, isBusy: false, attentionSource: nil)
        ))

        pool.stopAll()

        #expect(made.map(\.stopCount) == [1, 1])
    }

    @Test("background suspension preserves preview client identity")
    func suspendAndResumeAllPreservesEveryClient() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        pool.update(layout: .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "one", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "two", title: "", attentionText: nil, isBusy: false, attentionSource: nil)
        ))
        let identitiesBefore = pool.clients.mapValues(ObjectIdentifier.init)

        pool.suspendAll()
        pool.resumeAll()

        #expect(pool.clients.mapValues(ObjectIdentifier.init) == identitiesBefore)
        #expect(made.map(\.suspendCount) == [1, 1])
        #expect(made.map(\.resumeCount) == [1, 1])
        #expect(made.map(\.stopCount) == [0, 0])
    }
}

@Suite("Retained interactive pane connections")
@MainActor
struct RetainedPaneClientPoolTests {
    typealias Client = PanePreviewClientPoolTests.FakePreviewClient

    @Test("@spec IPAD-2.11: While iPad panes are mounted, the application shall retain each pane's client independently of the recent-pane cache limit and shall reuse the client after its view is hidden.")
    func mountedPanesAreNotEvictedByOtherTabs() {
        let pool = RetainedPaneClientPool<Client>(capacity: 1)
        let host = UUID(), owner = UUID()
        let a = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "a")
        let b = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "b")
        pool.attach(a, owner: owner)
        let first = pool.acquire(a) { Client(sessionName: "a") }
        pool.attach(b, owner: owner)
        let second = pool.acquire(b) { Client(sessionName: "b") }
        #expect(first.stopCount == 0)
        #expect(second.stopCount == 0)
        #expect(pool.cached(a) === first)
        pool.detach(b, owner: owner)
        #expect(pool.acquire(a) { Client(sessionName: "unexpected") } === first)
        pool.stopAll()
    }

    @Test("@spec IPAD-2.21: When switching iPad workspaces, the application shall release excess cached clients from the inactive workspace even when the new workspace contains unvisited tabs.")
    func unvisitedTabsDoNotInflateCacheCapacity() {
        let pool = RetainedPaneClientPool<Client>(capacity: 4)
        let host = UUID(), oldOwner = UUID(), newOwner = UUID()
        let oldKeys = (0..<6).map { RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "old-\($0)") }
        let newKeys = (0..<10).map { RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "new-\($0)") }
        pool.retainWorkspace(Set(oldKeys), owner: oldOwner)
        for key in oldKeys { _ = pool.acquire(key) { Client(sessionName: key.sessionName) } }
        pool.retainWorkspace(Set(newKeys), owner: newOwner)
        pool.retainWorkspace([], owner: oldOwner)
        #expect(oldKeys.filter { pool.cached($0) != nil }.count == 4)
        pool.stopAll()
    }

    @Test("@spec IPAD-2.20: While an iPad workspace is selected, the application shall retain every visited live tab's renderer beyond the recent-pane cache limit and release closed sessions and inactive workspace retention.")
    func sixWorkspaceTabsRetainTheirRenderers() {
        let pool = RetainedPaneClientPool<Client>(capacity: 4)
        let host = UUID(), workspace = UUID()
        let keys = (0..<6).map { RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "tab-\($0)") }
        pool.retainWorkspace(Set(keys), owner: workspace)
        let clients = keys.map { key in pool.acquire(key) { Client(sessionName: key.sessionName) } }
        for (key, client) in zip(keys, clients) {
            #expect(pool.cached(key) === client)
            #expect(client.stopCount == 0)
        }
        pool.remove(keys[0])
        #expect(clients[0].stopCount == 1)
        pool.retainWorkspace([], owner: workspace)
        #expect(keys.filter { pool.cached($0) != nil }.count == 4)
        pool.stopAll()
    }

    @Test("A retiring route cannot unpin the replacement route's renderer")
    func replacementAttachmentSurvivesOldRouteDetachment() {
        let pool = RetainedPaneClientPool<Client>(capacity: 1)
        let host = UUID(), old = UUID(), replacement = UUID()
        let a = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "a")
        let b = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "b")
        pool.attach(a, owner: old)
        let first = pool.acquire(a) { Client(sessionName: "a") }
        pool.attach(a, owner: replacement)
        pool.detach(a, owner: old)
        pool.attach(b, owner: replacement)
        _ = pool.acquire(b) { Client(sessionName: "b") }
        #expect(pool.cached(a) === first)
        #expect(first.stopCount == 0)
        pool.stopAll()
    }

    @Test("@spec IOS-7.9: While mobile remains in the foreground, switching compact pane views shall retain up to four recently visited pane connections and their existing leadership, reusing connections on return and releasing the least recently visited connection when the limit is exceeded.")
    func switchingReusesConnectionsAndEvictsLeastRecentlyUsed() {
        let pool = RetainedPaneClientPool<Client>(capacity: 2)
        let host = UUID()
        let a = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "a")
        let b = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "b")
        let c = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "c")
        let first = pool.acquire(a) { Client(sessionName: "a") }
        let second = pool.acquire(b) { Client(sessionName: "b") }
        let revisited = pool.acquire(a) { Client(sessionName: "a") }
        #expect(revisited === first)
        #expect(first.startCount == 1)
        #expect(first.stopCount == 0)
        _ = pool.acquire(c) { Client(sessionName: "c") }
        #expect(second.stopCount == 1)
        #expect(first.stopCount == 0)
        pool.stopAll()
        #expect(first.stopCount == 1)
    }

    @Test("Retained panes are host scoped and all suspend on background")
    func hostIdentityAndSuspension() {
        let pool = RetainedPaneClientPool<Client>()
        let a = RetainedPaneClientPool<Client>.Key(hostID: UUID(), sessionName: "same")
        let b = RetainedPaneClientPool<Client>.Key(hostID: UUID(), sessionName: "same")
        let first = pool.acquire(a) { Client(sessionName: "same") }
        let second = pool.acquire(b) { Client(sessionName: "same") }
        #expect(first !== second)
        pool.suspendAll()
        #expect(first.suspendCount == 1)
        #expect(second.suspendCount == 1)
        #expect(pool.acquire(a) { Client(sessionName: "same") } === first)
        #expect(first.resumeCount == 1)
        pool.remove(a)
        #expect(first.stopCount == 1)
        #expect(second.stopCount == 0)
    }
}

@Suite("Mobile workspace persistence and navigation")
@MainActor
struct MobileWorkspaceStoreTests {
    private func leaf(_ name: String) -> PaneLayoutNode {
        .leaf(sessionName: name, title: name, attentionText: nil, isBusy: false, attentionSource: nil)
    }
    private func row() -> WorktreePanes {
        WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
            layout: .split(direction: .horizontal, ratio: 0.5, left: leaf("a"),
                right: .split(direction: .horizontal, ratio: 0.5, left: leaf("b"), right: leaf("shell"))),
            agents: [AgentSessionInfo(id: "a", name: "A", provider: "codex", status: "running", sessionName: "a"),
                AgentSessionInfo(id: "b", name: "B", provider: "claude", status: "waiting", sessionName: "b")])
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "MobileWorkspaceTests-\(UUID())")! }

    @Test("@spec IPAD-2.12: When mobile opens or restores a workspace, the application shall make its focused live session visible in the device-local layout before routing input.")
    func initialAndRestoredFocusSelectTheVisibleTab() throws {
        let defaults = defaults(), host = UUID(), worktree = row()
        let store = MobileWorkspaceStore(defaults: defaults)
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        #expect(store.layout(hostID: host, worktree: worktree).group(containing: "a")?.selected == "a")
        let restored = MobileWorkspaceStore(defaults: defaults)
        restored.synchronize(hostID: host, worktree: worktree, focused: "shell")
        let layout = restored.layout(hostID: host, worktree: worktree)
        #expect(layout.selectedTerminal == "shell")
        #expect(layout.drawerVisible)
    }

    @Test("@spec IPAD-2.13: When the user navigates spatially on iPad, the application shall use selected device-local tabs and the visible terminal drawer without changing the host inventory.")
    func spatialNavigationUsesVisibleTabsAndDrawer() throws {
        let host = UUID(), worktree = row(), store = MobileWorkspaceStore(defaults: defaults())
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        #expect(store.navigationLayout(hostID: host, worktree: worktree)?.leaves.map(\.sessionName) == ["a"])
        store.update(hostID: host, worktree: worktree) { $0.select("shell") }
        let navigation = try #require(store.navigationLayout(hostID: host, worktree: worktree))
        #expect(navigation.leaves.map(\.sessionName) == ["a", "shell"])
        #if canImport(UIKit)
        #expect(PaneLayoutNavigation.spatialNeighbor(in: navigation, of: "a", direction: .down) == "shell")
        #endif
        #expect(worktree.layout?.leaves.count == 3)
    }

    @Test("@spec IPAD-2.14: When an iPad split divider is resized, the application shall persist its device-local ratio through tab selection and workspace restoration.")
    func resizingSurvivesTabSelectionAndReload() throws {
        let host = UUID(), worktree = row(), defaults = defaults()
        let store = MobileWorkspaceStore(defaults: defaults)
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        store.update(hostID: host, worktree: worktree) { layout in
            layout.split("shell", beside: layout.groups[0].id, edge: .right)
        }
        store.resize(hostID: host, worktree: worktree, path: .root, ratio: 0.31)
        store.update(hostID: host, worktree: worktree) { $0.select("b") }
        let restored = MobileWorkspaceStore(defaults: defaults)
        restored.synchronize(hostID: host, worktree: worktree, focused: "b")
        guard case .split(_, let ratio, _, _) = restored.layout(hostID: host, worktree: worktree).root else {
            Issue.record("Expected a split after restoration"); return
        }
        #expect(ratio == 0.31)
    }

    @Test("@spec IPAD-2.15: When the remembered compact agent is no longer live, the application shall return from a terminal to a surviving agent or omit the Back to agent action.")
    func staleCompactAgentFallsBackToLiveAgent() {
        let worktree = row()
        #expect(MobileWorkspaceStore.previousAgent("closed-session", in: worktree) == "a")
        #expect(MobileWorkspaceStore.previousAgent("b", in: worktree) == "b")
        #expect(MobileWorkspaceStore.previousAgent("shell", in: worktree) == "a")
        #expect(MobileWorkspaceStore.previousAgent("a", in: row().with(agents: [])) == nil)
    }

    @Test("@spec IPAD-2.16: When an iPad terminal moves between the drawer and a split group, the application shall preserve its identity and restore the prior canvas focus when the drawer hides.")
    func drawerMovesPreserveSessionAndPriorFocus() throws {
        let host = UUID(), worktree = row(), store = MobileWorkspaceStore(defaults: defaults())
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        store.update(hostID: host, worktree: worktree) { layout in
            layout.split("shell", beside: layout.groups[0].id, edge: .bottom)
        }
        #expect(store.layout(hostID: host, worktree: worktree).groups.count == 2)
        store.update(hostID: host, worktree: worktree) { layout in
            layout.select("a"); layout.moveToDrawer("shell")
            #expect(layout.hideDrawer() == "a")
        }
        let layout = store.layout(hostID: host, worktree: worktree)
        #expect(layout.groups.count == 1)
        #expect(layout.sessions.count == 3)
        #expect(Set(layout.sessions) == ["a", "b", "shell"])
        #expect(!layout.drawerVisible)
        store.synchronize(hostID: host, worktree: worktree, focused: "shell", revealFocused: false)
        #expect(!store.layout(hostID: host, worktree: worktree).drawerVisible)
    }

    @Test("@spec IPAD-2.17: When the iPad terminal drawer is resized, the application shall persist its height per host and worktree and keep the rendered height within the available viewport.")
    func drawerHeightIsPersistedAndViewportBounded() {
        let host = UUID(), worktree = row(), defaults = defaults()
        let store = MobileWorkspaceStore(defaults: defaults)
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        store.update(hostID: host, worktree: worktree) { $0.drawerHeight = 360 }
        let restored = MobileWorkspaceStore(defaults: defaults)
        restored.synchronize(hostID: host, worktree: worktree, focused: "a")
        #expect(restored.layout(hostID: host, worktree: worktree).drawerHeight == 360)
        #expect(MobileWorkspaceStore.drawerHeight(360, available: 300) == 210)
        #expect(MobileWorkspaceStore.drawerHeight(360, available: 0) == 0)
        #expect(store.layout(hostID: UUID(), worktree: worktree).drawerHeight == 240)
    }

    @Test("@spec IPAD-2.18: While mobile displays agent tabs or its compact agent picker, the application shall distinguish waiting, failed, and finished awaiting cleanup without treating a viewer disconnect as assignment completion.")
    func assignmentIndicatorsDistinguishAttentionAndCompletion() {
        func status(_ status: String, attention: Bool = false) -> AgentAssignmentStatus {
            AgentAssignmentStatus(agent: AgentSessionInfo(id: "a", name: "A", provider: "codex", status: status, sessionName: "a"),
                needsInput: attention)
        }
        #expect(status("running", attention: true) == .waiting)
        #expect(status("waiting") == .waiting)
        #expect(status("failed") == .failed)
        #expect(status("awaiting-cleanup", attention: true) == .awaitingCleanup)
        #expect(status("future-state") == .unknown)
        #expect(Set([status("waiting").label, status("failed").label, status("awaiting-cleanup").label]).count == 3)
    }

    @Test("@spec IPAD-2.19: When another device adds sessions to an observed worktree, the application shall preserve the iPad's selected tabs, selected terminal, and drawer visibility until a local focus request selects a new session.")
    func remoteInventoryAdditionsPreserveLocalPresentation() throws {
        let host = UUID(), worktree = row(), store = MobileWorkspaceStore(defaults: defaults())
        store.synchronize(hostID: host, worktree: worktree, focused: "a")
        let inventory = try #require(worktree.layout)
        let expanded = worktree.with(layout: .split(direction: .vertical, ratio: 0.5,
            left: inventory, right: .split(direction: .horizontal, ratio: 0.5,
                left: leaf("other-shell"), right: leaf("other-agent"))),
            agents: (worktree.agents ?? []) + [AgentSessionInfo(id: "other", name: "Other", provider: "codex", status: "running", sessionName: "other-agent")])
        store.synchronize(hostID: host, worktree: expanded, focused: "a", revealFocused: false)
        var layout = store.layout(hostID: host, worktree: expanded)
        #expect(!layout.drawerVisible)
        #expect(layout.selectedTerminal == "shell")
        #expect(layout.group(containing: "a")?.selected == "a")
        store.update(hostID: host, worktree: expanded) { $0.select("other-shell") }
        layout = store.layout(hostID: host, worktree: expanded)
        #expect(layout.drawerVisible)
        #expect(layout.selectedTerminal == "other-shell")
    }
}
