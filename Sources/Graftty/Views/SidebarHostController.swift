import AppKit
import Combine
import Foundation
import SwiftUI
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
    private struct IconMetadata {
        let data: Data
        let revision: String
        let accentHex: String?
    }
    private var iconMetadata: [UUID: IconMetadata] = [:]
    private let resolveAccent: (Data) -> String?

    init(resolveAccent: @escaping (Data) -> String? = ProjectIconDiscovery.accentHex) {
        self.resolveAccent = resolveAccent
    }

    private var checked: [UUID: Date] = [:]
    private struct IconSignature: Equatable { var path: String; var iconOverride: ProjectIconOverride? }
    private var signatures: [UUID: IconSignature] = [:]
    private var loading: [UUID: (signature: IconSignature, token: UUID)] = [:]

    func refreshIcons(_ repos: [RepoEntry], force: Bool = false) {
        let ids = Set(repos.map(\.id))
        iconMetadata = iconMetadata.filter { ids.contains($0.key) }
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
        let metadata: IconMetadata?
        if let data {
            if let cached = iconMetadata[repo.id], cached.data == data { metadata = cached }
            else {
                let resolved = IconMetadata(data: data, revision: ProjectIconDiscovery.revision(data),
                                            accentHex: resolveAccent(data))
                iconMetadata[repo.id] = resolved
                metadata = resolved
            }
        } else {
            iconMetadata[repo.id] = nil
            metadata = nil
        }
        let initials: String?
        if case .initials(let value) = repo.iconOverride { initials = value } else { initials = nil }
        return SidebarProject(id: "\(owner.deviceID.value):\(repo.id.uuidString)", repositoryID: repo.path,
            name: repo.displayName, owner: owner, iconRevision: metadata?.revision,
            initials: initials, accentHex: metadata?.accentHex, supportsWorktreeEditing: repo.isGitTracked, worktreeOrderMode: repo.isGitTracked ? repo.worktreeOrderMode : nil)
    }

    /// Inout access to a SwiftUI binding writes back even when the snapshot
    /// didn't mutate its value. Poll using a copy and publish actual changes.
    func snapshot(state: Binding<AppState>, owner: WorktreeOrigin, remote: [SidebarProject],
                  authoritativeRemoteOwners: Set<RemoteDeviceID> = [],
                  savedRemoteOwners: Set<RemoteDeviceID>? = nil) -> SidebarSnapshot {
        let previous = state.wrappedValue
        var next = previous
        let result = snapshot(state: &next, owner: owner, remote: remote,
            authoritativeRemoteOwners: authoritativeRemoteOwners, savedRemoteOwners: savedRemoteOwners)
        if next != previous { state.wrappedValue = next }
        return result
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

/// Uses the same `WorktreePanes(entry:repo:inputs:)` projection as the published snapshot.
@MainActor
func sidebarLocalWorktrees(state: AppState, owner: WorktreeOrigin,
                          titles: [PaneSlotID: String], liveness: [String: AgentLiveness], prBadges: [String: PRBadge] = [:],
                          defaultBranch: (RepoEntry) -> String? = { $0.defaultBranchHint }) -> [WorktreePanes] {
    state.repos.flatMap { repo in
        let ancestry = SidebarHostNavigation.folderAncestry(in: repo)
        let labels = SidebarWorktreeLabel.texts(for: repo.worktrees, inRepoAtPath: repo.path,
                                               defaultBranch: defaultBranch(repo))
        return SidebarHostNavigation.displayedWorktrees(in: repo).map { wt in
            sidebarLocalWorktree(wt, repo: repo, owner: owner, displayName: labels[wt.id] ?? "",
                                 titles: titles, liveness: liveness, prBadge: prBadges[wt.path], folders: ancestry[wt.id])
        }
    }
}

/// Build one row without projecting every sibling on each row render.
/// Stats stay nil (the sidebar reads `WorktreeStatsStore` directly), and
/// stopped worktrees keep their saved layout, unlike published snapshots.
@MainActor
func sidebarLocalWorktree(_ wt: WorktreeEntry, repo: RepoEntry, owner: WorktreeOrigin,
                          displayName: String, titles: [PaneSlotID: String], liveness: [String: AgentLiveness],
                          prBadge: PRBadge?, folders: [SidebarWorktreeHierarchy.Folder]? = nil, ports: [WorktreePort] = []) -> WorktreePanes {
    WorktreePanes(entry: wt, repo: repo, inputs: WorktreeRowInputs(
        origin: owner, projectID: "\(owner.deviceID.value):\(repo.id.uuidString)", displayName: displayName,
        folders: folders, prBadge: prBadge, paneTitles: titles, liveness: liveness,
        includeLayoutWhenStopped: true, ports: ports))
}
