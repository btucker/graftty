import Foundation

/// Region assignments belong to worktree paths, not their current list positions.
enum WorktreeMapRegionIdentity {
    static let revision = 5

    static func assign(paths: [String], preserving existing: [String: Int]) -> [String: Int] {
        let paths = Set(paths).sorted()
        var result: [String: Int] = [:]
        var used = Set<Int>()
        for path in paths {
            if let id = existing[path], id >= 0, id < 1_000_000, used.insert(id).inserted { result[path] = id }
        }
        var next = 0
        for path in paths where result[path] == nil {
            while used.contains(next) { next += 1 }
            result[path] = next
            used.insert(next)
        }
        return result
    }

}
