import Foundation

public enum CodexSessionLiveness {
    public static func poll(
        records: [CodexAppServerSessionRecord],
        client: any CodexAppServerClienting,
        processStartTime: @Sendable (Int32) -> Int64? = { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
    ) async -> [String: [String: AgentLiveness]] {
        await withTaskGroup(of: (String, String, AgentLiveness?).self) { group in
            for record in records {
                guard let thread = record.threadID, !thread.isEmpty,
                      let start = record.appServerProcessStartTimeMicroseconds,
                      processStartTime(record.appServerPID) == start else { continue }
                group.addTask {
                    let activity = await client.turnLiveness(binaryPath: record.realBinaryPath,
                        socketPath: record.socketPath, expectedCWD: record.worktree,
                        target: .init(threadID: thread, activeTurnID: record.activeTurnID))
                    return (record.paneSessionName, "codex:" + thread, activity)
                }
            }
            var result: [String: [String: AgentLiveness]] = [:]
            for await (pane, session, activity) in group {
                if let activity { result[pane, default: [:]][session] = activity }
            }
            return result
        }
    }
}
