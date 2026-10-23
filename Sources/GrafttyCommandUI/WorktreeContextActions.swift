import GrafttyProtocol
import SwiftUI

/// Context links use the current window's host-aware worktree selection.
public struct WorktreeContextActions {
    public let openWorktree: (String, WorktreePanes) -> Bool

    public init(openWorktree: @escaping (String, WorktreePanes) -> Bool) {
        self.openWorktree = openWorktree
    }

    /// A path from another Mac must never select a same-named local worktree.
    public static func target(_ path: String, source: WorktreePanes, rows: [WorktreePanes]) -> WorktreePanes? {
        let matches = rows.filter { $0.path == path && $0.origin?.deviceID == source.origin?.deviceID }
        guard matches.count == 1, let row = matches.first, row.state.hasOnDiskWorktree else { return nil }
        return row
    }

    public enum Failure: Error, Equatable { case unavailable, notReady }

    @MainActor public static func resolve(_ path: String, source: WorktreePanes,
        fetch: @MainActor () async throws -> [WorktreePanes], reopen: @MainActor (String) async throws -> Void,
        isCurrent: @MainActor () -> Bool,
        pause: @MainActor () async throws -> Void = WorktreeLayoutAwait.pauseBetweenSnapshots
    ) async throws -> (worktree: WorktreePanes, rows: [WorktreePanes]) {
        @MainActor func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        var rows = try await fetch()
        try checkCurrent()
        guard let original = target(path, source: source, rows: rows) else { throw Failure.unavailable }
        if original.state == .closed {
            try await reopen(original.path)
            try checkCurrent()
            rows = try await fetch()
        }
        let ready = try await WorktreeLayoutAwait.poll(rows: rows, fetch: fetch, checkCurrent: checkCurrent,
                                                       pause: pause) { rows -> (worktree: WorktreePanes, rows: [WorktreePanes])? in
            guard let row = target(path, source: source, rows: rows) else { throw Failure.unavailable }
            return row.state == .running && row.layout?.leaves.isEmpty == false ? (row, rows) : nil
        }
        guard let ready else { throw Failure.notReady }
        return ready
    }
}

private struct WorktreeContextActionsKey: EnvironmentKey {
    static let defaultValue: WorktreeContextActions? = nil
}

extension EnvironmentValues {
    public var worktreeContextActions: WorktreeContextActions? {
        get { self[WorktreeContextActionsKey.self] }
        set { self[WorktreeContextActionsKey.self] = newValue }
    }
}
