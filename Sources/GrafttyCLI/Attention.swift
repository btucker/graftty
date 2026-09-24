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

    @Flag(name: .long, help: "Read a JSON object with title, completed, next, and optional context and need from standard input")
    var stdin = false

    func run() throws {
        guard stdin else { throw ValidationError("pass --stdin with a recap JSON object") }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let recap: AttentionRecap
        do {
            recap = try JSONDecoder().decode(AttentionRecap.self, from: data)
        } catch {
            throw ValidationError("expected JSON with title, completed, next, and optional context and need")
        }
        guard recap.isValid else {
            throw ValidationError("recap fields must be brief, nonempty text")
        }
        let worktree = try CLIEnv.resolveWorktree()
        guard let agentID = AttentionReportIdentity.currentAgentID(worktreePath: worktree) else {
            throw ValidationError("an active Graftty agent session is required")
        }
        try AttentionFileHandoff().stage(recap, worktree: worktree, agentID: agentID)
    }
}
