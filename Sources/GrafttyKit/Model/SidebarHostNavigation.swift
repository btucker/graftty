import Foundation
import GrafttyProtocol

public struct SidebarHostState: Codable, Sendable, Equatable {
    public var order: SidebarProjectOrder
    public var cachedProjects: [SidebarProject]
    public init(order: SidebarProjectOrder = .init(), cachedProjects: [SidebarProject] = []) {
        self.order = order; self.cachedProjects = cachedProjects
    }
    public mutating func reconcile(_ available: [SidebarProject]) -> [SidebarProject] {
        let current = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = cachedProjects.map { old -> SidebarProject in
            if let live = current[old.id] { return live }
            var offline = old; offline.isAvailable = false; return offline
        }
        let known = Set(result.map(\.id))
        result += available.filter { !known.contains($0.id) }
        order.discover(result.map(\.id))
        cachedProjects = order.sorted(result)
        return cachedProjects
    }
}

public enum ProjectIconOverride: Codable, Sendable, Equatable {
    case initials(String)
    case image(Data)
}

public enum SidebarHostNavigation {
    /// Only used to recognize identities written by older builds.
    private static let emojiPool = Array("🌱 🌿 🍀 🌻 🌵 🌲 🌴 🍄 🪴 🌾 🐝 🦋 🐙 🐢 🦊 🐻 🐼 🐨 🐸 🦉 🐧 🐳 🦀 🐬 🦎 🦄 🐞 🐌 🐚 🪼 🍋 🍉 🍓 🍒 🍑 🥑 🌶️ 🥨 🧀 🥐 🍕 🍣 🧁 ☕️ 🫖 🧭 🗺️ 🧩 🎯 🎨 🎭 🎮 🎲 🎸 🎹 🎺 🎻 🥁 📚 📝 💡 🔦 🔭 🔬 🧪 🧬 🧲 🧰 🛠️ ⚙️ 🔑 🔒 🚀 🛸 ✈️ 🚂 🚲 ⛵️ 🏔️ 🌋 🏝️ 🌊 🌈 ☀️ 🌙 ⭐️ ❄️ 🔥 💎 🪐 🎈 🎁 🏆 🏁".split(separator: " ").map(String.init))

    /// @spec LAYOUT-2.78: When upgrading from automatically assigned worktree emojis, the application shall remove generated identities while preserving edits that differ from the old automatic choice.
    public static func migrateLegacyEmojis(in repos: inout [RepoEntry]) {
        guard repos.contains(where: { $0.worktrees.contains { $0.emoji != nil && $0.emojiSource == nil } }) else { return }
        var expected = repos
        for repoIndex in expected.indices {
            for worktreeIndex in expected[repoIndex].worktrees.indices where expected[repoIndex].worktrees[worktreeIndex].emojiSource == nil {
                expected[repoIndex].worktrees[worktreeIndex].emoji = nil
            }
        }
        assignLegacyEmojis(in: &expected)
        for repoIndex in repos.indices {
            for worktreeIndex in repos[repoIndex].worktrees.indices {
                guard let emoji = repos[repoIndex].worktrees[worktreeIndex].emoji,
                      repos[repoIndex].worktrees[worktreeIndex].emojiSource == nil else { continue }
                if emoji == expected[repoIndex].worktrees[worktreeIndex].emoji {
                    repos[repoIndex].worktrees[worktreeIndex].emoji = nil
                } else {
                    repos[repoIndex].worktrees[worktreeIndex].emojiSource = .manual
                }
            }
        }
    }

    /// @spec LAYOUT-2.77: When an agent's proposed emoji is already used, the application shall try its task-related alternatives before assigning a worktree identity.
    public static func adoptReportedEmoji(_ recap: AttentionRecap?, worktreePath: String, in repos: inout [RepoEntry]) {
        migrateLegacyEmojis(in: &repos)
        guard let recap, recap.isValid else { return }
        let used = Set(repos.flatMap(\.worktrees).compactMap(\.emoji))
        guard let emoji = recap.proposedEmojis.first(where: { !used.contains($0) }) else { return }
        for repoIndex in repos.indices {
            guard let worktreeIndex = repos[repoIndex].worktrees.firstIndex(where: { $0.path == worktreePath }),
                  repos[repoIndex].worktrees[worktreeIndex].emoji == nil else { continue }
            repos[repoIndex].worktrees[worktreeIndex].emoji = emoji
            repos[repoIndex].worktrees[worktreeIndex].emojiSource = .agent
            return
        }
    }

    static func assignLegacyEmojis(in repos: inout [RepoEntry]) {
        var used = Set(repos.flatMap(\.worktrees).compactMap(\.emoji))
        for index in repos.indices { assignLegacyEmojis(in: &repos[index].worktrees, used: &used) }
    }

    private static func assignLegacyEmojis(in worktrees: inout [WorktreeEntry], used: inout Set<String>) {
        for index in worktrees.indices where worktrees[index].emoji == nil {
            let start = Int(worktrees[index].id.uuidString.utf8.reduce(UInt64(14695981039346656037)) {
                ($0 ^ UInt64($1)) &* 1099511628211
            } % UInt64(emojiPool.count))
            let choice = (0..<emojiPool.count).lazy.map { emojiPool[(start + $0) % emojiPool.count] }.first { !used.contains($0) }
            var emoji = choice ?? "✨"
            while used.contains(emoji) { emoji += "✨" }
            worktrees[index].emoji = emoji
            used.insert(emoji)
        }
    }

    public static func canonicalWorktrees(in repo: RepoEntry) -> [WorktreeEntry] {
        repo.worktrees.filter { $0.path == repo.path }
            + WorktreeOrdering.staleLast(repo.worktrees.filter { $0.path != repo.path })
    }

    public static func metadata(for worktree: WorktreeEntry, projectID: String, folders: [String], folderIDs: [String]? = nil) -> SidebarWorktreeMetadata {
        var times = Dictionary(worktree.paneAttention.map { ($0.key.id.uuidString, $0.value.timestamp.timeIntervalSinceReferenceDate) }, uniquingKeysWith: { first, _ in first })
        times["worktree"] = worktree.attention?.timestamp.timeIntervalSinceReferenceDate
        return .init(id: "\(projectID):\(worktree.id.uuidString)", projectID: projectID, folders: folders, folderIDs: folderIDs,
                     paneIDs: Dictionary(worktree.paneSessions.map { (ZmxLauncher.sessionName(for: $0.value), $0.key.id.uuidString) }, uniquingKeysWith: { first, _ in first }),
                     paneSlotIDs: worktree.splitTree.allLeaves.map { $0.id.uuidString },
                     attentionTimestamps: times, unseenAgentStop: worktree.unseenAgentStop,
                     agentProgressTimes: worktree.agentProgressTimes, emoji: worktree.emoji)
    }

    @discardableResult
    public static func moveWorktree(in state: inout AppState, repositoryID: String,
                                    worktreeID: String, relativeTo: String, after: Bool) -> Bool {
        guard worktreeID != relativeTo,
              let ri = state.repos.firstIndex(where: { $0.path == repositoryID }) else { return false }
        let repo = state.repos[ri]
        let rows = repo.worktrees
        guard let source = rows.firstIndex(where: { $0.path == worktreeID }),
              let target = rows.firstIndex(where: { $0.path == relativeTo }),
              rows[source].path != repo.path,
              !rows[source].state.isInFlight, !rows[target].state.isInFlight,
              rows[target].path != repo.path || after else { return false }
        let nodes = SidebarWorktreeHierarchy.nodes(for: rows, inRepoAtPath: repo.path, defaultBranch: nil)
        let parents = SidebarWorktreeHierarchy.parentFolderPaths(in: nodes)
        guard parents[rows[source].id] == parents[rows[target].id] else { return false }
        let indices = rows.indices.filter { parents[rows[$0].id] == parents[rows[source].id] }
        let siblings = indices.map { rows[$0] }
        guard let ti = indices.firstIndex(of: target) else { return false }
        let destination = ti + (after ? 1 : 0)
        let neighbors = [destination - 1, destination].filter {
            siblings.indices.contains($0) && siblings[$0].id != rows[source].id
        }
        guard neighbors.allSatisfy({ !siblings[$0].state.isInFlight }),
              let moved = WorktreeOrdering.move(siblings, movingIDs: [rows[source].id], toIndex: destination),
              moved != siblings else { return false }
        for (index, worktree) in zip(indices, moved) { state.repos[ri].worktrees[index] = worktree }
        return true
    }

    @discardableResult
    public static func acknowledge(in state: inout AppState, worktreeID: String, paneID: String?,
                                    occurrence: SidebarAttentionOccurrence) -> Bool {
        for ri in state.repos.indices {
            guard let wi = state.repos[ri].worktrees.firstIndex(where: { $0.path == worktreeID }) else { continue }
            if paneID == nil, let stop = state.repos[ri].worktrees[wi].unseenAgentStop,
               occurrence == stop.occurrence {
                state.repos[ri].worktrees[wi].unseenAgentStop = nil
                return true
            }
            if let paneID {
                guard let slot = state.repos[ri].worktrees[wi].paneSlot(forSessionName: paneID),
                      let attention = state.repos[ri].worktrees[wi].paneAttention[slot],
                      occurrence.matches(timestamp: attention.timestamp, text: attention.text, source: attention.source) else { return false }
                state.repos[ri].worktrees[wi].paneAttention[slot] = nil
            } else {
                guard let attention = state.repos[ri].worktrees[wi].attention,
                      occurrence.matches(timestamp: attention.timestamp, text: attention.text, source: attention.source) else { return false }
                state.repos[ri].worktrees[wi].attention = nil
            }
            return true
        }
        return false
    }
}
