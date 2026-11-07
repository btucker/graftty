import Testing
@testable import GrafttyProtocol

@Suite("@spec LAYOUT-2.221: While a project is on several hosts, the application shall show its temporary worktrees as one flat list by recent activity across hosts and its pinned agents by shared rank, naming the host on pinned rows always and on temporary rows only when names clash.")
struct MergedWorktreeListTests {
    private let mac = WorktreeOrigin(deviceID: RemoteDeviceID(value: "mac"), deviceLabel: "MacBook", relayDepth: 0)
    private let box = WorktreeOrigin(deviceID: RemoteDeviceID(value: "box"), deviceLabel: "build-box", relayDepth: 0)

    private func row(_ name: String, _ owner: WorktreeOrigin?, activity: Double? = nil, pinned: Bool? = false, rank: String? = nil,
                     main: Bool = false, state: WorktreeWireState = .running, folders: [String] = [], folderIDs: [String]? = nil,
                     metadata: Bool = true) -> WorktreePanes {
        let project = "\(owner?.deviceID.value ?? "x"):repo"
        return WorktreePanes(path: "/\(owner?.deviceID.value ?? "x")/\(name)", displayName: name, repoDisplayName: "app", displayBranch: name,
            state: state, isMainCheckout: main, prBadge: nil, stats: nil, attentionText: nil, layout: nil, origin: owner,
            sidebar: metadata ? .init(id: "\(project):\(name)", projectID: project, folders: folders, folderIDs: folderIDs, isPinned: pinned, activityTime: activity, pinnedRank: rank) : nil)
    }
    private func build(_ rows: [WorktreePanes], several: Bool = true) -> (pinned: [MergedWorktreeNode], temporary: [MergedWorktreeRow]) {
        MergedWorktreeList.build(rows: rows, availability: { _ in .reachable }, projectIsOnSeveralHosts: several)
    }
    private func names(_ nodes: [MergedWorktreeNode]) -> [String] {
        nodes.map {
            switch $0 {
            case .row(let row): return row.leafName
            case .folder(_, let name, let children): return "\(name)[\(names(children).joined(separator: ","))]"
            }
        }
    }

    @Test func temporaryRowsMixAcrossHostsByActivity() {
        let result = build([row("a", mac, activity: 5), row("b", box, activity: 9), row("c", mac, activity: 7)])
        #expect(result.temporary.map(\.row.displayName) == ["b", "c", "a"])
    }
    @Test func noActivityAndStaleSortLast() {
        let result = build([row("idle", box), row("gone", mac, activity: 99, state: .stale), row("new", mac, activity: 1)])
        #expect(result.temporary.map(\.row.displayName) == ["new", "idle", "gone"])
    }
    @Test func temporaryIsFlatWithFullName() {
        let result = build([row("spikes/one", mac, activity: 2, folders: ["spikes"]), row("spikes/two", mac, activity: 1, folders: ["spikes"])])
        #expect(result.temporary.map(\.relativeName) == ["spikes/one", "spikes/two"])
        #expect(result.pinned.isEmpty)
    }
    @Test func hostLabelOnlyOnClashForTemporary() {
        let result = build([row("fix", mac, activity: 3), row("fix", box, activity: 2), row("solo", box, activity: 1)])
        #expect(result.temporary.map(\.showsHostLabel) == [true, true, false])
    }
    @Test func hostLabelAlwaysOnPinnedWhenMultiHost() {
        let result = build([row("agent", mac, pinned: true, rank: "a")])
        guard case .row(let pinned) = result.pinned[0] else { Issue.record("expected row"); return }
        #expect(pinned.showsHostLabel)
        #expect(pinned.hostLabel == "MacBook")
    }
    @Test func noLabelsOnSingleHost() {
        let result = build([row("agent", mac, pinned: true, rank: "a"), row("fix", mac, activity: 1), row("fix", mac, activity: 2)], several: false)
        guard case .row(let pinned) = result.pinned[0] else { Issue.record("expected row"); return }
        #expect(!pinned.showsHostLabel)
        #expect(result.temporary.allSatisfy { !$0.showsHostLabel })
    }
    @Test func pinnedSortsByRankAcrossHosts() {
        let result = build([row("m1", mac, pinned: true, rank: "c"), row("b1", box, pinned: true, rank: "a"), row("m2", mac, pinned: true, rank: "b")])
        #expect(names(result.pinned) == ["b1", "m2", "m1"])
    }
    @Test func rankTiesBreakOnHostThenPath() {
        let result = build([row("z", mac, pinned: true, rank: "a"), row("y", box, pinned: true, rank: "a"), row("x", mac, pinned: true, rank: "a")])
        #expect(names(result.pinned) == ["y", "x", "z"])
    }
    @Test func defaultCheckoutsFirstByHostName() {
        let result = build([row("agent", mac, pinned: true, rank: "a"), row("main", mac, pinned: nil, main: true), row("main", box, pinned: nil, main: true)])
        guard case .row(let first) = result.pinned[0], case .row(let second) = result.pinned[1] else { Issue.record("expected rows"); return }
        #expect([first.hostLabel, second.hostLabel] == ["build-box", "MacBook"])
    }
    @Test func foldersMergeAcrossHosts() {
        let result = build([row("agents/one", mac, pinned: true, rank: "b"), row("agents/two", box, pinned: true, rank: "a"), row("solo", mac, pinned: true, rank: "c")])
        #expect(names(result.pinned) == ["agents[two,one]", "solo"])
    }
    @Test func folderSitsAtHighestRankedMember() {
        let result = build([row("first", mac, pinned: true, rank: "b"), row("agents/one", box, pinned: true, rank: "a"), row("agents/two", mac, pinned: true, rank: "c")])
        #expect(names(result.pinned) == ["agents[one,two]", "first"])
    }
    @Test func twoMemberMinimumCountsAcrossHosts() {
        let result = build([row("agents/one", mac, pinned: true, rank: "a"), row("tools/two", box, pinned: true, rank: "b")])
        #expect(names(result.pinned) == ["agents/one", "tools/two"])
    }
    @Test func inferredFoldersStayPerHost() {
        let result = build([row("one", mac, pinned: true, rank: "a", folders: ["work"], folderIDs: ["/Users/me/work"]),
                            row("two", mac, pinned: true, rank: "b", folders: ["work"], folderIDs: ["/Users/me/work"]),
                            row("three", box, pinned: true, rank: "c", folders: ["work"], folderIDs: ["/srv/work"]),
                            row("four", box, pinned: true, rank: "d", folders: ["work"], folderIDs: ["/srv/work"])])
        #expect(names(result.pinned) == ["work · MacBook[one,two]", "work · build-box[three,four]"])
    }
    @Test func olderHostRowsKeptWithoutActivityOrRank() {
        let result = build([row("old-pin", box, pinned: true), row("agent", mac, pinned: true, rank: "a"),
                            row("legacy", box, metadata: false), row("new", mac, activity: 1)])
        #expect(names(result.pinned) == ["agent", "old-pin"])
        #expect(result.temporary.map(\.row.displayName) == ["new", "legacy"])
    }
    @Test func availabilityIsCarried() {
        let asleep = MergedWorktreeList.build(rows: [row("a", box, activity: 1)], availability: { _ in .wakeable }, projectIsOnSeveralHosts: false)
        #expect(asleep.temporary[0].availability == .wakeable)
    }
}

@Suite("@spec REMOTE-13.43: When a host's worktree is reachable both directly and through another host, the application shall list it once, using the direct route.")
struct MergedWorktreeDedupTests {
    private func row(depth: Int, path: String) -> WorktreePanes {
        WorktreePanes(path: path, displayName: "w", repoDisplayName: "app", displayBranch: "w", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: "box"), deviceLabel: "box", relayDepth: depth),
            sidebar: .init(id: "box:repo:w", projectID: "box:repo"))
    }
    @Test func directRouteWinsOverRelay() {
        #expect(MergedWorktreeList.deduplicated([row(depth: 1, path: "relay-1"), row(depth: 0, path: "/w")]).map(\.path) == ["/w"])
    }
    @Test func dedupKeepsRowWhenOnlyRelayRemains() {
        #expect(MergedWorktreeList.deduplicated([row(depth: 1, path: "relay-1")]).map(\.path) == ["relay-1"])
    }
    @Test func samePathOnDifferentOwnersStaysSeparate() {
        let other = WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "app", displayBranch: "w", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: "mac"), deviceLabel: "mac", relayDepth: 0),
            sidebar: .init(id: "mac:repo:w", projectID: "mac:repo"))
        #expect(MergedWorktreeList.deduplicated([row(depth: 0, path: "/w"), other]).count == 2)
    }
}
