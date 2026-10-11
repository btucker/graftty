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
            let data = await Task.detached(priority: .utility) {
                switch repo.iconOverride {
                case .initials: return nil as Data?
                case .image(let data): return data.count <= 2 * 1024 * 1024 ? data : nil
                case nil: return ProjectIconDiscovery.discoverSource(at: URL(fileURLWithPath: repo.path))
                }
            }.value
            guard projectIconLoads[repo.id]?.token == token else { continue }
            projectIconLoads[repo.id] = nil
            guard let current = state.repos.first(where: { $0.id == repo.id }),
                  current.path == repo.path, current.iconOverride == repo.iconOverride else { continue }
            projectIcons[repo.id] = HostProjectIcon(path: repo.path, override: repo.iconOverride,
                checked: Date(), data: data, revision: data.map(ProjectIconDiscovery.revision))
        }
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
            return SidebarProject(id: repo.path, repositoryID: repo.path, name: repo.displayName,
                owner: origin, iconRevision: currentProjectIcon(for: repo)?.revision, initials: initials,
                supportsWorktreeEditing: true)
        }))
    }
}
