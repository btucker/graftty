import AppKit
import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

@MainActor
enum ProjectNotificationIdentity {
    static func apply(to notification: inout AgentStopNotificationContent, worktree: WorktreeEntry, repo: RepoEntry) {
        notification.identityProject = nil
        notification.identityProjectPath = nil
        notification.identityImage = image(for: worktree, in: repo)
        guard worktree.iconIdentity(in: repo) == .project else { return }
        let store = SidebarHostController.shared
        if repo.iconOverride == nil, !store.hasResolvedIcon(for: repo) {
            notification.identityProject = store.project(for: repo, owner: store.owner)
            notification.identityProjectPath = repo.path
        }
    }

    static func resolved(_ notification: AgentStopNotificationContent,
                         currentRepo: (() -> RepoEntry?)? = nil) async -> AgentStopNotificationContent {
        var result = notification
        if let repo = currentRepo?(),
           let worktree = repo.worktrees.first(where: { $0.path == notification.userInfo["worktree_path"] }) {
            apply(to: &result, worktree: worktree, repo: repo)
        }
        guard let path = result.identityProjectPath, let project = result.identityProject else { return result }
        let data = await Task.detached(priority: .utility) {
            ProjectIconDiscovery.discover(at: URL(fileURLWithPath: path))
        }.value
        if let repo = currentRepo?(),
           let worktree = repo.worktrees.first(where: { $0.path == notification.userInfo["worktree_path"] }) {
            apply(to: &result, worktree: worktree, repo: repo)
            guard repo.path == path, result.identityProjectPath != nil else { return result }
            result.identityImage = image(project: SidebarHostController.shared.project(for: repo,
                owner: SidebarHostController.shared.owner), data: data)
        } else {
            result.identityImage = image(project: project, data: data)
        }
        return result
    }

    static func image(for worktree: WorktreeEntry, in repo: RepoEntry) -> Data? {
        guard worktree.iconIdentity(in: repo) == .project else { return nil }
        let store = SidebarHostController.shared
        let project = store.project(for: repo, owner: store.owner)
        return image(project: project, data: store.iconData(for: repo))
    }

    static func image(project: SidebarProject, data: Data?) -> Data? {
        let renderer = ImageRenderer(content: ProjectIdentityView(project: project, imageData: data, size: 64))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
