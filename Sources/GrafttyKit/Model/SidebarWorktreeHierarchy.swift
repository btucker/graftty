import Foundation

/// A sidebar worktree row or a virtual folder formed from managed relative
/// names or a conservatively inferred shared root for external worktrees.
public indirect enum SidebarWorktreeNode: Equatable, Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        case worktree(WorktreeEntry.ID)
        case folder(String)
    }

    case worktree(WorktreeEntry, displayName: String)
    case folder(path: String, name: String, children: [SidebarWorktreeNode])

    public var id: ID {
        switch self {
        case .worktree(let worktree, _):
            return .worktree(worktree.id)
        case .folder(let path, _, _):
            return .folder(path)
        }
    }

    /// `OutlineGroup` treats a non-nil value as an expandable node and nil
    /// as a leaf. Folder children are never empty because folders are only
    /// formed from two or more descendant worktrees.
    public var children: [SidebarWorktreeNode]? {
        switch self {
        case .worktree:
            return nil
        case .folder(_, _, let children):
            return children
        }
    }
}

/// Repository-scoped identity for a virtual sidebar folder. Folder paths are
/// only unique within one repository (`research` can exist in many repos), so
/// expansion state must carry both pieces.
public struct SidebarWorktreeFolderID: Hashable, Sendable {
    public let repositoryID: UUID
    public let path: String

    public init(repositoryID: UUID, path: String) {
        self.repositoryID = repositoryID
        self.path = path
    }
}

/// Session-local disclosure state for virtual worktree folders. Storing only
/// collapsed IDs makes newly discovered folders expanded by default without a
/// synchronization pass when the hierarchy changes.
public struct SidebarWorktreeFolderExpansion: Equatable, Sendable {
    private var collapsedFolderIDs: Set<SidebarWorktreeFolderID> = []

    public init() {}

    public func isExpanded(_ folderID: SidebarWorktreeFolderID) -> Bool {
        !collapsedFolderIDs.contains(folderID)
    }

    public mutating func setExpanded(
        _ isExpanded: Bool,
        for folderID: SidebarWorktreeFolderID
    ) {
        if isExpanded {
            collapsedFolderIDs.remove(folderID)
        } else {
            collapsedFolderIDs.insert(folderID)
        }
    }
}

/// Builds the virtual folder structure used by the macOS sidebar.
///
/// Graftty-created worktrees have an explicit namespace root at
/// `<repo>/.worktrees`. Worktrees created by other tools can live elsewhere;
/// when at least two of those paths diverge beneath the same sufficiently
/// specific directory, that directory becomes an inferred root. Broad
/// ancestors shared with the main checkout are deliberately rejected.
public enum SidebarWorktreeHierarchy {
    public static func nodes(
        for worktrees: [WorktreeEntry],
        inRepoAtPath repoPath: String,
        defaultBranch: String?
    ) -> [SidebarWorktreeNode] {
        let labels = SidebarWorktreeLabel.texts(
            for: worktrees,
            inRepoAtPath: repoPath,
            defaultBranch: defaultBranch
        )
        let inferredComponents = inferredExternalComponents(
            for: worktrees,
            inRepoAtPath: repoPath
        )
        let items = worktrees.map { worktree in
            let managedComponents = SidebarWorktreeLabel
                .managedRelativeName(forPath: worktree.path, inRepoAtPath: repoPath)
                .map(componentsForManagedName)
            return Item(
                worktree: worktree,
                remainingComponents: managedComponents ?? inferredComponents[worktree.id],
                fallbackLabel: labels[worktree.id] ?? worktree.branch
            )
        }
        return build(items)
    }

    /// Returns the virtual folder containing each nested worktree. Root-level
    /// worktrees are omitted, so a missing value consistently means the
    /// hierarchy root. The sidebar uses this to prevent a flat-array reorder
    /// from crossing a folder boundary that path-based grouping would
    /// immediately restore.
    public static func parentFolderPaths(
        in nodes: [SidebarWorktreeNode]
    ) -> [WorktreeEntry.ID: String] {
        var result: [WorktreeEntry.ID: String] = [:]
        collectParentFolderPaths(in: nodes, parentPath: nil, into: &result)
        return result
    }

    /// Sums the already-computed Git statistics for every descendant
    /// worktree. Missing entries are omitted just as their individual rows
    /// omit the gutter while stats are unresolved; the aggregate converges as
    /// `WorktreeStatsStore` publishes each result.
    public static func aggregateStats(
        in node: SidebarWorktreeNode,
        statsByWorktreePath: [String: WorktreeStats]
    ) -> WorktreeStats? {
        let stats = descendantWorktreePaths(in: node).compactMap {
            statsByWorktreePath[$0]
        }
        guard !stats.isEmpty else { return nil }
        return WorktreeStats(
            ahead: stats.reduce(0) { $0 + $1.ahead },
            behind: stats.reduce(0) { $0 + $1.behind },
            insertions: stats.reduce(0) { $0 + $1.insertions },
            deletions: stats.reduce(0) { $0 + $1.deletions },
            hasUncommittedChanges: stats.contains(where: \.hasUncommittedChanges)
        )
    }

    private static func descendantWorktreePaths(
        in node: SidebarWorktreeNode
    ) -> [String] {
        switch node {
        case .worktree(let worktree, _):
            return [worktree.path]
        case .folder(_, _, let children):
            return children.flatMap { descendantWorktreePaths(in: $0) }
        }
    }

    private static func collectParentFolderPaths(
        in nodes: [SidebarWorktreeNode],
        parentPath: String?,
        into result: inout [WorktreeEntry.ID: String]
    ) {
        for node in nodes {
            switch node {
            case .worktree(let worktree, _):
                if let parentPath {
                    result[worktree.id] = parentPath
                }
            case .folder(let path, _, let children):
                collectParentFolderPaths(
                    in: children,
                    parentPath: path,
                    into: &result
                )
            }
        }
    }

    private struct HierarchyComponent {
        let idPath: String
        let name: String
    }

    private struct Item {
        let worktree: WorktreeEntry
        let remainingComponents: [HierarchyComponent]?
        let fallbackLabel: String
    }

    private struct DescendantGroup {
        let component: HierarchyComponent
        var items: [Item]
    }

    private static func build(_ items: [Item]) -> [SidebarWorktreeNode] {
        var descendantsByComponent: [String: DescendantGroup] = [:]
        for item in items {
            guard let components = item.remainingComponents,
                  components.count > 1,
                  let first = components.first else { continue }
            var group = descendantsByComponent[first.idPath]
                ?? DescendantGroup(component: first, items: [])
            group.items.append(Item(
                worktree: item.worktree,
                remainingComponents: Array(components.dropFirst()),
                fallbackLabel: item.fallbackLabel
            ))
            descendantsByComponent[first.idPath] = group
        }
        let groupedComponents = Set(
            descendantsByComponent.compactMap { idPath, group in
                group.items.count >= 2 ? idPath : nil
            }
        )

        var emittedGroups: Set<String> = []
        var result: [SidebarWorktreeNode] = []

        for item in items {
            guard let components = item.remainingComponents,
                  components.count > 1,
                  let first = components.first,
                  groupedComponents.contains(first.idPath) else {
                let label = item.remainingComponents?.map(\.name).joined(separator: "/")
                    ?? item.fallbackLabel
                result.append(.worktree(item.worktree, displayName: label))
                continue
            }

            guard emittedGroups.insert(first.idPath).inserted else { continue }
            guard let group = descendantsByComponent[first.idPath] else { continue }
            result.append(.folder(
                path: first.idPath,
                name: group.component.name,
                children: build(group.items)
            ))
        }

        return result
    }

    private static func componentsForManagedName(_ relativeName: String) -> [HierarchyComponent] {
        var path: [String] = []
        return relativeName.split(separator: "/").map { component in
            let name = String(component)
            path.append(name)
            return HierarchyComponent(idPath: path.joined(separator: "/"), name: name)
        }
    }

    private struct ExternalPath {
        let worktreeID: WorktreeEntry.ID
        let components: [String]
    }

    private struct RootCandidate {
        let path: String
        let components: [String]
        var descendantIDs: Set<WorktreeEntry.ID>
        var branches: Set<String>

        var namedComponents: [String] {
            components.filter { $0 != "/" }
        }
    }

    /// Infers independent external roots from branching points in the path
    /// trie. Requiring a branch (rather than merely a shared prefix) skips
    /// unary ancestors such as `/Users/me/.codex`; two Codex paths under
    /// `~/.codex/worktrees/<id>/...` infer `~/.codex/worktrees` instead.
    private static func inferredExternalComponents(
        for worktrees: [WorktreeEntry],
        inRepoAtPath repoPath: String
    ) -> [WorktreeEntry.ID: [HierarchyComponent]] {
        let repoComponents = standardizedComponents(repoPath)
        let homeComponents = standardizedComponents(
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        let externalPaths = worktrees.compactMap { worktree -> ExternalPath? in
            guard worktree.path != repoPath,
                  SidebarWorktreeLabel.managedRelativeName(
                    forPath: worktree.path,
                    inRepoAtPath: repoPath
                  ) == nil else { return nil }
            return ExternalPath(
                worktreeID: worktree.id,
                components: standardizedComponents(worktree.path)
            )
        }

        var candidatesByPath: [String: RootCandidate] = [:]
        for external in externalPaths {
            // A candidate needs at least two named components beneath `/`
            // (`/tmp/shared`, `/Users/me`, `/Volumes/Drive`, ...), plus a
            // worktree leaf below it.
            guard external.components.count > 3 else { continue }
            for length in 3..<external.components.count {
                let components = Array(external.components.prefix(length))
                let path = NSString.path(withComponents: components)
                var candidate = candidatesByPath[path] ?? RootCandidate(
                    path: path,
                    components: components,
                    descendantIDs: [],
                    branches: []
                )
                candidate.descendantIDs.insert(external.worktreeID)
                candidate.branches.insert(external.components[length])
                candidatesByPath[path] = candidate
            }
        }

        let eligible = candidatesByPath.values.filter { candidate in
            candidate.descendantIDs.count >= 2
                && candidate.branches.count >= 2
                && candidate.components != homeComponents
                && !repoComponents.starts(with: candidate.components)
        }
        let ordered = eligible.sorted {
            if $0.components.count != $1.components.count {
                return $0.components.count < $1.components.count
            }
            return $0.path < $1.path
        }

        // Keep the highest meaningful branching point for each independent
        // cluster; descendants then become recursive folders through `build`.
        var roots: [RootCandidate] = []
        for candidate in ordered where !roots.contains(where: {
            candidate.components.starts(with: $0.components)
        }) {
            roots.append(candidate)
        }

        let labels = Dictionary(
            uniqueKeysWithValues: roots.map { root in
                (root.path, uniqueSuffixLabel(for: root, among: roots))
            }
        )
        var result: [WorktreeEntry.ID: [HierarchyComponent]] = [:]
        for external in externalPaths {
            guard let root = roots.first(where: {
                external.components.starts(with: $0.components)
            }) else { continue }

            var identityComponents = root.components
            var components = [HierarchyComponent(
                idPath: "external:\(root.path)",
                name: labels[root.path] ?? (root.components.last ?? root.path)
            )]
            for name in external.components.dropFirst(root.components.count) {
                identityComponents.append(name)
                components.append(HierarchyComponent(
                    idPath: "external:\(NSString.path(withComponents: identityComponents))",
                    name: name
                ))
            }
            result[external.worktreeID] = components
        }
        return result
    }

    private static func uniqueSuffixLabel(
        for candidate: RootCandidate,
        among candidates: [RootCandidate]
    ) -> String {
        let components = candidate.namedComponents
        for length in 1...components.count {
            let suffix = components.suffix(length)
            let collides = candidates.contains {
                $0.path != candidate.path && $0.namedComponents.suffix(length) == suffix
            }
            if !collides { return suffix.joined(separator: "/") }
        }
        return candidate.path
    }

    private static func standardizedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }
}
