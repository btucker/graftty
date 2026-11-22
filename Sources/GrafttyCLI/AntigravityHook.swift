import Foundation
import GrafttyKit

/// Adapts the AGY hook contract to Graftty's provider-independent lifecycle.
/// https://antigravity.google/docs/hooks
struct AntigravityHook {
    let sessionID: String
    let workingDirectory: String?
    let prompt: String?
    let turnID: String?
    let fullyIdle: Bool

    init?(event: TeamHookEvent, payload: [String: Any]) {
        guard let sessionID = payload["conversationId"] as? String,
              UUID(uuidString: sessionID) != nil else { return nil }
        switch event {
        case .sessionStart:
            break
        case .userPromptSubmit:
            guard payload["invocationNum"] as? Int == 0 else { return nil }
        case .stop:
            guard payload["fullyIdle"] is Bool else { return nil }
        default:
            return nil
        }
        self.sessionID = sessionID
        let cwd = (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let workspace = (payload["workspacePaths"] as? [String])?.first(where: { !$0.isEmpty })
        workingDirectory = cwd ?? workspace
        prompt = payload["lastUserInput"] as? String
        turnID = (payload["executionNum"] as? Int).map { "execution:\($0)" }
        fullyIdle = payload["fullyIdle"] as? Bool ?? true
    }

    static func output(_ output: String, event: TeamHookEvent) -> String {
        if event == .stop { return #"{"decision":"allow"}"# }
        guard let body = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let hook = body["hookSpecificOutput"] as? [String: Any],
              let context = hook["additionalContext"] as? String,
              !context.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "injectSteps": [["systemMessage": ["systemMessage": context]]]
              ]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func register(worktree: String, pane: String, pid: Int32) {
        guard let resolved = TeamPresenceResolution.resolveTeamAndWorktree(worktreePath: worktree),
              let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) else { return }
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let teamID = TeamLookup.id(of: resolved.team)
        let existing = try? storage.read(teamID: teamID, worktree: worktree,
            runtime: .antigravity, paneSessionName: pane)
        let unchanged = existing?.runtimeSessionID == sessionID && existing?.pid == pid
            && existing?.processStartTimeMicroseconds == start
        // A bound server stays valid for the life of the process and conversation.
        // An unbound session probes again at each turn start. A process launched
        // without the wrapper has no credential, so its probe returns at once.
        let transport = (unchanged ? existing?.transport : nil) ?? AntigravityServerBinder().bind(
            pid: pid, conversationID: sessionID,
            token: ProcessInfo.processInfo.environment[AntigravityServerBinder.tokenEnvironmentKey])
        guard !unchanged || existing?.transport != transport else { return }
        // One file per pane is replaced when AGY switches conversations.
        try? storage.write(.init(teamID: teamID, worktree: worktree, runtime: .antigravity,
            paneSessionName: pane, pid: pid, processStartTimeMicroseconds: start,
            registeredAt: unchanged ? existing?.registeredAt ?? Date() : Date(),
            runtimeSessionID: sessionID, transport: transport))
    }

    static func providerPID(start: Int32 = ProcessInfo.processInfo.processIdentifier) -> Int32? {
        var pid = start
        for _ in 0..<16 {
            guard let parent = ProcessAncestryReader.entry(forPID: pid)?.parentPID, parent > 1 else { return nil }
            if let path = SleepProcessReader.executable(pid: parent),
               URL(fileURLWithPath: path).lastPathComponent == TeamHookRuntime.antigravity.executable { return parent }
            pid = parent
        }
        return nil
    }
}
