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

    /// @spec AGENT-3.34
    /// A linked worktree adopts its first valid drawing. A later drawing
    /// replaces it only when the same recap says the purpose changed, so
    /// icons stay stable enough to remember. The hue is assigned once.
    public static func adoptReportedDrawing(_ recap: AttentionRecap?, worktreePath: String, projectHue: Double?, in repos: inout [RepoEntry]) {
        guard let recap, recap.isValid, let icon = recap.icon, let svg = try? WorktreeDrawingSVG.validate(icon) else { return }
        for repoIndex in repos.indices {
            guard worktreePath != repos[repoIndex].path,
                  let index = repos[repoIndex].worktrees.firstIndex(where: { $0.path == worktreePath }) else { continue }
            let current = repos[repoIndex].worktrees[index]
            guard current.drawing == nil || recap.purposeChanged == true else { return }
            let hue = current.drawingHue ?? WorktreeColorAssignment.hue(
                avoiding: repos[repoIndex].worktrees.compactMap(\.drawingHue) + [projectHue].compactMap { $0 })
            repos[repoIndex].worktrees[index].drawingHue = hue
            repos[repoIndex].worktrees[index].drawing = WorktreeDrawing(svg: svg, hue: hue)
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

    /// The repository's home checkout is always pinned; linked worktrees opt in.
    public static func isPinned(_ worktree: WorktreeEntry, in repo: RepoEntry) -> Bool {
        worktree.path == repo.path || worktree.isPinned
    }

    /// Pinned agents precede temporary worktrees. The default-branch row leads
    /// the pinned section, followed by linked worktrees in saved manual order.
    public static func canonicalWorktrees(in repo: RepoEntry) -> [WorktreeEntry] {
        pinnedWorktrees(in: repo)
            + WorktreeOrdering.staleLast(repo.worktrees.filter { !isPinned($0, in: repo) })
    }

    private static func pinnedWorktrees(in repo: RepoEntry) -> [WorktreeEntry] {
        let linked = repo.worktrees.filter { $0.path != repo.path && $0.isPinned }
        return repo.worktrees.filter { $0.path == repo.path }
            + linked.filter { $0.pinnedRank != nil }.sorted { $0.pinnedRank! < $1.pinnedRank! }
            + linked.filter { $0.pinnedRank == nil }
    }

    /// Gives unranked projects and pins a rank after those already ranked,
    /// following current order. A seeded rank has no change time, so it loses
    /// to any rank set by a drag.
    public static func seedRanks(in repos: inout [RepoEntry], projectOrder: [UUID]) {
        let positions = Dictionary(projectOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let ordered = repos.indices.sorted {
            positions[repos[$0].id, default: .max] == positions[repos[$1].id, default: .max]
                ? $0 < $1 : positions[repos[$0].id, default: .max] < positions[repos[$1].id, default: .max]
        }
        var last = repos.compactMap(\.projectRank).max()
        var next = 0
        for index in ordered where repos[index].projectRank == nil {
            let rank = last.map { FractionalRank.between($0, nil) } ?? FractionalRank.seed(index: next)
            repos[index].projectRank = rank
            next += 1
            if last != nil { last = rank }
        }
        for index in repos.indices {
            let repoPath = repos[index].path
            var lastPin = repos[index].worktrees.filter { $0.path != repoPath && $0.isPinned }.compactMap(\.pinnedRank).max()
            var nextPin = 0
            for row in repos[index].worktrees.indices {
                let worktree = repos[index].worktrees[row]
                guard worktree.path != repoPath, worktree.isPinned, worktree.pinnedRank == nil else { continue }
                let rank = lastPin.map { FractionalRank.between($0, nil) } ?? FractionalRank.seed(index: nextPin)
                repos[index].worktrees[row].pinnedRank = rank
                nextPin += 1
                if lastPin != nil { lastPin = rank }
            }
        }
    }

    @discardableResult
    public static func setPinnedRank(_ rank: String, worktreeID: String, repositoryID: String, in state: inout AppState) -> Bool {
        guard FractionalRank.isValid(rank),
              let ri = state.repos.firstIndex(where: { $0.path == repositoryID }),
              let wi = state.repos[ri].worktrees.firstIndex(where: { $0.path == worktreeID }),
              worktreeID != repositoryID, state.repos[ri].worktrees[wi].isPinned else { return false }
        state.repos[ri].worktrees[wi].pinnedRank = rank
        return true
    }

    /// A repeated or older write is accepted and ignored: the newest change wins.
    @discardableResult
    public static func setProjectRank(_ rank: String, changedAt: Double, repositoryID: String, in state: inout AppState) -> Bool {
        guard FractionalRank.isValid(rank), changedAt.isFinite,
              let ri = state.repos.firstIndex(where: { $0.path == repositoryID }) else { return false }
        guard (state.repos[ri].projectRankChangedAt ?? -.infinity) < changedAt else { return true }
        state.repos[ri].projectRank = rank
        state.repos[ri].projectRankChangedAt = changedAt
        return true
    }

    /// `keys` holds successful lookups only, so a failed git call keeps the old key.
    public static func applyOriginKeys(_ keys: [String: String], in repos: inout [RepoEntry]) {
        for index in repos.indices {
            if let key = keys[repos[index].path], repos[index].originKey != key { repos[index].originKey = key }
        }
    }

    /// Temporary worktrees always sort by recent activity. Never written back,
    /// so an older client's saved order survives.
    public static func displayedWorktrees(in repo: RepoEntry) -> [WorktreeEntry] {
        pinnedWorktrees(in: repo)
            + WorktreeOrdering.byRecentActivity(repo.worktrees.filter { !isPinned($0, in: repo) })
    }

    /// Published folder ancestry matches the separately rendered sections.
    public static func folderAncestry(in repo: RepoEntry) -> [UUID: [SidebarWorktreeHierarchy.Folder]] {
        var result: [UUID: [SidebarWorktreeHierarchy.Folder]] = [:]
        for pinned in [false, true] {
            let nodes = SidebarWorktreeHierarchy.nodes(
                for: repo.worktrees.filter { isPinned($0, in: repo) == pinned },
                inRepoAtPath: repo.path, defaultBranch: nil)
            result.merge(SidebarWorktreeHierarchy.folderAncestry(in: nodes), uniquingKeysWith: { first, _ in first })
        }
        return result
    }

    @discardableResult
    public static func setPinned(_ pinned: Bool, worktreeID: UUID, in repos: inout [RepoEntry]) -> Bool {
        for repoIndex in repos.indices {
            guard let index = repos[repoIndex].worktrees.firstIndex(where: { $0.id == worktreeID }) else { continue }
            let worktree = repos[repoIndex].worktrees[index]
            guard worktree.path != repos[repoIndex].path, !worktree.state.isInFlight,
                  !pinned || worktree.state.hasOnDiskWorktree,
                  worktree.isPinned != pinned else { return false }
            repos[repoIndex].worktrees[index].isPinned = pinned
            // A later pin starts at the end of the list again.
            if !pinned { repos[repoIndex].worktrees[index].pinnedRank = nil }
            return true
        }
        return false
    }

    /// A pin drop crosses section membership rather than reordering temporary
    /// rows. Existing peers keep their order, and the new role lands beside the
    /// row where it was dropped.
    @discardableResult
    public static func pinWorktree(in state: inout AppState, repositoryID: String,
                                   worktreeID: String, relativeTo: String? = nil, after: Bool = true) -> Bool {
        guard let ri = state.repos.firstIndex(where: { $0.path == repositoryID }),
              let si = state.repos[ri].worktrees.firstIndex(where: { $0.path == worktreeID }) else { return false }
        let repo = state.repos[ri]
        let source = repo.worktrees[si]
        guard source.path != repo.path, !source.isPinned,
              !source.state.isInFlight, source.state.hasOnDiskWorktree else { return false }
        if let relativeTo {
            guard let target = repo.worktrees.first(where: { $0.path == relativeTo }),
                  isPinned(target, in: repo), !target.state.isInFlight else { return false }
        }
        var candidate = state
        guard setPinned(true, worktreeID: source.id, in: &candidate.repos) else { return false }
        let pinned = candidate.repos[ri].worktrees.remove(at: si)
        candidate.repos[ri].worktrees.append(pinned)
        if let relativeTo {
            // If a pending neighbor prevents placement,
            // retain the appended role without moving any existing peers.
            moveWorktree(in: &candidate, repositoryID: repositoryID, worktreeID: worktreeID,
                relativeTo: relativeTo, after: relativeTo == repo.path || after)
        }
        state = candidate
        return true
    }

    /// Applies a user-picked emoji as a manual identity. Rejects anything
    /// that is not exactly one emoji or that another worktree already uses.
    @discardableResult
    public static func setManualEmoji(_ value: String, worktreeID: UUID, in repos: inout [RepoEntry]) -> Bool {
        let emoji = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AttentionRecap.isSingleEmoji(emoji),
              !repos.flatMap(\.worktrees).contains(where: { $0.id != worktreeID && $0.emoji == emoji }) else { return false }
        return updateWorktree(worktreeID, in: &repos) { $0.emoji = emoji; $0.emojiSource = .manual; $0.emojiChosenByUser = true }
    }

    @discardableResult
    public static func clearEmoji(worktreeID: UUID, in repos: inout [RepoEntry]) -> Bool {
        updateWorktree(worktreeID, in: &repos) { $0.emoji = nil; $0.emojiSource = nil; $0.emojiChosenByUser = false }
    }

    private static func updateWorktree(_ worktreeID: UUID, in repos: inout [RepoEntry],
                                       _ change: (inout WorktreeEntry) -> Void) -> Bool {
        for repoIndex in repos.indices {
            guard let index = repos[repoIndex].worktrees.firstIndex(where: { $0.id == worktreeID }) else { continue }
            change(&repos[repoIndex].worktrees[index])
            return true
        }
        return false
    }

    public static func metadata(for worktree: WorktreeEntry, projectID: String, folders: [String], repositoryPath: String? = nil, folderIDs: [String]? = nil) -> SidebarWorktreeMetadata {
        var times = Dictionary(worktree.paneAttention.map { ($0.key.id.uuidString, $0.value.timestamp.timeIntervalSinceReferenceDate) }, uniquingKeysWith: { first, _ in first })
        times["worktree"] = worktree.attention?.timestamp.timeIntervalSinceReferenceDate
        var metadata = SidebarWorktreeMetadata(id: "\(projectID):\(worktree.id.uuidString)", projectID: projectID, folders: folders, folderIDs: folderIDs,
                     paneIDs: Dictionary(worktree.paneSessions.map { (ZmxLauncher.sessionName(for: $0.value), $0.key.id.uuidString) }, uniquingKeysWith: { first, _ in first }),
                     paneSlotIDs: worktree.splitTree.allLeaves.map { $0.id.uuidString },
                     attentionTimestamps: times, unseenAgentStop: worktree.unseenAgentStop, lastAgentStop: worktree.lastAgentStop, brief: worktree.brief, history: worktree.history,
                     agentProgressTimes: worktree.agentProgressTimes, emoji: worktree.path == repositoryPath ? nil : worktree.emoji, isPinned: worktree.isPinned,
                     activityTime: worktree.lastActivity?.timeIntervalSinceReferenceDate, pinnedRank: worktree.isPinned ? worktree.pinnedRank : nil)
        #if canImport(AppKit)
        // A host without the renderer could never serve the image (LAYOUT-2.204).
        metadata.drawingRevision = worktree.path == repositoryPath ? nil : worktree.drawing?.revision
        #endif
        metadata.emojiChosenByUser = worktree.emojiChosenByUser ? true : nil
        return metadata
    }

    /// Sets only the display mode; saved worktree order and pin state survive.
    @discardableResult
    public static func setWorktreeOrder(_ mode: WorktreeOrderMode, in state: inout AppState, repositoryID: String) -> Bool {
        guard let index = state.repos.firstIndex(where: { $0.path == repositoryID && $0.isGitTracked }) else { return false }
        state.repos[index].worktreeOrderMode = mode
        return true
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
              isPinned(rows[source], in: repo) == isPinned(rows[target], in: repo),
              isPinned(rows[source], in: repo),
              rows[target].path != repo.path || after else { return false }
        // Pinned agents are one flat grid, so every pinned row is a sibling.
        let indices = rows.indices.filter { isPinned(rows[$0], in: repo) }
        // A newly pinned row can precede the home checkout in saved state.
        // Interpret the drop against the section's displayed canonical order.
        let siblingIDs = Set(indices.map { rows[$0].id })
        let siblings = canonicalWorktrees(in: repo).filter { siblingIDs.contains($0.id) }
        guard let ti = siblings.firstIndex(where: { $0.id == rows[target].id }) else { return false }
        let destination = ti + (after ? 1 : 0)
        let neighbors = [destination - 1, destination].filter {
            siblings.indices.contains($0) && siblings[$0].id != rows[source].id
        }
        guard neighbors.allSatisfy({ !siblings[$0].state.isInFlight }),
              let moved = WorktreeOrdering.move(siblings, movingIDs: [rows[source].id], toIndex: destination),
              moved != siblings else { return false }
        for (index, worktree) in zip(indices, moved) { state.repos[ri].worktrees[index] = worktree }
        // Older clients still move pins with this request. Keep the rank true
        // so every other device sees the same order.
        if let position = moved.firstIndex(where: { $0.id == rows[source].id }), rows[source].isPinned,
           let index = state.repos[ri].worktrees.firstIndex(where: { $0.id == rows[source].id }) {
            let lower = position > 0 ? moved[position - 1].pinnedRank : nil
            let upper = position + 1 < moved.count ? moved[position + 1].pinnedRank : nil
            state.repos[ri].worktrees[index].pinnedRank = FractionalRank.between(lower, upper)
        }
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
