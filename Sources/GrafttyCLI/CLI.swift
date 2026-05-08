import ArgumentParser
import Foundation
import GrafttyKit

@main
struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI",
        subcommands: [Notify.self, Pane.self, Team.self, InternalGroup.self]
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
        subcommands: [PaneList.self, PaneAdd.self, PaneClose.self, PaneShow.self]
    )
}

struct PaneList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List panes in a worktree (default: current)"
    )

    @Argument(help: "Worktree name (defaults to current worktree)")
    var address: String?

    func run() throws {
        let (path, paneID) = try CLIEnv.resolveAddress(address)
        if paneID != nil {
            CLIEnv.printError("pane list takes a worktree name, not a pane id")
            throw ExitCode(1)
        }
        let response = try CLIEnv.sendRequest(.listPanes(path: path))
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
        case .paneShow:
            CLIEnv.printError("Unexpected pane_show response for list")
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
        abstract: "Add a new pane by splitting the focused pane in a worktree (default: current)"
    )

    @Argument(help: "Worktree name (defaults to current worktree)")
    var address: String?

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
        let (path, paneID) = try CLIEnv.resolveAddress(address)
        if paneID != nil {
            CLIEnv.printError("pane add takes a worktree name, not a pane id")
            throw ExitCode(1)
        }
        let dir = PaneSplit(rawValue: direction)!
        let response = try CLIEnv.sendRequest(.addPane(path: path, direction: dir, command: command))
        try CLIEnv.expectOk(response)
    }
}

struct PaneClose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pane by its 1-based ID as shown by `pane list`"
    )

    @Argument(help: "Pane address: '<id>' or '<worktree>:<id>'")
    var address: String

    func run() throws {
        let (path, paneID) = try CLIEnv.resolveAddress(address)
        guard let id = paneID else {
            CLIEnv.printError("pane close requires a pane id (e.g., 'graftty pane close 2' or 'graftty pane close drag-files:2')")
            throw ExitCode(1)
        }
        let response = try CLIEnv.sendRequest(.closePane(path: path, index: id))
        try CLIEnv.expectOk(response)
    }
}

struct PaneShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the last lines of a pane's terminal output"
    )

    @Argument(help: "Pane address: omit, '<id>', '<worktree>', or '<worktree>:<id>'")
    var address: String?

    @Option(name: .long, help: "Number of trailing lines to print (default 100)")
    var lines: Int = 100

    func run() throws {
        let exit = PaneShowDispatcher.run(
            address: address,
            lines: lines,
            transport: SocketTransportClient.shared
        )
        if exit != 0 { throw ExitCode(exit) }
    }
}

/// `ATTN-1.18 / ATTN-1.19 / ATTN-1.22`: Resolve the address, disambiguate
/// the pane (auto-targeting when there's exactly one), then dispatch
/// `showPane` and surface either the scrollback or a copy-pasteable
/// error. Extracted from `PaneShow.run()` so tests can drive it via
/// stub seams without spinning up the app or opening a socket.
enum PaneShowDispatcher {
    static func run(
        address: String?,
        lines: Int,
        transport: SocketTransport,
        stdout: TextSink = StandardOutSink(),
        stderr: TextSink = StandardErrSink(),
        stateDirectory: URL = AppState.defaultDirectory
    ) -> Int32 {
        let resolved: (path: String, paneID: Int?)
        do {
            resolved = try CLIEnv.resolveAddress(address, stderr: stderr, stateDirectory: stateDirectory)
        } catch {
            return 1
        }

        let paneID: Int
        if let id = resolved.paneID {
            paneID = id
        } else {
            switch transport.send(.listPanes(path: resolved.path)) {
            case .paneList(let panes) where panes.count == 1:
                paneID = panes[0].id
            case .paneList(let panes):
                stderr.write(formatAmbiguityHint(verb: "show", address: address, panes: panes))
                return 1
            case .error(let msg):
                stderr.write("graftty: \(msg)\n")
                return 1
            default:
                stderr.write("graftty: unexpected response from list\n")
                return 1
            }
        }

        switch transport.send(.showPane(path: resolved.path, index: paneID, lines: lines)) {
        case .paneShow(let body):
            stdout.write(body)
            return 0
        case .error(let msg):
            stderr.write("graftty: \(msg)\n")
            return 1
        default:
            stderr.write("graftty: unexpected response\n")
            return 1
        }
    }
}

/// `ATTN-1.19 / ATTN-1.22`: format the multi-pane disambiguation message
/// shown when a bare-worktree `pane show` / `pane send` lands on a
/// worktree with >1 panes. Includes a literal copy-pasteable next-step
/// invocation: when the caller passed a `<wt>` address, show
/// `graftty pane <verb> <wt>:<id>`; when they omitted the address (PWD
/// resolution), show the shorter `graftty pane <verb> <id>` form they
/// should use instead.
func formatAmbiguityHint(verb: String, address: String?, panes: [PaneInfo]) -> String {
    let header: String
    let nextStep: String
    if let address {
        header = "graftty: '\(address)' has \(panes.count) panes — specify a pane:"
        nextStep = "Use 'graftty pane \(verb) \(address):<id>' to target one."
    } else {
        header = "graftty: current worktree has \(panes.count) panes — specify a pane:"
        nextStep = "Use 'graftty pane \(verb) <id>' to target one."
    }
    var out = header + "\n"
    for p in panes { out += "  " + p.formattedLine() + "\n" }
    out += nextStep + "\n"
    return out
}

// MARK: - Test seams (ATTN-1.18 / ATTN-1.19 / ATTN-1.22)

/// Test seam for stderr/stdout output from CLI commands. Production
/// binds to `StandardErrSink` / `StandardOutSink`; tests inject
/// capturing implementations to assert on the rendered text without
/// polluting the test runner's output.
protocol TextSink {
    func write(_ text: String)
}

struct StandardOutSink: TextSink {
    func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
}

struct StandardErrSink: TextSink {
    func write(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
}

/// Test seam for socket round-trips. Production binds to a thin wrapper
/// over `SocketClient.sendExpectingResponse` (errors surface as
/// `.error(description)` so the dispatcher renders them uniformly);
/// tests inject stubs that return canned responses without opening a
/// socket. Kept on `PaneShowDispatcher` / `PaneSendDispatcher` so each
/// dispatch is wholly stub-able from the tests.
protocol SocketTransport {
    func send(_ message: NotificationMessage) -> ResponseMessage
}

struct SocketTransportClient: SocketTransport {
    static let shared = SocketTransportClient()
    func send(_ message: NotificationMessage) -> ResponseMessage {
        do { return try SocketClient.sendExpectingResponse(message) }
        catch let e as CLIError { return .error(e.description) }
        catch { return .error("\(error)") }
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
        case .paneShow:
            printError("Unexpected pane_show response")
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

    /// `ATTN-1.17`: resolve the optional `<addr>` positional shared by
    /// every `graftty pane *` subcommand to a `(worktree path, optional
    /// pane id)`. Empty / `<id>` forms resolve via the current PWD just
    /// like `resolveWorktree()`; `<wt>` / `<wt>:<id>` forms look up the
    /// worktree by sanitized branch name in the persisted state. An
    /// unknown name or unparseable input writes a stderr error via the
    /// injected sink and throws `ExitCode(1)`.
    ///
    /// `ATTN-1.22`: the missing-current-worktree, unknown-worktree, and
    /// invalid-address branches all surface a copy-pasteable next-step
    /// hint so an agent that hits the error knows the literal command
    /// to retry with.
    static func resolveAddress(
        _ raw: String?,
        stderr: TextSink = StandardErrSink(),
        stateDirectory: URL = AppState.defaultDirectory
    ) throws -> (path: String, paneID: Int?) {
        switch PaneAddress.parse(raw) {
        case .currentWorktreeAnyPane:
            return (try resolveCurrentWorktreeForPaneCommand(stderr: stderr), nil)
        case .currentWorktreeID(let id):
            return (try resolveCurrentWorktreeForPaneCommand(stderr: stderr), id)
        case .namedWorktreeAnyPane(let name):
            return (try resolveNamedWorktree(name, stderr: stderr, stateDirectory: stateDirectory), nil)
        case .namedWorktreeID(let name, let id):
            return (try resolveNamedWorktree(name, stderr: stderr, stateDirectory: stateDirectory), id)
        case .invalid(let value):
            stderr.write("graftty: invalid pane address '\(value)'. Examples: '2', 'drag-files', 'drag-files:1'.\n")
            throw ExitCode(1)
        }
    }

    /// `ATTN-1.22`: PWD-resolution failure on a `pane *` command needs
    /// the longer next-step hint so the agent can fix it without reading
    /// the docs. The bare `resolveWorktree()` (used by `notify`) keeps
    /// its short historical message.
    private static func resolveCurrentWorktreeForPaneCommand(stderr: TextSink) throws -> String {
        do {
            return try WorktreeResolver.resolve()
        } catch {
            stderr.write("graftty: not inside a tracked worktree; pass <wt> or cd into one. Run 'graftty team list' to see registered worktrees.\n")
            throw ExitCode(1)
        }
    }

    private static func resolveNamedWorktree(
        _ name: String,
        stderr: TextSink,
        stateDirectory: URL
    ) throws -> String {
        guard let path = WorktreeResolver.resolveWorktreeName(name, stateDirectory: stateDirectory) else {
            stderr.write("graftty: unknown worktree '\(name)'. Run 'graftty team list' to see registered worktrees.\n")
            throw ExitCode(1)
        }
        return path
    }
}
