import GrafttyProtocol

/// Scrolls an agent that a gallery tile just put on stage to a message
/// (CONTEXT-57.15). The jump carries the message rather than a row, because
/// a mobile tile renders its own preview surface and staging can resize a
/// terminal, and the staged terminal may not have mounted or loaded it yet.
@MainActor
public enum StagedMessageReveal {
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
