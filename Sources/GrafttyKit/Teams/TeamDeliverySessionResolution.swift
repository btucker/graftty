import Foundation

public enum TeamDeliverySessionResolution {
    public static func codexSessionNames(
        in worktree: String,
        records: [TeamPresenceRecord],
        isLiveSession: (String) -> Bool,
        isPIDAlive: (Int32) -> Bool = { TeamPresenceMonitor.kernelIsAlive($0) }
    ) -> [String] {
        var seen: Set<String> = []
        var sessions: [String] = []
        for record in records {
            guard record.worktree == worktree,
                  record.runtime == .codex,
                  let sessionName = record.paneSessionName,
                  isLiveSession(sessionName),
                  isPIDAlive(record.pid),
                  !seen.contains(sessionName) else {
                continue
            }
            seen.insert(sessionName)
            sessions.append(sessionName)
        }
        return sessions
    }

    public static func stopSessionName(
        runtime: String,
        paneSessionName: String?,
        isLiveSession: (String) -> Bool
    ) -> String? {
        guard runtime == TeamHookRuntime.codex.rawValue,
              let sessionName = paneSessionName,
              isLiveSession(sessionName) else {
            return nil
        }
        return sessionName
    }
}
