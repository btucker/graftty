import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read retained context and publish only what changed",
        subcommands: [ContextUpdate.self, ContextShow.self])
}

struct ContextUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Publish changed context groups or explicit attention")
    @Flag(name: .long, help: "Read JSON with optional purpose, now, decisions, historyEntry, attention, emoji, icon, or unchanged")
    var stdin = false

    func run() throws {
        guard stdin else { throw ValidationError("pass --stdin with a context update JSON object") }
        let recap = try Self.decodeUpdate(FileHandle.standardInput.readDataToEndOfFile())
        let worktree = try CLIEnv.resolveWorktree()
        let handoff = AttentionFileHandoff()
        guard let agentID = AttentionReportIdentity.currentAgentID(worktreePath: worktree)
            ?? AttentionReportIdentity.unmanagedAgent(environment: ProcessInfo.processInfo.environment)?.agentID else {
            throw ValidationError("an active agent session is required")
        }
        try Self.publish(recap, worktree: worktree, agentID: agentID, handoff: handoff)
    }

    static func publish(_ recap: AttentionRecap, worktree: String, agentID: String, handoff: AttentionFileHandoff) throws {
        let snapshot = try ContextShow.read(worktree: worktree, handoff: handoff)
        if snapshot.brief == nil && !(recap.contextUpdate?.purpose != nil && recap.contextUpdate?.now != nil) {
            // The host may consume initialization between the first read and the queue scan.
            let queued = try handoff.hasQueuedContextInitialization(worktree: worktree, agentID: agentID)
            guard try queued || ContextShow.read(worktree: worktree, handoff: handoff).brief != nil else {
                throw ValidationError("the first context update needs purpose (title and context) and now (summary and optional next)")
            }
        }
        try handoff.publish(recap, worktree: worktree, agentID: agentID)
    }

    static func decodeUpdate(_ data: Data) throws -> AttentionRecap {
        let allowed: Set<String> = ["purpose", "now", "decisions", "historyEntry", "attention", "unchanged",
                                    "emoji", "emojiAlternatives", "icon", "iconDescription"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("expected a context update JSON object")
        }
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ValidationError("unknown context update field: \(unknown)")
        }
        var update = try JSONDecoder().decode(WorktreeContextUpdate.self, from: data)
        update.receiptID = UUID()
        if let icon = update.icon {
            do { update.icon = try WorktreeDrawingSVG.validate(icon) } catch {
                throw ValidationError("the worktree drawing in \"icon\" was rejected: \(error)")
            }
        }
        guard update.isValid else {
            throw ValidationError("supply changed context groups, an ask (question and optional background/options), a notice (message), or unchanged: true by itself; fields must be brief and valid")
        }
        return AttentionRecap(update: update)
    }
}

struct ContextShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Read the current host's retained context")
    @Flag(name: .long, help: "Print the retained context snapshot as JSON")
    var json = false

    func run() throws {
        let snapshot = try Self.read(worktree: CLIEnv.resolveWorktree(), handoff: AttentionFileHandoff())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if json {
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } else if let brief = snapshot.brief {
            print(brief.title)
            if let context = brief.context { print(context) }
            print(brief.completed)
            if !brief.next.isEmpty { print("Next: \(brief.next)") }
            for decision in brief.decisions { print("Decision: \(decision)") }
        } else {
            print("No context yet. The first update needs purpose and now.")
        }
    }

    static func read(worktree: String, handoff: AttentionFileHandoff) throws -> WorktreeContextSnapshot {
        do { return try handoff.context(worktree: worktree) } catch {
            throw ValidationError("the owning host has not published context-update support; relaunch the updated Graftty app and start a turn, then retry")
        }
    }
}
