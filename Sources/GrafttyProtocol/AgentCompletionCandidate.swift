import Foundation

/// A routable top-level agent, with labels independent of its address.
public struct AgentCompletionCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { address }
    public let address: String
    public let projectPath: String
    public let projectName: String
    public let worktreePath: String
    public let worktreeName: String
    public let hostName: String
    public let runtime: String
    /// Explicit request context also covers quiet and externally located worktrees.
    public let isCurrentProject: Bool?

    public init(address: String, projectPath: String, projectName: String, worktreePath: String,
                worktreeName: String, hostName: String, runtime: String, isCurrentProject: Bool? = nil) {
        self.address = address
        self.projectPath = projectPath
        self.projectName = projectName
        self.worktreePath = worktreePath
        self.worktreeName = worktreeName
        self.hostName = hostName
        self.runtime = runtime
        self.isCurrentProject = isCurrentProject
    }

    public static func matching(_ candidates: [Self], query: String, currentWorktreePath: String?) -> [Self] {
        let currentProject = candidates.first { $0.worktreePath == currentWorktreePath }?.projectPath
            ?? candidates.filter { candidate in
                guard let currentWorktreePath else { return false }
                return currentWorktreePath == candidate.projectPath
                    || currentWorktreePath.hasPrefix(candidate.projectPath + "/")
            }.max { $0.projectPath.count < $1.projectPath.count }?.projectPath
        let words = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        let exactQuery = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var seen = Set<String>()
        let matches: [(candidate: Self, exact: Bool, score: Int)] = candidates.compactMap { candidate in
            guard seen.insert(candidate.id).inserted else { return nil }
            guard !words.isEmpty else { return (candidate, false, 0) }
            let name = normalized(candidate.worktreeName)
            let address = normalized(candidate.address)
            if name == exactQuery || address == exactQuery { return (candidate, true, 0) }
            let fields = [name, normalized(candidate.projectName), normalized(candidate.hostName),
                          normalized(candidate.runtime), address]
            var total = 0
            for word in words {
                guard let best = fields.compactMap({ fuzzyScore(word, in: $0) }).max() else { return nil }
                total += best
            }
            return (candidate, false, total)
        }
        return matches.sorted { leftMatch, rightMatch in
            let lhs = leftMatch.candidate
            let rhs = rightMatch.candidate
            let leftCurrent = lhs.isCurrentProject ?? (currentProject != nil && lhs.projectPath == currentProject)
            let rightCurrent = rhs.isCurrentProject ?? (currentProject != nil && rhs.projectPath == currentProject)
            if leftCurrent != rightCurrent { return leftCurrent }
            if leftMatch.exact != rightMatch.exact { return leftMatch.exact }
            if leftMatch.score != rightMatch.score { return leftMatch.score > rightMatch.score }
            let left = [lhs.hostName, lhs.projectName, lhs.worktreeName, lhs.runtime, lhs.address].joined(separator: "\u{0}")
            let right = [rhs.hostName, rhs.projectName, rhs.worktreeName, rhs.runtime, rhs.address].joined(separator: "\u{0}")
            return left.localizedStandardCompare(right) == .orderedAscending
        }.map(\.candidate)
    }

    private static func normalized(_ value: String) -> [Character] {
        Array(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
    }

    /// Ordered-character matching with bonuses for word starts and consecutive
    /// characters. Keep the best score for each ending position so an early,
    /// scattered match cannot hide a later compact one. O(query × field) time.
    private static func fuzzyScore(_ query: [Character], in text: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= text.count else { return nil }
        let missing = Int.min / 4
        var previous = [Int](repeating: missing, count: text.count)
        for (queryIndex, character) in query.enumerated() {
            var scores = [Int](repeating: missing, count: text.count)
            var gapBest = missing
            for index in text.indices {
                if index > 0 { gapBest = max(gapBest - 1, previous[index - 1] - 1) }
                guard text[index] == character else { continue }
                let boundary = index == 0 || !text[index - 1].isLetter && !text[index - 1].isNumber
                let bonus = boundary ? 12 : 0
                if queryIndex == 0 {
                    scores[index] = 16 + bonus - min(index, 16)
                } else if index > 0 {
                    let consecutive = previous[index - 1] > missing ? previous[index - 1] + 8 : missing
                    let best = max(gapBest, consecutive)
                    if best > missing { scores[index] = best + 16 + bonus }
                }
            }
            previous = scores
        }
        guard let best = previous.max(), best > missing else { return nil }
        return best
    }
}
