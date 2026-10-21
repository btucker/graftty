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
        fetch: () async throws -> [WorktreePanes], reopen: (String) async throws -> Void,
        isCurrent: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) async throws -> (worktree: WorktreePanes, rows: [WorktreePanes]) {
        func checkCurrent() throws {
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
        for attempt in 0..<12 {
            try checkCurrent()
            guard let row = target(path, source: source, rows: rows) else { throw Failure.unavailable }
            if row.state == .running, row.layout?.leaves.isEmpty == false { return (row, rows) }
            guard attempt < 11 else { throw Failure.notReady }
            try await pause()
            try checkCurrent()
            rows = try await fetch()
        }
        throw Failure.notReady
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
