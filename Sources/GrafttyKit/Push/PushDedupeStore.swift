import Foundation

public final class PushDedupeStore: @unchecked Sendable {
    private var lastByWorktree: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    public func lastPushed(forWorktree path: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastByWorktree[path]
    }

    public func markPushed(worktree: String, attentionTimestamp: Date) {
        lock.lock(); defer { lock.unlock() }
        lastByWorktree[worktree] = attentionTimestamp
    }
}
