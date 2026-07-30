import Foundation
import GrafttyKit

enum CLIWorktreeCreationPolicy {
    static func validationError(agentRuntime: TeamHookRuntime?, teamsEnabled: Bool) -> String? {
        guard agentRuntime != nil, !teamsEnabled else { return nil }
        return "Agent Teams is disabled; enable it in Graftty Settings before using --agent"
    }

    /// An interim CLI revision put a prompt-file path inside a shell command
    /// and relinquished ownership as soon as the app acknowledged the async
    /// operation. The app cannot safely recover that path if Git later fails,
    /// so reject that exact loader family before mutating the worktree. The
    /// released base64 command and current structured prompt remain valid.
    static func obsoletePromptLoaderError(
        agentRuntime: TeamHookRuntime?,
        command: String?,
        agentPrompt: String?
    ) -> String? {
        guard agentRuntime != nil,
              agentPrompt == nil,
              let command,
              command.contains("_graftty_agent_prompt_file="),
              command.contains("/bin/rm -f \"$_graftty_agent_prompt_file\"") else {
            return nil
        }
        return "this request uses an obsolete agent prompt loader; use the graftty CLI bundled with the running app and retry"
    }

    /// New clients send the prompt separately so the app can stage it after
    /// accepting the request. A bare runtime command from an older client is
    /// upgraded to the same bootstrap path; the released client's base64
    /// prompt command remains untouched for wire compatibility.
    static func shouldStageAgentPrompt(
        agentRuntime: TeamHookRuntime?,
        command: String?,
        agentPrompt: String?
    ) -> Bool {
        guard let agentRuntime else { return false }
        return agentPrompt != nil || command == nil || command == agentRuntime.rawValue
    }
}

/// In-memory rendezvous between the fast local-socket request and the async
/// Git/surface work. Terminal results are retained briefly so a lost socket
/// response can be retried with the same operation ID.
@MainActor
final class CLIWorktreeCreationStore {
    private struct Record {
        var status: WorktreeCreateStatus
        var updatedAt: Date
        var stagedPromptFile: URL?
    }

    private var records: [String: Record] = [:]
    private let terminalRetention: TimeInterval

    init(terminalRetention: TimeInterval = 10 * 60) {
        self.terminalRetention = terminalRetention
    }

    func begin(
        worktreePath: String,
        messageAddress: String,
        stagedPromptFile: URL? = nil,
        operationID: String? = nil,
        now: Date = Date()
    ) -> WorktreeCreateStatus {
        prune(now: now)
        let operationID = operationID ?? UUID().uuidString.lowercased()
        if let existing = records[operationID]?.status {
            return existing
        }
        let status = WorktreeCreateStatus(
            operationID: operationID,
            state: .pending,
            worktreePath: worktreePath,
            messageAddress: messageAddress
        )
        records[status.operationID] = Record(
            status: status,
            updatedAt: now,
            stagedPromptFile: stagedPromptFile
        )
        return status
    }

    func markReady(operationID: String, now: Date = Date()) {
        // The backend accepted the loader bytes; its shell now owns removal.
        records[operationID]?.stagedPromptFile = nil
        transition(operationID: operationID, state: .ready, error: nil, now: now)
    }

    func markFailed(operationID: String, error: String, now: Date = Date()) {
        if let promptFile = records[operationID]?.stagedPromptFile {
            try? FileManager.default.removeItem(at: promptFile)
            records[operationID]?.stagedPromptFile = nil
        }
        transition(operationID: operationID, state: .failed, error: error, now: now)
    }

    func status(operationID: String, now: Date = Date()) -> WorktreeCreateStatus? {
        prune(now: now)
        return records[operationID]?.status
    }

    private func transition(
        operationID: String,
        state: WorktreeCreateState,
        error: String?,
        now: Date
    ) {
        guard let record = records[operationID] else { return }
        let prior = record.status
        records[operationID] = Record(
            status: WorktreeCreateStatus(
                operationID: operationID,
                state: state,
                worktreePath: prior.worktreePath,
                messageAddress: prior.messageAddress,
                error: error
            ),
            updatedAt: now,
            stagedPromptFile: record.stagedPromptFile
        )
    }

    private func prune(now: Date) {
        records = records.filter { _, record in
            record.status.state == .pending || now.timeIntervalSince(record.updatedAt) <= terminalRetention
        }
    }
}
