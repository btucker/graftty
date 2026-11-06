import Foundation
import GrafttyProtocol

struct HostProjectIconLoad {
    let path: String
    let override: ProjectIconOverride?
    let token: UUID
}

struct HostProjectIcon {
    let path: String
    let override: ProjectIconOverride?
    let checked: Date
    let data: Data?
    let revision: String?
}

extension HeadlessHostRuntime {
    func refreshProjectIcons() async {
        await refreshOriginKeys()
        let ids = Set(state.repos.map(\.id))
        projectIcons = projectIcons.filter { ids.contains($0.key) }
        projectIconLoads = projectIconLoads.filter { ids.contains($0.key) }
        for repo in state.repos {
            if let cached = projectIcons[repo.id], cached.path == repo.path,
               cached.override == repo.iconOverride, Date().timeIntervalSince(cached.checked) < 30 { continue }
            if let loading = projectIconLoads[repo.id], loading.path == repo.path, loading.override == repo.iconOverride { continue }
            let token = UUID()
            projectIconLoads[repo.id] = HostProjectIconLoad(path: repo.path, override: repo.iconOverride, token: token)
            if let cached = projectIcons[repo.id], cached.path != repo.path || cached.override != repo.iconOverride {
                projectIcons[repo.id] = nil
            }
            let (data, hue) = await Task.detached(priority: .utility) { () -> (Data?, Double?) in
                let data: Data? = switch repo.iconOverride {
                case .initials: nil
                case .image(let data): data.count <= 2 * 1024 * 1024 ? data : nil
                case nil: ProjectIconDiscovery.discoverSource(at: URL(fileURLWithPath: repo.path))
                }
                // Decoding a full-size source icon must stay off the runtime's main actor.
                #if canImport(AppKit)
                return (data, data.flatMap(WorktreeDrawingRenderer.dominantHue(ofImage:)))
                #else
                return (data, nil)
                #endif
            }.value
            guard projectIconLoads[repo.id]?.token == token else { continue }
            projectIconLoads[repo.id] = nil
            guard let current = state.repos.first(where: { $0.id == repo.id }),
                  current.path == repo.path, current.iconOverride == repo.iconOverride else { continue }
            projectIcons[repo.id] = HostProjectIcon(path: repo.path, override: repo.iconOverride,
                checked: Date(), data: data, revision: data.map(ProjectIconDiscovery.revision))
            ProjectHueRegistry.shared.set(hue, for: repo.id)
        }
    }

    /// An origin rarely changes, so look again every few minutes. Ranks are cheap
    /// and a new pin can't be dragged without one, so those are seeded each pass.
    private func refreshOriginKeys() async {
        var keys: [String: String] = [:]
        let isDue = originKeysCheckedAt.map { Date().timeIntervalSince($0) >= 300 } ?? true
            || state.repos.contains { $0.isGitTracked && $0.originKey == nil && $0.projectRank == nil }
        if isDue {
            originKeysCheckedAt = Date()
            for repo in state.repos where repo.isGitTracked {
                if let origin = try? await GitRepositoryOrigin.detect(repoPath: repo.path) { keys[repo.path] = origin.identityKey }
            }
        }
        var candidate = state
        SidebarHostNavigation.applyOriginKeys(keys, in: &candidate.repos)
        SidebarHostNavigation.seedRanks(in: &candidate.repos, projectOrder: candidate.repos.map(\.id))
        guard candidate != state else { return }
        state = candidate
        try? state.save(to: configuration.stateDirectory)
    }

    /// Clients merge projects from several hosts, so one host's id can't equal
    /// another's just because both checked out to the same path.
    func projectID(for repo: RepoEntry) -> String {
        origin.map { "\($0.deviceID.value):\(repo.path)" } ?? repo.path
    }

    func currentProjectIcon(for repo: RepoEntry) -> HostProjectIcon? {
        guard let cached = projectIcons[repo.id], cached.path == repo.path, cached.override == repo.iconOverride else { return nil }
        return cached
    }

    public func panesMessage() -> PanesStateMessage {
        // Filesystem discovery must not delay pane updates or initial subscriptions.
        if projectIconRefreshTask == nil {
            projectIconRefreshTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshProjectIcons()
                self.projectIconRefreshTask = nil
            }
        }
        return .snapshot(snapshot(), sidebar: SidebarSnapshot(projects: state.repos.map { repo in
            let initials: String?
            if case .initials(let value) = repo.iconOverride { initials = value } else { initials = nil }
            return SidebarProject(id: projectID(for: repo), repositoryID: repo.path, name: repo.displayName,
                owner: origin, iconRevision: currentProjectIcon(for: repo)?.revision, initials: initials,
                supportsWorktreeEditing: repo.isGitTracked, worktreeOrderMode: repo.isGitTracked ? repo.worktreeOrderMode : nil,
                originKey: repo.originKey, rank: repo.projectRank, rankChangedAt: repo.projectRankChangedAt)
        }, hostResources: hostResources))
    }
}
