import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("@spec PROJECT-4.3: While the Mac sidebar shows projects from several hosts, the application shall list same-origin checkouts as one project with one rail badge total, keep the project selected when one of its hosts leaves, and show the rows of every host.")
struct SidebarMergedRowsTests {
    private let local = WorktreeOrigin(deviceID: .init(value: "mac"), deviceLabel: "MacBook", relayDepth: 0)
    private let box = WorktreeOrigin(deviceID: .init(value: "box"), deviceLabel: "build-box", relayDepth: 0)

    private func project(_ id: String, _ owner: WorktreeOrigin, key: String? = "github.com/acme/app") -> SidebarProject {
        SidebarProject(id: id, repositoryID: "/" + id, name: "app", owner: owner, originKey: key)
    }
    private func row(_ name: String, _ owner: WorktreeOrigin, project: String, depth: Int = 0, activity: Double? = nil) -> WorktreePanes {
        WorktreePanes(path: "/\(owner.deviceID.value)/\(name)", displayName: name, repoDisplayName: "app", displayBranch: name, state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: owner.deviceID, deviceLabel: owner.deviceLabel, relayDepth: depth),
            sidebar: .init(id: "\(project):\(name)", projectID: project, isPinned: false, activityTime: activity))
    }
    private func make(projects: [SidebarProject], local localRows: [WorktreePanes] = [], remote: [WorktreePanes] = []) -> SidebarMergedRows {
        SidebarMergedRows.make(projects: projects, localRows: localRows, remoteRows: remote, localDeviceID: local.deviceID,
                               availability: { $0.isAvailable ? .reachable : .offline })
    }

    @Test func localAndRemoteSameOriginShareOneRailEntry() {
        let merged = make(projects: [project("m", local), project("b", box)],
                          local: [row("one", local, project: "m", activity: 1)],
                          remote: [row("two", box, project: "b", activity: 2)])
        #expect(merged.projects.count == 1)
        let section = merged.sections(for: merged.projects[0].id)
        #expect(section.temporary.map(\.row.displayName) == ["two", "one"])
    }
    @Test func railCountsCoverAllHosts() {
        let merged = make(projects: [project("m", local), project("b", box), project("c", box, key: nil)])
        #expect(merged.rekeyed(["m": 1, "b": 2, "c": 4]) == ["origin:github.com/acme/app": 3, "c": 4])
    }
    @Test func selectionSurvivesWhenOneHostLeaves() {
        let both = make(projects: [project("m", local), project("b", box)])
        let id = both.selectedProjectID(for: "b")
        #expect(id == "origin:github.com/acme/app")
        let one = make(projects: [project("m", local)])
        #expect(one.selectedProjectID(for: id) == id)
        #expect(one.project(id: id)?.members.map(\.id) == ["m"])
    }
    @Test func savedMemberSelectionMigratesToMergedID() {
        let merged = make(projects: [project("m", local)])
        #expect(merged.selectedProjectID(for: "m") == "origin:github.com/acme/app")
    }
    @Test func unknownSelectionIsNil() {
        #expect(make(projects: [project("m", local)]).selectedProjectID(for: "gone") == nil)
    }
    @Test func rowsWithUnknownProjectStayVisible() {
        let merged = make(projects: [], remote: [row("two", box, project: "legacy")])
        #expect(merged.projects.map(\.id) == ["legacy"])
        #expect(merged.sections(for: "legacy").temporary.count == 1)
    }
    @Test func relayedRowsAreLeftOut() {
        let merged = make(projects: [project("b", box)], remote: [row("two", box, project: "b", depth: 1)])
        #expect(merged.sections(for: merged.projects[0].id).temporary.isEmpty)
    }
    @Test func frozenOrderHoldsTemporaryRows() {
        let merged = make(projects: [project("m", local)], local: [row("a", local, project: "m", activity: 1), row("b", local, project: "m", activity: 2)])
        let id = merged.projects[0].id
        let live = merged.sections(for: id).temporary.map(\.id)
        #expect(live.count == 2)
        let frozen = merged.sections(for: id, frozenOrder: Array(live.reversed())).temporary.map(\.id)
        #expect(frozen == Array(live.reversed()))
    }
    @Test func projectColumnOffGroupsByProject() {
        let merged = make(projects: [project("m", local), project("c", box, key: "github.com/acme/tool")],
                          local: [row("one", local, project: "m")], remote: [row("two", box, project: "c")])
        #expect(merged.projects.map { merged.sections(for: $0.id).temporary.map(\.row.displayName) } == [["one"], ["two"]])
    }
}

@Suite("@spec LAYOUT-2.205: When the user right-clicks a terminal while the web server is listening, the application shall offer Copy web URL for that pane.")
struct PaneWebURLTests {
    @Test func composesURLForOwningSession() {
        let slot = PaneSlotID()
        var worktree = WorktreeEntry(path: "/r/w", branch: "w", state: .running, splitTree: SplitTree(root: .leaf(slot)))
        let session = worktree.ensurePaneSession(for: slot)
        let repos = [RepoEntry(path: "/r", displayName: "r", worktrees: [worktree])]
        let url = SidebarView.paneWebURL(terminalID: slot, repos: repos, host: "mac.local", port: 8799)
        #expect(url == WebURLComposer.url(session: ZmxLauncher.sessionName(for: session), host: "mac.local", port: 8799))
        #expect(SidebarView.paneWebURL(terminalID: PaneSlotID(), repos: repos, host: "mac.local", port: 8799) == nil)
    }
}

@Suite("@spec LAYOUT-2.206: When a user drags a pinned row or a project, the application shall write the new rank to the hosts that own it, so the same order appears on every device, and shall keep older hosts' moves on their existing request.")
struct SidebarMergedMoveTests {
    private let local = WorktreeOrigin(deviceID: .init(value: "mac"), deviceLabel: "MacBook", relayDepth: 0)
    private let box = WorktreeOrigin(deviceID: .init(value: "box"), deviceLabel: "build-box", relayDepth: 0)

    private func pin(_ name: String, _ owner: WorktreeOrigin, rank: String?) -> WorktreePanes {
        WorktreePanes(path: "/\(owner.deviceID.value)/\(name)", displayName: name, repoDisplayName: "app", repositoryID: "/\(owner.deviceID.value)", displayBranch: name, state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, origin: owner,
            sidebar: .init(id: "\(owner.deviceID.value):repo:\(name)", projectID: "\(owner.deviceID.value):repo", isPinned: true, pinnedRank: rank))
    }
    private func merged(_ rows: [WorktreePanes]) -> SidebarMergedRows {
        let projects = [local, box].map { SidebarProject(id: "\($0.deviceID.value):repo", repositoryID: "/\($0.deviceID.value)", name: "app", owner: $0, originKey: "k/app") }
        return SidebarMergedRows.make(projects: projects, localRows: rows.filter { $0.origin == local }, remoteRows: rows.filter { $0.origin != local },
                                      localDeviceID: local.deviceID, availability: { _ in .reachable })
    }
    private func id(_ row: WorktreePanes) -> String { MergedWorktreeList.identity(row) }

    @Test func pinnedDragAcrossHostsWritesOnlyDraggedHost() throws {
        let a = pin("a", local, rank: "a"), b = pin("b", box, rank: "b"), c = pin("c", local, rank: "c")
        let plan = merged([a, b, c]).pinnedMove(source: id(c), target: id(b), after: false, projectID: "origin:k/app", isWritable: { _ in true })
        guard case .ranks(let writes)? = plan else { Issue.record("\(String(describing: plan))"); return }
        #expect(writes.map(\.row.row.displayName) == ["c"])
        #expect(writes[0].rank > "a" && writes[0].rank < "b")
    }
    @Test func pinnedDragStaysAmongSiblings() {
        let a = pin("agents/a", local, rank: "a"), b = pin("agents/b", box, rank: "b"), c = pin("solo", local, rank: "c")
        #expect(merged([a, b, c]).pinnedMove(source: id(c), target: id(a), after: true, projectID: "origin:k/app", isWritable: { _ in true }) == nil)
        #expect(merged([a, b, c]).pinnedMove(source: id(a), target: id(b), after: true, projectID: "origin:k/app", isWritable: { _ in true }) != nil)
    }
    @Test func olderHostFallsBackToMove() {
        let a = pin("a", box, rank: nil), b = pin("b", box, rank: nil), c = pin("c", local, rank: "a")
        let plan = merged([a, b, c]).pinnedMove(source: id(b), target: id(a), after: false, projectID: "origin:k/app", isWritable: { _ in true })
        guard case .legacy(let source, let target, false)? = plan else { Issue.record("\(String(describing: plan))"); return }
        #expect(source.row.displayName == "b")
        #expect(target.row.displayName == "a")
        #expect(merged([a, b, c]).pinnedMove(source: id(a), target: id(c), after: false, projectID: "origin:k/app", isWritable: { _ in true }) == nil,
                "an older host's row can't cross hosts")
    }
    private func project(_ id: String, _ owner: WorktreeOrigin, key: String, rank: String?, at: Double? = nil) -> SidebarProject {
        SidebarProject(id: id, repositoryID: "/" + id, name: id, owner: owner, originKey: key, rank: rank, rankChangedAt: at)
    }
    private func railMerged(_ projects: [SidebarProject]) -> SidebarMergedRows {
        SidebarMergedRows.make(projects: projects, localRows: [], remoteRows: [], localDeviceID: local.deviceID, availability: { _ in .reachable })
    }
    @Test func railDragWritesAllReachableMembers() {
        let rows = railMerged([project("one", local, key: "k/one", rank: "a"), project("two-m", local, key: "k/two", rank: "b"), project("two-b", box, key: "k/two", rank: "b"), project("three", box, key: "k/three", rank: "c")])
        let plan = rows.projectMove(id: "origin:k/three", target: "origin:k/two", after: false, changedAt: 50, isReachable: { _ in true })
        #expect(plan.count == 1)
        #expect(plan[0].member.id == "three")
        #expect(plan[0].changedAt == 50)
        #expect(plan[0].rank > "a" && plan[0].rank < "b")
        let toMerged = rows.projectMove(id: "origin:k/two", target: "origin:k/one", after: false, changedAt: 50, isReachable: { _ in true })
        #expect(Set(toMerged.map(\.member.id)) == ["two-m", "two-b"])
        #expect(Set(toMerged.map(\.rank)).count == 1)
    }
    @Test func railDragSkipsUnreachableMembersWithoutWaking() {
        let rows = railMerged([project("one", local, key: "k/one", rank: "a"), project("two-m", local, key: "k/two", rank: "b"), project("two-b", box, key: "k/two", rank: "b")])
        let plan = rows.projectMove(id: "origin:k/two", target: "origin:k/one", after: false, changedAt: 50, isReachable: { $0.id == "two-m" })
        #expect(plan.map(\.member.id) == ["two-m"])
    }
    @Test func repairCopiesNewestOnce() {
        var tracker = ProjectRankRepairTracker()
        let member = project("b", box, key: "k/a", rank: "c", at: 1)
        #expect(tracker.due([(member: member, rank: "d", changedAt: 5)]).count == 1)
        #expect(tracker.due([(member: member, rank: "d", changedAt: 5)]).isEmpty)
        #expect(tracker.due([(member: member, rank: "e", changedAt: 9)]).count == 1)
    }
}
