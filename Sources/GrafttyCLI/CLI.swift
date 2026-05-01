import ArgumentParser
import Foundation
import GrafttyKit

@main
struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI",
        subcommands: [Notify.self, Pane.self, Team.self]
    )
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an attention notification to Graftty")

    @Argument(help: "Notification text to display in the sidebar")
    var text: String?

    @Flag(name: .long, help: "Clear the attention notification")
    var clear: Bool = false

    @Option(name: .long, help: "Auto-clear the notification after N seconds")
    var clearAfter: Int?

    func validate() throws {
        let result = NotifyInputValidation.validate(text: text, clear: clear, clearAfter: clearAfter)
        if let message = result.message {
            throw ValidationError(message)
        }
    }

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let message: NotificationMessage
        if clear {
            message = .clear(path: worktreePath)
        } else {
            message = .notify(path: worktreePath, text: text!, clearAfter: clearAfter.map { TimeInterval($0) })
        }
        try CLIEnv.sendFireAndForget(message)
    }
}

struct Pane: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add, remove, or list panes in the current worktree",
        subcommands: [PaneList.self, PaneAdd.self, PaneClose.self]
    )
}

struct PaneList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List panes in the current worktree"
    )

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.listPanes(path: worktreePath))
        switch response {
        case .paneList(let panes):
            for pane in panes {
                print(pane.formattedLine())
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok:
            CLIEnv.printError("Unexpected ok response for list")
            throw ExitCode(1)
        case .teamList:
            CLIEnv.printError("Unexpected team_list response for list")
            throw ExitCode(1)
        case .teamHookOutput:
            CLIEnv.printError("Unexpected team_hook_output response for list")
            throw ExitCode(1)
        case .teamInbox:
            CLIEnv.printError("Unexpected team_inbox response for list")
            throw ExitCode(1)
        }
    }
}

struct PaneAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a new pane by splitting the focused pane in the current worktree"
    )

    @Option(name: .long, help: "Split direction: right (default), left, up, or down")
    var direction: String = "right"

    @Option(name: .long, help: "Optional command to run in the new pane (typed into the shell followed by Enter)")
    var command: String?

    func validate() throws {
        guard PaneSplit(rawValue: direction) != nil else {
            throw ValidationError("--direction must be one of: right, left, up, down")
        }
    }

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let dir = PaneSplit(rawValue: direction)!
        let response = try CLIEnv.sendRequest(.addPane(path: worktreePath, direction: dir, command: command))
        try CLIEnv.expectOk(response)
    }
}

struct PaneClose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pane by its 1-based ID as shown by `pane list`"
    )

    @Argument(help: "Pane ID from `graftty pane list`")
    var id: Int

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.closePane(path: worktreePath, index: id))
        try CLIEnv.expectOk(response)
    }
}

/// Small shared helpers used by every subcommand. Keeps each subcommand's
/// `run()` readable and avoids copy-pasting the error plumbing.
enum CLIEnv {
    static func resolveWorktree() throws -> String {
        do {
            return try WorktreeResolver.resolve()
        } catch {
            printError("Not inside a tracked worktree")
            throw ExitCode(1)
        }
    }

    static func sendFireAndForget(_ message: NotificationMessage) throws {
        do {
            try SocketClient.send(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        }
    }

    static func sendRequest(_ message: NotificationMessage) throws -> ResponseMessage {
        do {
            return try SocketClient.sendExpectingResponse(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        } catch {
            printError("Decode error: \(error)")
            throw ExitCode(1)
        }
    }

    static func expectOk(_ response: ResponseMessage) throws {
        switch response {
        case .ok:
            return
        case .error(let msg):
            printError(msg)
            throw ExitCode(1)
        case .paneList:
            printError("Unexpected pane_list response")
            throw ExitCode(1)
        case .teamList:
            printError("Unexpected team_list response")
            throw ExitCode(1)
        case .teamHookOutput:
            printError("Unexpected team_hook_output response")
            throw ExitCode(1)
        case .teamInbox:
            printError("Unexpected team_inbox response")
            throw ExitCode(1)
        }
    }

    static func printError(_ msg: String) {
        FileHandle.standardError.write(Data("graftty: \(msg)\n".utf8))
    }
}
