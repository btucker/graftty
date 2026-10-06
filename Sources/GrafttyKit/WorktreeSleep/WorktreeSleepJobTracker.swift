import Foundation

/// Background job evidence survives reparenting. A missing scan or an
/// unreadable previously observed identity keeps the worktree awake.
public final class WorktreeSleepJobTracker {
    private var observed: [String: Set<SleepProcessIdentity>] = [:]
    public init() {}

    public func observe(path: String, descendants: [SleepProcessIdentity]?, isAlive: (SleepProcessIdentity) -> Bool?) -> Bool {
        guard let descendants else { return false }
        observed[path, default: []].formUnion(descendants)
        observed[path] = observed[path, default: []].filter { isAlive($0) != false }
        return descendants.isEmpty && observed[path, default: []].isEmpty
    }
}
