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
    private var originKeysChecked: [String: Date] = [:]
    /// Origins whose project lives on more than one host right now.
    @Published var multiHostOriginKeys: Set<String> = []
    /// The process-wide origin of local projects (also `GrafttyApp`'s
    /// `localWorktreeOrigin`). It must exist synchronously, so it is the one
    /// caller that still falls back to a non-persisted ID; remote identity
    /// (pairing, signaling, Bonjour) surfaces store errors instead (REMOTE-1.14).
    let owner = WorktreeOrigin(
        deviceID: SidebarHostController.ownerDeviceIDWithNonPersistedFallback(),
        deviceLabel: AppServices.localHostDisplayName(),
        relayDepth: 0
    )

    private static func ownerDeviceIDWithNonPersistedFallback() -> RemoteDeviceID {
        do {
            return try AppServices.localRemoteDeviceID()
        } catch {
            NSLog(
                "[Graftty] local project origin is using a non-persisted device ID because the host device-ID store failed: %@",
                String(describing: error)
            )
            return RemoteDeviceID.generate()
        }
    }
    @Published private(set) var icons: [String: Data] = [:] {
        didSet {
            // Drawing colors avoid the project icon's hue (LAYOUT-2.199).
            for key in Set(icons.keys).union(oldValue.keys) where icons[key] != oldValue[key] {
                guard let id = UUID(uuidString: key) else { continue }
                ProjectHueRegistry.shared.set(icons[key].flatMap(WorktreeDrawingRenderer.dominantHue(ofImage:)), for: id)
            }
        }
    }
    /// Rendered worktree drawings by revision. A render takes milliseconds, so
    /// it runs off the main actor and rows show the emoji until it lands.
    @Published private(set) var drawings: [String: Data] = [:]
    private var requestedDrawings = Set<String>()

    func drawingData(for worktree: WorktreeEntry) -> Data? {
        guard let drawing = worktree.drawing, let hue = worktree.drawingHue else { return nil }
        if let data = drawings[drawing.revision] { return data }
        // A failed render stays requested, so view updates do not retry it.
        guard requestedDrawings.insert(drawing.revision).inserted else { return nil }
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                WorktreeDrawingRenderer.png(for: drawing, hue: hue)
            }.value
            if let data { drawings[drawing.revision] = data }
        }
        return nil
    }

    let remoteIconCache = ProjectIconCache()
    var remoteIcons: [String: Data] { remoteIconCache.icons }
    let remoteDrawingCache = WorktreeDrawingCache()

    func remoteDrawingData(for worktree: WorktreePanes) -> Data? {
        guard case .drawing(let revision, _) = worktree.iconIdentity else { return nil }
        return remoteDrawingCache.images[revision]
    }

    /// Call with live, relay-promoted rows so requests use the delivering host's route.
    func loadRemoteDrawings(_ worktrees: [WorktreePanes],
                            send: (WorktreeManagementRequest) async -> WorktreeManagementResponse?) async {
        for worktree in worktrees {
            guard case .drawing(let revision, _) = worktree.iconIdentity else { continue }
            await remoteDrawingCache.load(revision: revision) {
                if case .icon(let data) = await send(.worktreeIcon(worktreeID: worktree.path, revision: revision)) {
                    return data
                }
                return nil
            }
        }
    }

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
                // Writing nil over nil still publishes, which would rebuild the
                // sidebar on every 30 s recheck (PERF-1.20).
                if icons[key] != nil { icons[key] = nil }
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
            initials: initials, accentHex: metadata?.accentHex, supportsWorktreeEditing: repo.isGitTracked, worktreeOrderMode: repo.isGitTracked ? repo.worktreeOrderMode : nil,
            originKey: repo.originKey, rank: repo.projectRank, rankChangedAt: repo.projectRankChangedAt)
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
        let savedOrder = Dictionary(navigation.order.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let projectOrder = state.repos.enumerated().sorted {
            let left = savedOrder["\(owner.deviceID.value):\($0.element.id.uuidString)"] ?? .max
            let right = savedOrder["\(owner.deviceID.value):\($1.element.id.uuidString)"] ?? .max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element.id)
        SidebarHostNavigation.seedRanks(in: &state.repos, projectOrder: projectOrder)
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

    /// An origin rarely changes, so look again every few minutes, and at once
    /// for a repository this host hasn't checked yet.
    func refreshOriginKeys(state: Binding<AppState>, loader: GitRepositoryOrigin.Loader = { try await GitRepositoryOrigin.detect(repoPath: $0) }) async {
        let now = Date()
        let due = state.wrappedValue.repos.filter { repo in
            repo.isGitTracked && now.timeIntervalSince(originKeysChecked[repo.path] ?? .distantPast) > 300
        }.map(\.path)
        guard !due.isEmpty else { return }
        for path in due { originKeysChecked[path] = now }
        var keys: [String: String] = [:]
        for path in due {
            if let origin = try? await loader(path) { keys[path] = origin.identityKey }
        }
        var repos = state.wrappedValue.repos
        SidebarHostNavigation.applyOriginKeys(keys, in: &repos)
        if repos != state.wrappedValue.repos { state.wrappedValue.repos = repos }
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

/// Only structural presentation data. Live entries and row contexts are never retained here.
struct SidebarLocalWorktreeMetadata {
    let ancestry: [UUID: [SidebarWorktreeHierarchy.Folder]]
    let labels: [UUID: String]

    init(repo: RepoEntry, defaultBranch: String?) {
        ancestry = SidebarHostNavigation.folderAncestry(in: repo)
        labels = SidebarWorktreeLabel.texts(for: repo.worktrees, inRepoAtPath: repo.path,
                                          defaultBranch: defaultBranch)
    }
}

@MainActor
final class SidebarLocalWorktreeMetadataCache {
    // Keep this key aligned with folderAncestry and SidebarWorktreeLabel.texts.
    // Branch is needed for the label fallback on an empty/root path. Rank,
    // activity, state, titles, and reports affect live rows, not this metadata.
    private struct WorktreeKey: Equatable {
        let id: UUID
        let path: String
        let branch: String
        let isPinned: Bool
    }
    private struct Key: Equatable {
        let path: String
        let defaultBranch: String?
        let worktrees: [WorktreeKey]
    }
    private var entries: [UUID: (key: Key, metadata: SidebarLocalWorktreeMetadata)] = [:]
    private let build: (RepoEntry, String?) -> SidebarLocalWorktreeMetadata

    init(build: @escaping (RepoEntry, String?) -> SidebarLocalWorktreeMetadata = SidebarLocalWorktreeMetadata.init) {
        self.build = build
    }

    func retainRepositories(_ repos: [RepoEntry]) {
        let ids = Set(repos.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }

    func metadata(for repo: RepoEntry, defaultBranch: String?) -> SidebarLocalWorktreeMetadata {
        let key = Key(path: repo.path, defaultBranch: defaultBranch, worktrees: repo.worktrees.map {
            WorktreeKey(id: $0.id, path: $0.path, branch: $0.branch, isPinned: $0.isPinned)
        })
        if let cached = entries[repo.id], cached.key == key { return cached.metadata }
        let metadata = build(repo, defaultBranch)
        entries[repo.id] = (key, metadata)
        return metadata
    }
}

/// Uses the same `WorktreePanes(entry:repo:inputs:)` projection as the published snapshot.
@MainActor
func sidebarLocalWorktrees(state: AppState, owner: WorktreeOrigin,
                          titles: [PaneSlotID: String], liveness: [String: AgentLiveness], prBadges: [String: PRBadge] = [:],
                          metadataCache: SidebarLocalWorktreeMetadataCache? = nil,
                          defaultBranch: (RepoEntry) -> String? = { $0.defaultBranchHint }) -> [WorktreePanes] {
    metadataCache?.retainRepositories(state.repos)
    return state.repos.flatMap { repo in
        sidebarLocalWorktrees(SidebarHostNavigation.displayedWorktrees(in: repo), in: repo, owner: owner,
                              titles: titles, liveness: liveness, prBadge: { prBadges[$0] },
                              metadataCache: metadataCache, defaultBranch: defaultBranch)
    }
}

/// The row `sidebarLocalWorktrees` would produce for `path`. Labels depend
/// on siblings, so only the owning repository is projected.
@MainActor
func sidebarLocalWorktree(atPath path: String, state: AppState, owner: WorktreeOrigin,
                          titles: [PaneSlotID: String], liveness: [String: AgentLiveness], prBadge: PRBadge?,
                          defaultBranch: (RepoEntry) -> String? = { $0.defaultBranchHint }) -> WorktreePanes? {
    guard let repo = state.repo(forWorktreePath: path) else { return nil }
    return sidebarLocalWorktrees(repo.worktrees.filter { $0.path == path }, in: repo, owner: owner,
                                 titles: titles, liveness: liveness, prBadge: { _ in prBadge }, defaultBranch: defaultBranch).first
}

/// Projects `worktrees` of `repo`. Labels and folder ancestry depend on
/// every sibling, so they always come from the whole repository.
@MainActor
private func sidebarLocalWorktrees(_ worktrees: [WorktreeEntry], in repo: RepoEntry, owner: WorktreeOrigin,
                                   titles: [PaneSlotID: String], liveness: [String: AgentLiveness],
                                   prBadge: (String) -> PRBadge?, metadataCache: SidebarLocalWorktreeMetadataCache? = nil,
                                   defaultBranch: (RepoEntry) -> String?) -> [WorktreePanes] {
    let branch = defaultBranch(repo)
    let metadata = metadataCache?.metadata(for: repo, defaultBranch: branch)
        ?? SidebarLocalWorktreeMetadata(repo: repo, defaultBranch: branch)
    return worktrees.map { wt in
        sidebarLocalWorktree(wt, repo: repo, owner: owner, displayName: metadata.labels[wt.id] ?? "",
                             titles: titles, liveness: liveness, prBadge: prBadge(wt.path), folders: metadata.ancestry[wt.id])
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
