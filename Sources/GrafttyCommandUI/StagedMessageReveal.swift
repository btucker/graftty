import GrafttyProtocol

/// Scrolls an agent that a gallery tile just put on stage to a message
/// (CONTEXT-57.15) on GrafttyMobile, where a tile renders its own preview
/// surface: the tile's rows mean nothing on the staged terminal, so the jump
/// carries the message, and the staged terminal may not have mounted or
/// loaded that message yet.
@MainActor
public enum StagedMessageReveal {
    /// The message a rail jump to `row` points at.
    public static func eventID(forRow row: Int, in map: ScrollbackMap?) -> String? {
        map?.nearestMark(toRow: row)?.eventID
    }

    /// Calls `attempt` until it reveals the message, up to `attempts` times
    /// with `interval` between tries; false if it never does or the task is cancelled.
    public static func reveal(attempts: Int = 20, interval: Duration = .milliseconds(150),
                              sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                              _ attempt: () async -> Bool) async -> Bool {
        for index in 0..<attempts {
            if await attempt() { return true }
            guard index < attempts - 1 else { break }
            await sleep(interval)
            if Task.isCancelled { return false }
        }
        return false
    }
}
