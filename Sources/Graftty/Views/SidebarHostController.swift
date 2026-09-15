import AppKit
import Combine
import Foundation
import GrafttyKit
import GrafttyProtocol

@MainActor
final class SidebarHostController: ObservableObject {
    static let shared = SidebarHostController()
    let owner = WorktreeOrigin(deviceID: AppServices.localRemoteDeviceID(), deviceLabel: AppServices.localHostDisplayName(), relayDepth: 0)
    @Published private(set) var icons: [String: Data] = [:]
    private var checked: [UUID: Date] = [:]
    private struct IconSignature: Equatable { var path: String; var iconOverride: ProjectIconOverride? }
    private var signatures: [UUID: IconSignature] = [:]
    private var loading: Set<UUID> = []

    func refreshIcons(_ repos: [RepoEntry], force: Bool = false) {
        for repo in repos {
            let previous = signatures[repo.id]
            guard !loading.contains(repo.id), force || previous?.path != repo.path
                || previous?.iconOverride != repo.iconOverride
                || Date().timeIntervalSince(checked[repo.id] ?? .distantPast) > 30 else { continue }
            loading.insert(repo.id)
            signatures[repo.id] = .init(path: repo.path, iconOverride: repo.iconOverride)
            Task {
                let image = await Task.detached(priority: .utility) {
                    switch repo.iconOverride {
                    case .initials: return Optional<Data>.none
                    case .image(let data): return ProjectIconDiscovery.thumbnail(data)
                    case nil: return ProjectIconDiscovery.discover(at: URL(fileURLWithPath: repo.path))
                    }
                }.value
                let key = repo.id.uuidString
                if icons[key] != image { icons[key] = image }
                checked[repo.id] = Date()
                loading.remove(repo.id)
            }
        }
    }

    func localProjects(_ repos: [RepoEntry], owner: WorktreeOrigin) -> [SidebarProject] {
        refreshIcons(repos)
        return repos.map { repo in
            let initials: String?
            if case .initials(let value) = repo.iconOverride { initials = value } else { initials = nil }
            return SidebarProject(id: "\(owner.deviceID.value):\(repo.id.uuidString)", repositoryID: repo.path,
                                  name: repo.displayName, owner: owner,
                                  iconRevision: icons[repo.id.uuidString].map(ProjectIconDiscovery.revision), initials: initials, supportsWorktreeEditing: true)
        }
    }

    func snapshot(state: inout AppState, owner: WorktreeOrigin, remote: [SidebarProject], authoritativeRemoteOwners: Set<RemoteDeviceID> = [], savedRemoteOwners: Set<RemoteDeviceID>? = nil) -> SidebarSnapshot {
        for index in state.repos.indices {
            let ordered = SidebarHostNavigation.canonicalWorktrees(in: state.repos[index])
            if state.repos[index].worktrees != ordered { state.repos[index].worktrees = ordered }
        }
        var navigation = state.sidebarNavigation ?? .init()
        let local = localProjects(state.repos, owner: owner)
        let localIDs = Set(local.map(\.id))
        let remoteIDs = Set(remote.map(\.id))
        navigation.cachedProjects.removeAll { project in
            guard let device = project.owner?.deviceID else { return false }
            if device == owner.deviceID { return !localIDs.contains(project.id) }
            if let savedRemoteOwners, !savedRemoteOwners.contains(device) { return true }
            return authoritativeRemoteOwners.contains(device) && !remoteIDs.contains(project.id)
        }
        let knownIDs = Set(navigation.cachedProjects.map(\.id) + local.map(\.id) + remote.map(\.id))
        navigation.order.ids.removeAll { !knownIDs.contains($0) }
        let projects = navigation.reconcile(local + remote)
        if state.sidebarNavigation != navigation { state.sidebarNavigation = navigation }
        return .init(projects: projects)
    }

    func chooseIcon(for repoID: UUID, state: inout AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .ico, .icns]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = ProjectIconDiscovery.readImageData(at: url), let png = ProjectIconDiscovery.thumbnail(data),
              let index = state.repos.firstIndex(where: { $0.id == repoID }) else { return }
        state.repos[index].iconOverride = .image(png)
        refreshIcons(state.repos, force: true)
    }
}

/// Uses the same pane conversion as the published snapshot, including liveness.
@MainActor
func sidebarLocalWorktrees(state: AppState, owner: WorktreeOrigin,
                          titles: [PaneSlotID: String], liveness: [String: AgentLiveness], prBadges: [String: PRBadge] = [:]) -> [WorktreePanes] {
    state.repos.flatMap { repo in
        let projectID = "\(owner.deviceID.value):\(repo.id.uuidString)"
        let nodes = SidebarWorktreeHierarchy.nodes(for: repo.worktrees, inRepoAtPath: repo.path, defaultBranch: nil)
        let ancestry = SidebarWorktreeHierarchy.folderAncestry(in: nodes)
        return repo.worktrees.map { wt in
            WorktreePanes(path: wt.path, displayName: wt.branch, repoDisplayName: repo.displayName,
                          repositoryID: repo.path, displayBranch: wt.displayBranch, state: WorktreeWireState(wt.state),
                          isMainCheckout: wt.path == repo.path, prBadge: prBadges[wt.path], stats: nil,
                          attentionText: wt.attention?.text, attentionSource: wt.attention?.source,
                          attentionTimestamp: wt.attention?.timestamp,
                          layout: wt.splitTree.root.map { paneLayoutNode(from: $0, paneSessions: wt.paneSessions, titles: titles, paneAttention: wt.paneAttention, liveness: liveness) },
                          origin: owner, sidebar: SidebarHostNavigation.metadata(for: wt, projectID: projectID,
                            folders: ancestry[wt.id]?.map(\.name) ?? [], folderIDs: ancestry[wt.id]?.map(\.id)))
        }
    }
}
