import AppKit
import Combine
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

@MainActor
final class SidebarHostController: ObservableObject {
    static let shared = SidebarHostController()
    let owner = WorktreeOrigin(deviceID: AppServices.localRemoteDeviceID(), deviceLabel: AppServices.localHostDisplayName(), relayDepth: 0)
    @Published private(set) var icons: [String: Data] = [:]
    let remoteIconCache = ProjectIconCache()
    var remoteIcons: [String: Data] { remoteIconCache.icons }
    private var resolvedSignatures: [UUID: IconSignature] = [:]
    private var checked: [UUID: Date] = [:]
    private struct IconSignature: Equatable { var path: String; var iconOverride: ProjectIconOverride? }
    private var signatures: [UUID: IconSignature] = [:]
    private var loading: [UUID: (signature: IconSignature, token: UUID)] = [:]

    func refreshIcons(_ repos: [RepoEntry], force: Bool = false) {
        for repo in repos {
            let signature = IconSignature(path: repo.path, iconOverride: repo.iconOverride)
            let previous = signatures[repo.id]
            guard force || previous != signature
                || Date().timeIntervalSince(checked[repo.id] ?? .distantPast) > 30 else { continue }
            signatures[repo.id] = signature
            if previous != signature { loading[repo.id] = nil }
            let key = repo.id.uuidString
            switch repo.iconOverride {
            case .initials:
                icons[key] = nil
                checked[repo.id] = Date()
                resolvedSignatures[repo.id] = signature
            case .image(let data):
                let image = ProjectIconDiscovery.thumbnail(data)
                if icons[key] != image { icons[key] = image }
                checked[repo.id] = Date()
                resolvedSignatures[repo.id] = signature
            case nil:
                if previous != signature { icons[key] = nil }
                guard loading[repo.id]?.signature != signature else { continue }
                let token = UUID()
                loading[repo.id] = (signature, token)
                Task {
                    let image = await Task.detached(priority: .utility) {
                        ProjectIconDiscovery.discover(at: URL(fileURLWithPath: repo.path))
                    }.value
                    guard loading[repo.id]?.token == token, signatures[repo.id] == signature else { return }
                    loading[repo.id] = nil
                    if icons[key] != image { icons[key] = image }
                    checked[repo.id] = Date()
                    resolvedSignatures[repo.id] = signature
                }
            }
        }
    }

    func localProjects(_ repos: [RepoEntry], owner: WorktreeOrigin) -> [SidebarProject] {
        refreshIcons(repos)
        return repos.map { project(for: $0, owner: owner) }
    }

    func hasResolvedIcon(for repo: RepoEntry) -> Bool {
        resolvedSignatures[repo.id] == IconSignature(path: repo.path, iconOverride: repo.iconOverride)
    }

    func iconData(for repo: RepoEntry) -> Data? {
        let signature = IconSignature(path: repo.path, iconOverride: repo.iconOverride)
        if signatures[repo.id] == signature { return icons[repo.id.uuidString] }
        if case .image(let data) = repo.iconOverride { return ProjectIconDiscovery.thumbnail(data) }
        return nil
    }

    func project(for repo: RepoEntry, owner: WorktreeOrigin) -> SidebarProject {
        let data = iconData(for: repo)
        let initials: String?
        if case .initials(let value) = repo.iconOverride { initials = value } else { initials = nil }
        return SidebarProject(id: "\(owner.deviceID.value):\(repo.id.uuidString)", repositoryID: repo.path,
            name: repo.displayName, owner: owner, iconRevision: data.map(ProjectIconDiscovery.revision),
            initials: initials, accentHex: data.flatMap(ProjectIconDiscovery.accentHex), supportsWorktreeEditing: true)
    }

    func snapshot(state: inout AppState, owner: WorktreeOrigin, remote: [SidebarProject], authoritativeRemoteOwners: Set<RemoteDeviceID> = [], savedRemoteOwners: Set<RemoteDeviceID>? = nil) -> SidebarSnapshot {
        for index in state.repos.indices {
            let ordered = SidebarHostNavigation.canonicalWorktrees(in: state.repos[index])
            if state.repos[index].worktrees != ordered { state.repos[index].worktrees = ordered }
        }
        SidebarHostNavigation.migrateLegacyEmojis(in: &state.repos)
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
                          titles: [PaneSlotID: String], liveness: [String: AgentLiveness], prBadges: [String: PRBadge] = [:],
                          defaultBranch: (RepoEntry) -> String? = { $0.defaultBranchHint }) -> [WorktreePanes] {
    state.repos.flatMap { repo in
        let projectID = "\(owner.deviceID.value):\(repo.id.uuidString)"
        let ancestry = SidebarHostNavigation.folderAncestry(in: repo)
        let labels = SidebarWorktreeLabel.texts(for: repo.worktrees, inRepoAtPath: repo.path,
                                               defaultBranch: defaultBranch(repo))
        return repo.worktrees.map { wt in
            WorktreePanes(path: wt.path, displayName: labels[wt.id] ?? "", repoDisplayName: repo.displayName,
                          repositoryID: repo.path, displayBranch: wt.displayBranch, state: WorktreeWireState(wt.state),
                          isMainCheckout: wt.path == repo.path, prBadge: prBadges[wt.path], stats: nil,
                          attentionText: wt.attention?.text, attentionSource: wt.attention?.source,
                          attentionTimestamp: wt.attention?.timestamp,
                          layout: wt.splitTree.root.map { paneLayoutNode(from: $0, paneSessions: wt.paneSessions, titles: titles, paneAttention: wt.paneAttention, liveness: liveness) },
                          origin: owner, sidebar: SidebarHostNavigation.metadata(for: wt, projectID: projectID,
                            folders: ancestry[wt.id]?.map(\.name) ?? [], repositoryPath: repo.path, folderIDs: ancestry[wt.id]?.map(\.id)))
        }
    }
}
