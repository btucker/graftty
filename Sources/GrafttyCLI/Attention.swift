import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Attention: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report what a stopped agent needs attention for",
        subcommands: [AttentionReport.self, AttentionDirectory.self]
    )
}

struct AttentionDirectory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "directory",
        abstract: "Print the effective Attention handoff directory"
    )

    func run() { print(AttentionFileHandoff.defaultRootDirectory.path) }
}

struct AttentionReport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Publish an agent recap before finishing its turn"
    )

    @Flag(name: .long, help: "Read recap JSON with title, completed, next, emoji, and optional context, need, catchUp (what the user needs to answer need), emojiAlternatives, icon (an SVG worktree drawing), iconDescription (a few words naming the drawing), purposeChanged, historyEntry (headline and optional detail), legacy checkpoint, and decisions")
    var stdin = false

    func run() throws {
        guard stdin else { throw ValidationError("pass --stdin with a recap JSON object") }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let recap = try Self.decodeRecap(data)
        let worktree = try CLIEnv.resolveWorktree()
        let handoff = AttentionFileHandoff()
        guard let agentID = AttentionReportIdentity.currentAgentID(worktreePath: worktree)
            ?? AttentionReportIdentity.unmanagedAgent(environment: ProcessInfo.processInfo.environment)?.agentID else {
            throw ValidationError("an active agent session is required")
        }
        try handoff.publish(recap, worktree: worktree, agentID: agentID)
    }

    static func decodeRecap(_ data: Data) throws -> AttentionRecap {
        var recap: AttentionRecap
        do {
            recap = try JSONDecoder().decode(AttentionRecap.self, from: data)
        } catch {
            throw ValidationError("expected recap JSON with title, completed, next, emoji, and optional context, need, catchUp, emojiAlternatives, icon, iconDescription, purposeChanged, historyEntry (headline and optional detail), legacy checkpoint, and decisions")
        }
        // Checked first so an oversized drawing reports its own reason, not the brief-text error.
        if let icon = recap.icon {
            do { recap.icon = try WorktreeDrawingSVG.validate(icon) } catch {
                throw ValidationError("the worktree drawing in \"icon\" was rejected: \(error)")
            }
        }
        guard recap.isValid else {
            throw ValidationError("recap fields must be brief text, and emoji choices must be single glyphs")
        }
        guard recap.emoji != nil else {
            throw ValidationError("include a task-specific \"emoji\" in the recap JSON and retry; optionally add up to three distinct \"emojiAlternatives\". Older cached skills may omit this requirement.")
        }
        return recap
    }
}
