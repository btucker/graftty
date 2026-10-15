import ArgumentParser
import Foundation
import GrafttyKit

struct WorktreePin: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Keep a worktree as a durable role in Pinned Agents",
        discussion: """
        With no target or with '.', pin the calling worktree. Supply a tracked
        worktree name or absolute path to pin another local agent's worktree.
        Pinning preserves the workspace and does not write GRAFTTY.md files.
        Pinned worktrees stay after their PR or MR merges or closes, without
        an automatic deletion offer. The default-branch checkout is always pinned.
        """
    )

    @Argument(help: "Tracked local worktree name, absolute path, or . (default: current worktree)")
    var target: String?

    func run() throws {
        try WorktreePinCommand.run(target: target, isPinned: true)
    }
}

struct WorktreeUnpin: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpin",
        abstract: "Return a pinned agent's worktree to the temporary list",
        discussion: "Unpinning preserves the workspace and its role instructions. The default-branch checkout cannot be unpinned."
    )

    @Argument(help: "Tracked local worktree name, absolute path, or . (default: current worktree)")
    var target: String?

    func run() throws {
        try WorktreePinCommand.run(target: target, isPinned: false)
    }
}

enum WorktreePinCommand {
    static func run(
        target: String?, isPinned: Bool,
        stateDirectory: URL = AppState.defaultDirectory,
        resolveCurrent: () throws -> String = { try CLIEnv.resolveWorktree() },
        send: (NotificationMessage) throws -> ResponseMessage = { try SocketClient.sendExpectingResponse($0) },
        writeLine: (String) -> Void = { print($0) }
    ) throws {
        let path: String
        if let name = target, name != "." {
            switch WorktreeResolver.resolveWorktreeName(name, stateDirectory: stateDirectory) {
            case .found(let resolved): path = resolved
            case .notFound:
                throw ValidationError("unknown worktree '\(name)'; use a tracked path or a name from graftty team list")
            case .ambiguous(let paths):
                throw ValidationError("ambiguous worktree '\(name)'; use an absolute path:\n" + paths.joined(separator: "\n"))
            }
        } else {
            path = try resolveCurrent()
        }

        try WorktreeCapability.require(
            .worktreePinCapability,
            unsupportedMessage: "the running Graftty app does not support worktree pinning; relaunch the updated app, then retry",
            verificationMessage: "could not verify worktree pinning support; relaunch the updated Graftty app, then retry",
            send: send
        )
        let response = try CLIEnv.sendRequest(
            .setWorktreePinned(worktreePath: path, isPinned: isPinned), using: send, writeError: CLIEnv.printError
        )
        try CLIEnv.expectOk(response)
        let action = isPinned ? "pinned" : "unpinned"
        writeLine("\(action) worktree=\(WorktreeAgentLaunchCommand.shellLiteral(path))")
    }
}
