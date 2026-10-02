import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol
import Darwin

struct SidebarHostNavigationTests {
    @Test("@spec LAYOUT-2.76: When a worktree has no emoji identity, the application shall leave it identity-less until the first valid agent recap proposes an unused emoji, then retain that emoji across later recaps and relaunches while honoring manual edits.")
    func firstReportClaimsWorktreeEmoji() throws {
        var repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/one", branch: "one")
        ])]
        #expect(repos[0].worktrees.allSatisfy { $0.emoji == nil })
        let first = AttentionRecap(title: "Push notifications", completed: "Client wired.", next: "Test devices.", emoji: "🔔")
        SidebarHostNavigation.adoptReportedEmoji(first, worktreePath: "/repo/one", in: &repos)
        #expect(repos[0].worktrees[1].emoji == "🔔")
        #expect(repos[0].worktrees[1].emojiSource == .agent)
        let later = AttentionRecap(title: "Push notifications", completed: "Device tested.", next: "Merge PR.", emoji: "📱")
        SidebarHostNavigation.adoptReportedEmoji(later, worktreePath: "/repo/one", in: &repos)
        #expect(repos[0].worktrees[1].emoji == "🔔")
        let restored = try JSONDecoder().decode([RepoEntry].self, from: JSONEncoder().encode(repos))
        #expect(restored[0].worktrees[1].emoji == "🔔")
        #expect(SidebarHostNavigation.metadata(for: restored[0].worktrees[1], projectID: "p", folders: []).emoji == "🔔")
        repos[0].worktrees[1].emoji = "🎱"
        repos[0].worktrees[1].emojiSource = .manual
        SidebarHostNavigation.adoptReportedEmoji(first, worktreePath: "/repo/one", in: &repos)
        #expect(repos[0].worktrees[1].emoji == "🎱")
        #expect(repos[0].worktrees[0].emoji == nil)
    }

    @Test("@spec LAYOUT-2.77: When an agent's proposed emoji is already used, the application shall try its task-related alternatives before assigning a worktree identity.")
    func duplicateReportEmojiUsesAlternative() {
        var first = WorktreeEntry(path: "/repo/one", branch: "one")
        first.emoji = "🔔"
        first.emojiSource = .manual
        var repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [first,
            WorktreeEntry(path: "/repo/two", branch: "two")])]
        let recap = AttentionRecap(title: "Push notifications", completed: "Client wired.", next: "Test devices.",
                                   emoji: "🔔", emojiAlternatives: ["📱", "📨"])
        SidebarHostNavigation.adoptReportedEmoji(recap, worktreePath: "/repo/two", in: &repos)
        #expect(repos[0].worktrees[1].emoji == "📱")
    }

    @Test("@spec LAYOUT-2.78: When upgrading from automatically assigned worktree emojis, the application shall remove generated identities while preserving edits that differ from the old automatic choice.")
    func legacyAutomaticEmojisAreCleared() {
        var repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/one", branch: "one")
        ])]
        SidebarHostNavigation.assignLegacyEmojis(in: &repos)
        let generated = repos[0].worktrees[0].emoji
        repos[0].worktrees[1].emoji = "🎱"
        SidebarHostNavigation.migrateLegacyEmojis(in: &repos)
        #expect(generated != nil)
        #expect(repos[0].worktrees[0].emoji == nil)
        #expect(repos[0].worktrees[1].emoji == "🎱")
        #expect(repos[0].worktrees[1].emojiSource == .manual)
    }
    @Test("@spec LAYOUT-2.60: When a worktree is stopped and reopened, the application shall retain recent Attention pane targets for saved layout slots and resolve them to their new sessions without following reused routes.")
    func recentPaneSurvivesStop() throws {
        let slot = PaneSlotID()
        var worktree = WorktreeEntry(path: "/repo/w", branch: "feature", state: .running,
                                    splitTree: SplitTree(root: .leaf(slot)))
        let oldSession = worktree.ensurePaneSession(for: slot)
        let metadata = SidebarHostNavigation.metadata(for: worktree, projectID: "project", folders: [])
        let item = SidebarActivityItem(id: metadata.id + ":" + slot.id.uuidString,
            projectID: "project", worktreeID: worktree.path, paneID: ZmxLauncher.sessionName(for: oldSession),
            projectName: "Repo", worktreeName: "w", title: "Review", occurrence: nil, isBusy: false, branchName: "feature")
        var history = SidebarRecentHistory()
        history.open(item)

        worktree.prepareForStop()
        #expect(worktree.paneSessions.isEmpty)
        func closedRow(_ worktree: WorktreeEntry) -> WorktreePanes {
            WorktreePanes(path: worktree.path, displayName: "w", repoDisplayName: "Repo",
                displayBranch: "feature", state: .closed, isMainCheckout: false, prBadge: nil,
                stats: nil, attentionText: nil, layout: nil,
                sidebar: SidebarHostNavigation.metadata(for: worktree, projectID: "project", folders: []))
        }
        let closed = try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(closedRow(worktree)))
        #expect(SidebarProjection.paneSlotID(for: item, in: try #require(closed.sidebar)) == slot.id.uuidString)
        #expect(SidebarProjection.paneRoute(for: item, in: closed) == nil)
        history.reconcile(worktrees: [closed], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item == item)
        let restored = try JSONDecoder().decode(SidebarRecentHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.entries.first?.item == item)

        worktree.state = .running
        let newSession = worktree.ensurePaneSession(for: slot)
        #expect(newSession != oldSession)
        let newRoute = ZmxLauncher.sessionName(for: newSession)
        let reopened = WorktreePanes(path: worktree.path, displayName: "w", repoDisplayName: "Repo",
            displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil,
            layout: .leaf(sessionName: newRoute, title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: SidebarHostNavigation.metadata(for: worktree, projectID: "project", folders: []))
        #expect(SidebarProjection.paneRoute(for: item, in: reopened) == newRoute)
        history.reconcile(worktrees: [reopened], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.paneID == newRoute)
        #expect(history.entries.first?.item.id == item.id)

        worktree.prepareForStop()
        worktree.splitTree = SplitTree(root: nil)
        history.reconcile(worktrees: [closedRow(worktree)], availableProjectIDs: ["project"])
        #expect(history.entries.isEmpty)
    }

    @Test("Pane history resolves stable slots without following a reused session route")
    func recentPaneRejectsReusedRoute() {
        let item = SidebarActivityItem(id: "worktree:original-slot", projectID: "project", worktreeID: "route", paneID: "old-session",
            projectName: "Repo", worktreeName: "feature", title: "Review", occurrence: nil, isBusy: false)
        let metadata = SidebarWorktreeMetadata(id: "worktree", projectID: "project",
            paneIDs: ["old-session": "different-slot"], paneSlotIDs: ["different-slot"])
        let row = WorktreePanes(path: "route", displayName: "feature", repoDisplayName: "Repo", displayBranch: "feature",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "old-session", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: metadata)
        #expect(SidebarProjection.paneSlotID(for: item, in: metadata) == nil)
        #expect(SidebarProjection.paneRoute(for: item, in: row) == nil)
        let legacy = WorktreePanes(path: "route", displayName: "feature", repoDisplayName: "Repo", displayBranch: "feature",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: row.layout)
        #expect(SidebarProjection.paneRoute(for: item, in: legacy) == "old-session")
    }

    @Test("""
@spec LAYOUT-2.51: When an agent stops in a worktree, the application shall retain its latest unseen stop across relaunches and include it in Attention until that agent resumes or the user visits the worktree.
""")
    func unseenStopSurvivesUntilVisit() throws {
        var worktree = WorktreeEntry(path: "/repo/w", branch: "feature")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100),
                                    providerSessionKey: "codex:session:one")
        worktree.unseenAgentStop = stop
        worktree.clearAgentStopAttention(providerSessionKey: "codex:session:other")
        #expect(worktree.unseenAgentStop == stop)
        #expect(worktree.hasAttention)
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        #expect(restored.unseenAgentStop == stop)
        let metadata = SidebarHostNavigation.metadata(for: restored, projectID: "p", folders: [])
        let row = WorktreePanes(path: worktree.path, displayName: "feature", repoDisplayName: "Repo", displayBranch: "feature", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
        let queue = SidebarActivityFilter.needsYou.apply(to: SidebarProjection.activity([row]))
        #expect(queue.count == 1)
        #expect(queue.first?.title == "Codex stopped")
        #expect(queue.first?.occurrence?.timestamp == stop.stoppedAt)
        worktree.clearAgentStopAttention(providerSessionKey: "codex:session:one")
        #expect(worktree.unseenAgentStop == nil)
        worktree.unseenAgentStop = stop
        worktree.acknowledgeAttention()
        #expect(worktree.unseenAgentStop == nil)
        worktree.unseenAgentStop = stop
        worktree.acknowledgePaneAttention(PaneSlotID())
        #expect(worktree.unseenAgentStop == nil)
    }

    @Test("@spec REMOTE-14.11: When a viewed agent stop is acknowledged remotely, the application shall clear only that stop occurrence and preserve newer stops and unrelated prompts.")
    func acknowledgeExactStop() {
        var worktree = WorktreeEntry(path: "/repo/w", branch: "feature")
        let old = SidebarAgentStop(agentName: "Claude", stoppedAt: Date(timeIntervalSince1970: 100))
        let newer = SidebarAgentStop(agentName: "Claude", stoppedAt: Date(timeIntervalSince1970: 200))
        worktree.unseenAgentStop = newer
        worktree.attention = Attention(text: "Review this", timestamp: Date(), source: .userNotify)
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [worktree])])
        #expect(!SidebarHostNavigation.acknowledge(in: &state, worktreeID: worktree.path, paneID: nil, occurrence: old.occurrence))
        #expect(state.repos[0].worktrees[0].unseenAgentStop == newer)
        #expect(SidebarHostNavigation.acknowledge(in: &state, worktreeID: worktree.path, paneID: nil, occurrence: newer.occurrence))
        #expect(state.repos[0].worktrees[0].unseenAgentStop == nil)
        #expect(state.repos[0].worktrees[0].attention?.text == "Review this")
    }

    @Test("@spec REMOTE-14.6: When folder metadata is published, the application shall retain native virtual-folder labels and identities, including separate folders with the same display name.")
    func folderMetadataPreservesNativeHierarchy() throws {
        let root = "/projects/repo"
        let managed = ["a", "b"].map { WorktreeEntry(path: root + "/.worktrees/worktrees/" + $0, branch: $0) }
        let external = ["c", "d"].map { WorktreeEntry(path: "/tmp/external/worktrees/" + $0, branch: $0) }
        let nodes = SidebarWorktreeHierarchy.nodes(for: managed + external, inRepoAtPath: root, defaultBranch: nil)
        let ancestry = SidebarWorktreeHierarchy.folderAncestry(in: nodes)
        let first = try #require(ancestry[managed[0].id])
        let second = try #require(ancestry[external[0].id])
        #expect(first.map(\.name) == ["worktrees"])
        #expect(second.map(\.name) == ["worktrees"])
        #expect(first.map(\.id) != second.map(\.id))
        let rows = (managed + external).map { worktree in
            let folders = ancestry[worktree.id] ?? []
            return WorktreePanes(path: worktree.path, displayName: worktree.branch, repoDisplayName: "Project", displayBranch: worktree.branch, state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: SidebarHostNavigation.metadata(for: worktree, projectID: "p", folders: folders.map(\.name), folderIDs: folders.map(\.id)))
        }
        let projected = SidebarWorktreeTree.nodes(rows)
        #expect(projected.map(\.name) == ["worktrees", "worktrees"])
        #expect(Set(projected.map(\.id)).count == 2)
        #expect(projected[0].children?.compactMap { $0.worktree?.path } == managed.map(\.path))
        #expect(projected[1].children?.compactMap { $0.worktree?.path } == external.map(\.path))
    }

    @Test("@spec PROJECT-3.3: When an icon file is read, the application shall reject nonregular files and read no more than the supported image byte limit.")
    func boundedRegularIconRead() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent("icon.png")
        let bytes = Data("small regular file".utf8)
        try bytes.write(to: regular)
        #expect(ProjectIconDiscovery.readImageData(at: regular) == bytes)
        let link = directory.appendingPathComponent("favicon.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(ProjectIconDiscovery.readImageData(at: link) == nil)
        let fifo = directory.appendingPathComponent("favicon.ico")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ProjectIconDiscovery.readImageData(at: fifo) == nil)
        #expect(ProjectIconDiscovery.readImageData(at: directory) == nil)
        try Data(repeating: 0, count: 2 * 1024 * 1024 + 1).write(to: regular)
        #expect(ProjectIconDiscovery.readImageData(at: regular) == nil)
        #expect(ProjectIconDiscovery.discover(at: directory) == nil)
    }

    @Test("@spec LAYOUT-2.42: When a user reorders worktrees, the application shall preserve the default-branch checkout first among pinned agents, stale temporary worktrees last within their list, and virtual-folder and pinned-section boundaries while moving only eligible siblings.")
    func worktreeMove() {
        let root = "/tmp/project"
        let main = WorktreeEntry(path: root, branch: "main", state: .closed)
        let a = WorktreeEntry(path: root + "/.worktrees/a", branch: "a", state: .closed)
        let b = WorktreeEntry(path: root + "/.worktrees/b", branch: "b", state: .closed)
        var state = AppState(repos: [RepoEntry(path: root, displayName: "project", worktrees: [main, a, b])])
        let moved = SidebarHostNavigation.moveWorktree(in: &state, repositoryID: root, worktreeID: b.path, relativeTo: a.path, after: false)
        #expect(moved)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
        let beforeMain = SidebarHostNavigation.moveWorktree(in: &state, repositoryID: root, worktreeID: b.path, relativeTo: main.path, after: false)
        #expect(!beforeMain)
        let stale = WorktreeEntry(path: root + "/gone", branch: "gone", state: .stale)
        let oldOrder = RepoEntry(path: root, displayName: "Project", worktrees: [stale, b, main, a])
        #expect(SidebarHostNavigation.canonicalWorktrees(in: oldOrder).map(\.branch) == ["b", "a", "gone", "main"])
    }

    @Test("@spec LAYOUT-2.95: While a repository's worktree order is set to recent activity, the application shall continuously order its temporary worktrees by their latest attention, agent progress, or stop time with the newest first, keep stale temporary worktrees last, place the default-branch checkout first among Pinned Agents below them, preserve manual pinned order, and decode older state without the setting as manual order.")
    func recentActivityOrdering() throws {
        let root = "/tmp/project"
        let main = WorktreeEntry(path: root, branch: "main")
        var quiet = WorktreeEntry(path: root + "/.worktrees/quiet", branch: "quiet")
        var stopped = WorktreeEntry(path: root + "/.worktrees/stopped", branch: "stopped")
        var progressing = WorktreeEntry(path: root + "/.worktrees/progressing", branch: "progressing")
        var pinged = WorktreeEntry(path: root + "/.worktrees/pinged", branch: "pinged")
        let stale = WorktreeEntry(path: root + "/gone", branch: "gone", state: .stale)
        stopped.unseenAgentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 300))
        progressing.agentProgressTimes = ["codex:one": Date(timeIntervalSince1970: 200).timeIntervalSinceReferenceDate]
        pinged.attention = Attention(text: "Done", timestamp: Date(timeIntervalSince1970: 100))
        #expect(quiet.lastActivity == nil)
        #expect(stopped.lastActivity == Date(timeIntervalSince1970: 300))
        #expect(progressing.lastActivity == Date(timeIntervalSince1970: 200))
        #expect(pinged.lastActivity == Date(timeIntervalSince1970: 100))
        var repo = RepoEntry(path: root, displayName: "project", worktrees: [stale, quiet, pinged, main, progressing, stopped])
        #expect(repo.worktreeOrderMode == .manual)
        #expect(SidebarHostNavigation.canonicalWorktrees(in: repo).map(\.branch) == ["quiet", "pinged", "progressing", "stopped", "gone", "main"])
        repo.worktreeOrderMode = .recentActivity
        #expect(SidebarHostNavigation.displayedWorktrees(in: repo).map(\.branch) == ["stopped", "progressing", "pinged", "quiet", "gone", "main"])
        // The persisted order is untouched by the display mode, so switching back to manual restores it.
        #expect(SidebarHostNavigation.canonicalWorktrees(in: repo).map(\.branch) == ["quiet", "pinged", "progressing", "stopped", "gone", "main"])
        // Reordering is manual-only, so a remote move must be refused rather than accepted and re-sorted away.
        var state = AppState(repos: [repo])
        #expect(!SidebarHostNavigation.moveWorktree(in: &state, repositoryID: root, worktreeID: progressing.path, relativeTo: stopped.path, after: false))
        quiet.paneAttention[PaneSlotID()] = Attention(text: "Finished", timestamp: Date(timeIntervalSince1970: 400))
        repo.worktrees = [stale, quiet, pinged, main, progressing, stopped]
        #expect(SidebarHostNavigation.displayedWorktrees(in: repo).map(\.branch) == ["quiet", "stopped", "progressing", "pinged", "gone", "main"])
        let encoded = try JSONEncoder().encode(repo)
        #expect(try JSONDecoder().decode(RepoEntry.self, from: encoded).worktreeOrderMode == .recentActivity)
        let legacy = """
        {"id": "11111111-1111-1111-1111-111111111111", "path": "/tmp/legacy", "displayName": "legacy", "worktrees": []}
        """
        #expect(try JSONDecoder().decode(RepoEntry.self, from: Data(legacy.utf8)).worktreeOrderMode == .manual)
    }

    @Test("@spec LAYOUT-2.97: When a user picks an emoji from the native macOS emoji palette for a worktree, the application shall apply it as a manual identity only when it is a single emoji not used by another worktree.")
    func manualEmojiEdit() {
        let root = "/tmp/project"
        var taken = WorktreeEntry(path: root + "/.worktrees/taken", branch: "taken")
        taken.emoji = "🚀"; taken.emojiSource = .agent
        let target = WorktreeEntry(path: root + "/.worktrees/target", branch: "target")
        var repos = [RepoEntry(path: root, displayName: "project", worktrees: [taken, target])]
        #expect(!SidebarHostNavigation.setManualEmoji("🚀", worktreeID: target.id, in: &repos))
        #expect(!SidebarHostNavigation.setManualEmoji("ab", worktreeID: target.id, in: &repos))
        #expect(!SidebarHostNavigation.setManualEmoji("", worktreeID: target.id, in: &repos))
        #expect(repos[0].worktrees[1].emoji == nil)
        #expect(SidebarHostNavigation.setManualEmoji(" 🧪 ", worktreeID: target.id, in: &repos))
        #expect(repos[0].worktrees[1].emoji == "🧪")
        #expect(repos[0].worktrees[1].emojiSource == .manual)
        #expect(SidebarHostNavigation.setManualEmoji("🧪", worktreeID: target.id, in: &repos))
        #expect(!SidebarHostNavigation.setManualEmoji("🧪", worktreeID: UUID(), in: &repos))
    }

    @Test("Clearing a worktree emoji drops both the emoji and its source")
    func clearEmoji() {
        var worktree = WorktreeEntry(path: "/tmp/project/.worktrees/one", branch: "one")
        worktree.emoji = "🧪"; worktree.emojiSource = .manual
        var repos = [RepoEntry(path: "/tmp/project", displayName: "project", worktrees: [worktree])]
        #expect(SidebarHostNavigation.clearEmoji(worktreeID: worktree.id, in: &repos))
        #expect(repos[0].worktrees[0].emoji == nil && repos[0].worktrees[0].emojiSource == nil)
        #expect(!SidebarHostNavigation.clearEmoji(worktreeID: UUID(), in: &repos))
    }

    @Test("Opening one occurrence preserves sibling requests and a newer request")
    func acknowledgeIsolation() {
        var wt = WorktreeEntry(path: "/project", branch: "main")
        let first = PaneSlotID(), second = PaneSlotID()
        let firstSession = wt.ensurePaneSession(for: first)
        _ = wt.ensurePaneSession(for: second)
        let old = Attention(text: "Review", timestamp: Date(timeIntervalSince1970: 1), source: .agentStop)
        let newer = Attention(text: "Review", timestamp: Date(timeIntervalSince1970: 2), source: .agentStop)
        wt.paneAttention[first] = newer
        wt.paneAttention[second] = old
        wt.attention = old
        var state = AppState(repos: [.init(path: "/project", displayName: "Project", worktrees: [wt])])
        let stale = SidebarHostNavigation.acknowledge(in: &state, worktreeID: wt.path, paneID: ZmxLauncher.sessionName(for: firstSession), occurrence: .init(timestamp: old.timestamp, text: old.text, source: old.source))
        #expect(!stale)
        let current = SidebarHostNavigation.acknowledge(in: &state, worktreeID: wt.path, paneID: ZmxLauncher.sessionName(for: firstSession), occurrence: .init(timestamp: newer.timestamp, text: newer.text, source: newer.source))
        #expect(current)
        #expect(state.repos[0].worktrees[0].paneAttention[first] == nil)
        #expect(state.repos[0].worktrees[0].paneAttention[second] == old)
        #expect(state.repos[0].worktrees[0].attention == old)
    }

    @Test("@spec PROJECT-3.1: When a project has no valid supported icon, the application shall fall back to stable initials without accepting malformed image data.")
    func invalidIcon() {
        #expect(ProjectIconDiscovery.thumbnail(Data("not an image".utf8)) == nil)
        let first = SidebarProject(id: "stable", repositoryID: "/old", name: "graftty-server")
        let second = SidebarProject(id: "stable", repositoryID: "/new", name: "graftty-server")
        #expect(first.displayInitials == "GS")
        #expect(first.colorIndex == second.colorIndex)
    }

    @Test("@spec PROJECT-3.2: When a project icon override or manual project order is saved, the application shall retain it across relaunches and decode older application state without those settings.")
    func persistence() throws {
        var repo = RepoEntry(path: "/project", displayName: "Project")
        repo.iconOverride = .initials("PR")
        var state = AppState(repos: [repo])
        state.sidebarNavigation = .init(order: .init(ids: ["a", "b"]))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AppState.self, from: data) == state)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sidebarNavigation")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppState.self, from: old).sidebarNavigation == nil)
    }
}
