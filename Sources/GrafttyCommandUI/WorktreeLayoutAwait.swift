import GrafttyProtocol

/// A reopened worktree publishes its running pane layout asynchronously, so
/// every surface that opens a closed worktree polls fresh snapshots for it.
/// One loop keeps their attempt count, spacing and supersession checks equal;
/// each caller still decides what "ready" means for its row.
public enum WorktreeLayoutAwait {
    public static let attempts = 12

    /// The spacing between snapshots unless a caller supplies its own.
    public static func pauseBetweenSnapshots() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Checks `rows`, then up to `attempts - 1` fresh snapshots `pause` apart,
    /// and returns the first non-nil `ready` result, or nil when the layout
    /// never arrives. `checkCurrent` runs before every check and fetch so a
    /// superseded request stops; `ready` may throw to end the poll early.
    @MainActor public static func poll<Result>(
        rows: [WorktreePanes],
        fetch: @MainActor () async throws -> [WorktreePanes],
        checkCurrent: @MainActor () throws -> Void,
        pause: @MainActor () async throws -> Void = WorktreeLayoutAwait.pauseBetweenSnapshots,
        ready: @MainActor ([WorktreePanes]) throws -> Result?
    ) async throws -> Result? {
        var rows = rows
        for attempt in 0..<attempts {
            try checkCurrent()
            if let result = try ready(rows) { return result }
            guard attempt < attempts - 1 else { break }
            try await pause()
            try checkCurrent()
            rows = try await fetch()
        }
        return nil
    }
}
