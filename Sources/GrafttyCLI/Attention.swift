import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Attention: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report what a stopped agent needs attention for",
        subcommands: [AttentionReport.self]
    )
}

struct AttentionReport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Stage an agent recap for its next stopped turn"
    )

    @Flag(name: .long, help: "Read recap JSON with title, completed, next, and optional context, need, emoji, and emojiAlternatives")
    var stdin = false

    func run() throws {
        guard stdin else { throw ValidationError("pass --stdin with a recap JSON object") }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let recap: AttentionRecap
        do {
            recap = try JSONDecoder().decode(AttentionRecap.self, from: data)
        } catch {
            throw ValidationError("expected recap JSON with title, completed, next, and optional context, need, and emoji")
        }
        guard recap.isValid else {
            throw ValidationError("recap fields must be brief text, and emoji choices must be single glyphs")
        }
        let worktree = try CLIEnv.resolveWorktree()
        let handoff = AttentionFileHandoff()
        if let agentID = AttentionReportIdentity.currentAgentID(worktreePath: worktree) {
            try handoff.stage(recap, worktree: worktree, agentID: agentID)
        } else if let agent = AttentionReportIdentity.unmanagedAgent(
            environment: ProcessInfo.processInfo.environment
        ) {
            try handoff.publishUnmanaged(
                recap, worktree: worktree, agentID: agent.agentID,
                runtime: agent.runtime, sessionID: agent.sessionID,
                paneSessionName: TeamRegisterPaneResolver.paneSessionName(
                    env: ProcessInfo.processInfo.environment
                )
            )
        } else {
            throw ValidationError("an active agent session is required")
        }
    }
}
