import Testing
@testable import GrafttyProtocol

@Suite("@spec LAYOUT-2.221: While a project is on several hosts, the application shall show its temporary worktrees as one flat list by recent activity across hosts and its pinned agents as one flat grid by shared rank, naming the host on every pinned agent and on every temporary row that is on another host.")
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
    private func build(_ rows: [WorktreePanes], several: Bool = true,
                       local: RemoteDeviceID? = RemoteDeviceID(value: "mac")) -> (pinned: [MergedWorktreeRow], temporary: [MergedWorktreeRow]) {
        MergedWorktreeList.build(rows: rows, availability: { _ in .reachable }, projectIsOnSeveralHosts: several, localDeviceID: local)
    }
    private func names(_ rows: [MergedWorktreeRow]) -> [String] { rows.map(\.leafName) }

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
    @Test func hostLabelOnTemporaryRowsElsewhereOrClashing() {
        let result = build([row("fix", mac, activity: 4), row("fix", box, activity: 3), row("solo", box, activity: 2), row("mine", mac, activity: 1)])
        #expect(result.temporary.map(\.showsHostLabel) == [true, true, true, false])
    }
    @Test func hostLabelAlwaysOnPinnedWhenMultiHost() {
        let result = build([row("agent", mac, pinned: true, rank: "a")])
        let pinned = result.pinned[0]
        #expect(pinned.showsHostLabel)
        #expect(pinned.hostLabel == "MacBook")
    }
    @Test func noLabelsOnSingleHost() {
        let result = build([row("agent", mac, pinned: true, rank: "a"), row("fix", mac, activity: 1), row("fix", mac, activity: 2)], several: false)
        let pinned = result.pinned[0]
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
        #expect(result.pinned.prefix(2).map(\.hostLabel) == ["build-box", "MacBook"])
    }
    /// Names that look like folders, or folders a host published, don't group tiles.
    @Test func pinnedAgentsAreFlat() {
        let result = build([row("agents/one", mac, pinned: true, rank: "b"), row("agents/two", box, pinned: true, rank: "a"),
                            row("solo", mac, pinned: true, rank: "c", folders: ["work"], folderIDs: ["/Users/me/work"])])
        #expect(names(result.pinned) == ["agents/two", "agents/one", "solo"])
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
