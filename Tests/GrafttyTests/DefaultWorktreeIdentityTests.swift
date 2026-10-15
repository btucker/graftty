import AppKit
import GrafttyCommandUI
import Foundation
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct DefaultWorktreeIdentityTests {
    private func state() -> AppState {
        var home = WorktreeEntry(path: "/repo", branch: "release")
        home.emoji = "🐸"
        home.emojiSource = .manual
        home.unseenAgentStop = .init(agentName: "Codex", stoppedAt: Date(),
            recap: .init(title: "Review", completed: "Done", next: "Review"))
        var linked = WorktreeEntry(path: "/repo/linked", branch: "main")
        linked.emoji = "🚀"
        linked.emojiSource = .agent
        linked.unseenAgentStop = home.unseenAgentStop
        var repo = RepoEntry(path: "/repo", displayName: "Project", worktrees: [home, linked])
        repo.iconOverride = .initials("PR")
        return AppState(repos: [repo])
    }

    @Test("@spec LAYOUT-2.124: While a repository's home checkout identity is displayed or serialized, the application shall use its current project icon and project fallback instead of any stored worktree emoji, including after restoration, while retaining linked worktree identities.")
    func publishedIdentityIgnoresStoredHomeEmoji() async throws {
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state()))
        let owner = WorktreeOrigin(deviceID: RemoteDeviceID(value: "test"), deviceLabel: "Test", relayDepth: 0)
        let worktrees = sidebarLocalWorktrees(state: restored, owner: owner, titles: [:], liveness: [:])
        #expect(worktrees[0].sidebar?.emoji == nil)
        #expect(worktrees[1].sidebar?.emoji == "🚀")
        let activity = SidebarProjection.activity(worktrees)
        #expect(activity.first { $0.worktreeID == "/repo" }?.worktreeEmoji == nil)
        #expect(activity.first { $0.worktreeID == "/repo/linked" }?.worktreeEmoji == "🚀")
        let home = try #require(activity.first { $0.worktreeID == "/repo" })
        #expect(home.iconIdentity == .project)
        #expect(worktrees[0].iconIdentity == .project)
        #expect(worktrees[1].iconIdentity == .emoji("🚀"))
        let decoded = try JSONDecoder().decode([WorktreePanes].self, from: JSONEncoder().encode(worktrees))
        #expect(decoded[0].iconIdentity == .project)
        #expect(decoded[1].effectiveEmoji == "🚀")
        let card = try JSONDecoder().decode(SidebarActivityItem.self, from: JSONEncoder().encode(home))
        #expect(card.iconIdentity == .project)

        var workspace = SidebarAttentionWorkspace()
        workspace.merge([home])
        var history = SidebarRecentHistory()
        history.open(home)
        var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktrees[0])) as? [String: Any])
        var metadata = try #require(wire["sidebar"] as? [String: Any])
        metadata["emoji"] = "🐸"
        wire["sidebar"] = metadata
        let legacySnapshot = try JSONDecoder().decode(WorktreePanes.self, from: JSONSerialization.data(withJSONObject: wire))
        workspace.reconcile(worktrees: [legacySnapshot])
        history.reconcile(worktrees: [legacySnapshot], availableProjectIDs: [])
        #expect(workspace.items.first?.iconIdentity == .project)
        #expect(history.entries.first?.item.iconIdentity == .project)

        var repo = restored.repos[0]
        let store = SidebarHostController()
        store.refreshIcons([repo])
        let before = store.project(for: repo, owner: owner)
        repo.iconOverride = .initials("NEW")
        store.refreshIcons([repo])
        let after = store.project(for: repo, owner: owner)
        #expect(before.displayInitials == "PR")
        #expect(after.displayInitials == "NEW")
        #expect(render(WorktreeIdentityView(identity: card.iconIdentity, project: before))
            != render(WorktreeIdentityView(identity: card.iconIdentity, project: after)))
        repo.iconOverride = .image(png(.red))
        store.refreshIcons([repo])
        #expect(store.icons[repo.id.uuidString] != nil)
        let imageProject = store.project(for: repo, owner: owner)
        #expect(imageProject.iconRevision != nil)
        repo.iconOverride = .initials("PR")
        store.refreshIcons([repo])
        #expect(store.icons[repo.id.uuidString] == nil)
        #expect(store.project(for: repo, owner: owner).iconRevision == nil)

        // A stale discovery completion must not replace a newly selected icon.
        repo.iconOverride = nil
        store.refreshIcons([repo], force: true)
        repo.iconOverride = .image(png(.blue))
        store.refreshIcons([repo], force: true)
        let selected = store.icons[repo.id.uuidString]
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.icons[repo.id.uuidString] == selected)
    }

    @Test("@spec NOTIF-1.9: When a native Attention notification represents the home checkout, the application shall use the current project icon and fallback instead of its stored worktree emoji while preserving linked worktree identities and notification activation routes.")
    func nativeNotificationIgnoresStoredHomeEmoji() async throws {
        var state = state()
        let binding = Binding<AppState>(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-default-icon-test.sock")
        var notifications: [AgentStopNotificationContent] = []
        GrafttyApp.recordStoppedTurn(callerPath: "/repo", runtime: .codex, callerAgentID: "agent",
            sessionID: "session", paneSessionName: nil,
            recap: .init(title: "Review", completed: "Done", next: "Review", emoji: "🧩"),
            stoppedAt: Date().addingTimeInterval(1), appState: binding, terminalManager: manager,
            postNotification: { notifications.append($0) })
        #expect(notifications.count == 1)
        #expect(notifications.first?.subtitle?.contains("🐸") == false)
        let first = try #require(notifications.first)
        #expect(first.identityImage != nil)
        let prepared = AgentNotificationRouter.prepareRequest(for: first)
        let request = prepared.request
        defer { if let source = prepared.sourceURL { try? FileManager.default.removeItem(at: source) } }
        #expect(request.content.attachments.count == 1)
        #expect(request.content.attachments.first?.identifier == "project-icon")
        let userInfo = try #require(request.content.userInfo as? [String: Any])
        #expect(try AgentStopNotification.payload(from: userInfo).worktreePath == "/repo")
        #expect(request.content.subtitle == "release")

        state.repos[0].iconOverride = .initials("NEW")
        var updated = first
        ProjectNotificationIdentity.apply(to: &updated, worktree: state.repos[0].worktrees[0], repo: state.repos[0])
        #expect(updated.identityImage != first.identityImage)
        let afterAuthorization = await ProjectNotificationIdentity.resolved(first, currentRepo: { state.repos[0] })
        let authorizedImage = try #require(afterAuthorization.identityImage.flatMap(NSBitmapImageRep.init(data:)))
        let currentImage = try #require(updated.identityImage.flatMap(NSBitmapImageRep.init(data:)))
        #expect(authorizedImage.pixelsWide == currentImage.pixelsWide)
        let byteCount = authorizedImage.bytesPerRow * authorizedImage.pixelsHigh
        #expect(Data(bytes: try #require(authorizedImage.bitmapData), count: byteCount)
            == Data(bytes: try #require(currentImage.bitmapData), count: byteCount))
        #expect(ProjectNotificationIdentity.image(for: state.repos[0].worktrees[1], in: state.repos[0]) == nil)

        // Discovery works for native content before any sidebar has loaded the project.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png(.green).write(to: directory.appendingPathComponent("favicon.png"))
        let worktree = WorktreeEntry(path: directory.path, branch: "develop")
        let repo = RepoEntry(path: directory.path, displayName: "Discovered", worktrees: [worktree])
        var discovered = first
        ProjectNotificationIdentity.apply(to: &discovered, worktree: worktree, repo: repo)
        let resolved = await ProjectNotificationIdentity.resolved(discovered)
        #expect(resolved.identityImage != discovered.identityImage)
        #expect(resolved.identityImage != nil)
    }

    @Test func sharedRemoteCacheRejectsOlderReplies() async {
        let store = SidebarHostController()
        let oldData = png(.red)
        let newData = png(.blue)
        let oldProject = SidebarProject(id: "remote-project", repositoryID: "route", name: "Project",
            iconRevision: ProjectIconDiscovery.revision(oldData))
        var newProject = oldProject
        newProject.iconRevision = ProjectIconDiscovery.revision(newData)
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        store.remoteIconCache.reconcile([oldProject])
        let older = Task {
            await store.remoteIconCache.load(for: oldProject) {
                started.continuation.yield()
                _ = await resume.stream.first { _ in true }
                return nil
            }
        }
        _ = await started.stream.first { _ in true }
        store.remoteIconCache.reconcile([newProject])
        await store.remoteIconCache.load(for: newProject) { newData }
        resume.continuation.yield()
        await older.value
        #expect(store.remoteIcons[oldProject.id] == newData)
        var unnecessaryFetch = false
        await store.remoteIconCache.load(for: newProject) { unnecessaryFetch = true; return nil }
        #expect(!unnecessaryFetch)
        store.remoteIconCache.reconcile([SidebarProject(id: oldProject.id, repositoryID: "route", name: "Project")])
        #expect(store.remoteIcons[oldProject.id] == nil)
    }

    private func render<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        return renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    private func png(_ color: Color) -> Data {
        render(Rectangle().fill(color).frame(width: 32, height: 32))!
    }
}
