import SwiftUI
import UniformTypeIdentifiers
import EspalierKit

struct SidebarView: View {
    @Binding var appState: AppState
    let onSelect: (String) -> Void
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onStopWorktree: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(appState.repos) { repo in
                    repoSection(repo)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(action: onAddRepo) {
                Label("Add Repository", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .publishSidebarWidth()
    }

    @ViewBuilder
    private func repoSection(_ repo: RepoEntry) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !repo.isCollapsed },
                set: { expanded in
                    if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[idx].isCollapsed = !expanded
                    }
                }
            )
        ) {
            ForEach(repo.worktrees) { worktree in
                // Wrap the row in a Button so clicks reliably trigger the
                // handler. A bare `.onTapGesture` inside List with sidebar
                // style is swallowed by List's own selection gestures;
                // Button's built-in hit testing bypasses that. `.plain`
                // keeps the row's visual styling.
                Button {
                    onSelect(worktree.path)
                } label: {
                    WorktreeRow(
                        entry: worktree,
                        isSelected: appState.selectedWorktreePath == worktree.path,
                        displayName: label(for: worktree, in: repo),
                        isMainCheckout: worktree.path == repo.path
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    worktreeContextMenu(worktree, repo: repo)
                }
            }
        } label: {
            Label(repo.displayName, systemImage: "folder.fill")
                .fontWeight(.semibold)
        }
    }

    /// The sidebar label for a worktree, special-cased so the main checkout
    /// shows just its branch name (no disambiguation noise — the sidebar
    /// icon differentiates it from linked worktrees), while linked
    /// worktrees show their collision-aware directory name.
    private func label(for worktree: WorktreeEntry, in repo: RepoEntry) -> String {
        if worktree.path == repo.path {
            return worktree.branch
        }
        return worktree.displayName(amongSiblingPaths: repo.worktrees.map(\.path))
    }

    @ViewBuilder
    private func worktreeContextMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> some View {
        if worktree.state == .running {
            Button("Stop") {
                stopWorktree(worktree, in: repo)
            }
        }
        if worktree.state == .stale {
            Button("Dismiss") {
                dismissWorktree(worktree, in: repo)
            }
        }
    }

    private func stopWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        onStopWorktree(worktree.path)
    }

    private func dismissWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        guard let repoIdx = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
        appState.repos[repoIdx].worktrees.removeAll { $0.id == worktree.id }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let path = url.path
                DispatchQueue.main.async {
                    onAddPath(path)
                }
            }
        }
        return true
    }
}
