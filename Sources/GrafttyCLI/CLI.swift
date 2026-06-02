import ArgumentParser
import Foundation
import GrafttyKit

/// Top-level entry point that intercepts swift-argument-parser errors,
/// walks the registered command tree against `CommandLine.arguments`
/// to find the level at which parsing failed, and appends a
/// `Did you mean '<closest>'?` hint to the rendered error before
/// exiting. Replaces a bare `@main` on the root `GrafttyCLI` so we
/// control the error path; the happy path still parses and runs
/// through swift-argument-parser unchanged.
@main
enum GrafttyCLIEntryPoint {
    static func main() {
        do {
            var command = try GrafttyCLI.parseAsRoot()
            try command.run()
        } catch {
            let baseMessage = GrafttyCLI.fullMessage(for: error)
            let stuck = unknownSubcommandLevel(args: CommandLine.arguments)
            let enriched: String
            if let stuck {
                enriched = GrafttyCLIErrorEnricher.enrich(
                    baseMessage,
                    attemptedSubcommand: stuck.token,
                    knownAtThatLevel: stuck.candidates
                )
            } else {
                enriched = baseMessage
            }
            // Avoid swift-argument-parser's `exit(withError:)` printing the
            // same message itself — write our enriched copy to stderr (or
            // stdout for clean-exit help paths), then exit with the parser's
            // computed exit code.
            let exitCode = GrafttyCLI.exitCode(for: error)
            if !enriched.isEmpty {
                if exitCode == .success {
                    FileHandle.standardOutput.write(Data((enriched + "\n").utf8))
                } else {
                    FileHandle.standardError.write(Data((enriched + "\n").utf8))
                }
            }
            exit(exitCode.rawValue)
        }
    }
}

struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI",
        subcommands: [Notify.self, Pane.self, Team.self, InternalGroup.self]
    )
}

/// Append a "Did you mean '<closest>'?" hint when the attempted
/// subcommand is within Levenshtein distance 2 of one of the
/// `knownAtThatLevel` candidates. Pulled out of the wrapper so unit
/// tests can drive it without invoking swift-argument-parser.
public enum GrafttyCLIErrorEnricher {
    public static func enrich(
        _ errorText: String,
        attemptedSubcommand: String,
        knownAtThatLevel: [String]
    ) -> String {
        guard let closest = SubcommandSuggestions.suggest(attemptedSubcommand, from: knownAtThatLevel) else {
            return errorText
        }
        return errorText + "\nDid you mean '\(closest)'?"
    }
}

/// Walk `CommandLine.arguments` against the root subcommand tree to
/// find the first user token that doesn't match a registered subcommand
/// at its level. Returns the unknown token together with the valid
/// candidate names at that level, or nil when parsing failed for some
/// other reason (bad option, missing value, the typo lands at a leaf
/// with no further subcommands, etc.) — cases where a "did you mean"
/// hint would be misleading.
private func unknownSubcommandLevel(args: [String]) -> (token: String, candidates: [String])? {
    var currentLevel: [any ParsableCommand.Type] = GrafttyCLI.configuration.subcommands
    // args[0] is the binary name; skip it.
    for arg in args.dropFirst() {
        // Flags/options aren't subcommand candidates; stop scanning.
        if arg.hasPrefix("-") { return nil }
        if currentLevel.isEmpty { return nil }
        if let child = currentLevel.first(where: { commandName(for: $0) == arg }) {
            currentLevel = child.configuration.subcommands
            continue
        }
        return (arg, currentLevel.map { commandName(for: $0) })
    }
    return nil
}

/// Helper to derive the command name even when `commandName` is nil
/// (swift-argument-parser falls back to the type name lowercased).
private func commandName(for type: any ParsableCommand.Type) -> String {
    type.configuration.commandName ?? "\(type)".lowercased()
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an attention notification to Graftty")

    @Argument(help: "Notification text to display in the sidebar")
    var text: String?

    @Flag(name: .long, help: "Clear the attention notification")
    var clear: Bool = false

    @Option(name: .long, help: "Auto-clear the notification after N seconds")
    var clearAfter: Int?

    @Option(name: .long, help: "Target a specific pane by its zmx session name")
    var session: String?

    @Option(name: .long, help: "Target a specific worktree by name")
    var worktree: String?

    func validate() throws {
        let result = NotifyInputValidation.validate(text: text, clear: clear, clearAfter: clearAfter)
        if let message = result.message {
            throw ValidationError(message)
        }
        if session != nil && worktree != nil {
            throw ValidationError("--session and --worktree are mutually exclusive")
        }
    }

    func run() throws {
        let message: NotificationMessage
        if clear {
            let path = try resolveTargetWorktreePath()
            let pane = NotifyTarget.paneSessionName(
                session: session, worktree: worktree, env: ProcessInfo.processInfo.environment)
            message = .clear(path: path, paneSessionName: pane)
        } else {
            message = try NotifyTarget.message(
                text: text!, session: session, worktree: worktree,
                env: ProcessInfo.processInfo.environment,
                resolveWorktreePath: { try resolveTargetWorktreePath() },
                clearAfter: clearAfter.map { TimeInterval($0) })
        }
        try CLIEnv.sendFireAndForget(message)
    }

    private func resolveTargetWorktreePath() throws -> String {
        if let worktree,
           let path = WorktreeResolver.resolveWorktreeName(worktree, stateDirectory: AppState.defaultDirectory) {
            return path
        }
        return try CLIEnv.resolveWorktree()
    }
}

struct Pane: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add, remove, list, show, or send to panes — in any worktree",
        discussion: """
        Address forms (shared by every subcommand):
          (omitted)         current worktree's only pane
          <id>              current worktree, pane <id>
          <worktree>        named worktree's only pane (errors if multiple)
          <worktree>:<id>   named worktree, pane <id>

        Worktree names match what `graftty team list` prints.
        """,
        subcommands: [PaneList.self, PaneAdd.self, PaneClose.self, PaneShow.self, PaneSend.self]
    )
}

struct PaneList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List panes in a worktree (default: current)",
        discussion: """
        Examples:
          graftty pane list                     # this worktree's panes
          graftty pane list drag-files          # drag-files' panes
        """
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
        abstract: "Add a new pane by splitting the focused pane in a worktree (default: current)",
        discussion: """
        Examples:
          graftty pane add                                    # split this worktree
          graftty pane add drag-files                         # split drag-files
          graftty pane add drag-files --command "pnpm test"   # split + run command
          graftty pane add --direction down                   # vertical split below
        """
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
        abstract: "Close a pane by its 1-based ID as shown by `pane list`",
        discussion: """
        Examples:
          graftty pane close 2                  # this worktree, pane 2
          graftty pane close drag-files:1       # drag-files, pane 1

        Use `graftty pane list` to find ids.
        """
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
        abstract: "Print the last lines of a pane's terminal output",
        discussion: """
        Examples:
          graftty pane show                     # this worktree's only pane
          graftty pane show 2                   # this worktree, pane 2
          graftty pane show drag-files          # drag-files' only pane (errors if >1)
          graftty pane show drag-files:1        # drag-files, pane 1
          graftty pane show drag-files:1 --lines 500
        """
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

enum PaneShowDispatcher {
    static func run(
        address: String?,
        lines: Int,
        transport: SocketTransport,
        stdout: TextSink = StandardOutSink(),
        stderr: TextSink = StandardErrSink(),
        stateDirectory: URL = AppState.defaultDirectory
    ) -> Int32 {
        guard let resolved = resolveTargetPane(
            verb: .show, address: address, transport: transport,
            stderr: stderr, stateDirectory: stateDirectory
        ) else {
            return 1
        }
        switch transport.send(.showPane(path: resolved.path, index: resolved.paneID, lines: lines)) {
        case .paneShow(let body):
            stdout.write(body)
            return 0
        case .error(let msg):
            emit(msg, to: stderr)
            return 1
        default:
            emit("unexpected response", to: stderr)
            return 1
        }
    }
}

struct PaneSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Inject text into a pane's PTY",
        discussion: """
        Bytes you pass go straight to the pane's PTY — there is no inbox or
        consent layer; whatever process is reading that pane's stdin will
        receive them as if you had typed at the keyboard. By default, a
        Return key event is synthesized after the text so the pane's shell
        (or TUI consumer like Codex/Claude in raw mode) treats the input
        as committed. Use --no-enter to suppress.

        For cooperative messaging where the receiving agent decides what
        to do, prefer 'graftty team send' instead.
        """
    )

    @Argument(help: "Pane address: omit, '<id>', '<worktree>', or '<worktree>:<id>'")
    var address: String?

    @Argument(help: "Text to inject into the pane")
    var text: String

    @Flag(name: .long, help: "Skip the trailing Return after the text")
    var noEnter: Bool = false

    func run() throws {
        let exit = PaneSendDispatcher.run(
            address: address,
            text: text,
            pressEnter: !noEnter,
            transport: SocketTransportClient.shared,
            stderr: StandardErrSink()
        )
        if exit != 0 { throw ExitCode(exit) }
    }
}

enum PaneSendDispatcher {
    static func run(
        address: String?,
        text: String,
        pressEnter: Bool,
        transport: SocketTransport,
        stderr: TextSink = StandardErrSink(),
        stateDirectory: URL = AppState.defaultDirectory
    ) -> Int32 {
        guard let resolved = resolveTargetPane(
            verb: .send, address: address, transport: transport,
            stderr: stderr, stateDirectory: stateDirectory
        ) else {
            return 1
        }
        switch transport.send(.sendPane(
            path: resolved.path, index: resolved.paneID, text: text, pressEnter: pressEnter
        )) {
        case .ok:
            return 0
        case .error(let msg):
            emit(msg, to: stderr)
            return 1
        default:
            emit("unexpected response", to: stderr)
            return 1
        }
    }
}

/// One of the verbs that share the `<addr>` grammar and multi-pane
/// disambiguation. Carries its CLI keyword for use in error hints.
enum PaneVerb: String {
    case show, send
}

/// Resolve `address` to a concrete `(path, paneID)` for `pane show` /
/// `pane send`. Returns nil after writing a copy-pasteable error to
/// stderr when the address is unknown, ambiguous, or invalid; on
/// ambiguity, prints the worktree's `pane list` followed by a
/// `graftty pane <verb> <wt>:<id>` next-step hint.
private func resolveTargetPane(
    verb: PaneVerb,
    address: String?,
    transport: SocketTransport,
    stderr: TextSink,
    stateDirectory: URL
) -> (path: String, paneID: Int)? {
    let resolved: (path: String, paneID: Int?)
    do {
        resolved = try CLIEnv.resolveAddress(address, stderr: stderr, stateDirectory: stateDirectory)
    } catch {
        return nil
    }
    if let id = resolved.paneID {
        return (resolved.path, id)
    }
    switch transport.send(.listPanes(path: resolved.path)) {
    case .paneList(let panes) where panes.count == 1:
        return (resolved.path, panes[0].id)
    case .paneList(let panes):
        stderr.write(formatAmbiguityHint(verb: verb, address: address, panes: panes))
        return nil
    case .error(let msg):
        emit(msg, to: stderr)
        return nil
    default:
        emit("unexpected response from list", to: stderr)
        return nil
    }
}

/// Multi-pane disambiguation message shown when a bare-worktree
/// `pane show` / `pane send` lands on a worktree with >1 panes. Includes
/// a literal copy-pasteable next-step invocation: when the caller passed
/// a `<wt>` address, show `graftty pane <verb> <wt>:<id>`; when they
/// omitted it, show the shorter `graftty pane <verb> <id>` form.
func formatAmbiguityHint(verb: PaneVerb, address: String?, panes: [PaneInfo]) -> String {
    let header: String
    let nextStep: String
    if let address {
        header = "graftty: '\(address)' has \(panes.count) panes — specify a pane:"
        nextStep = "Use 'graftty pane \(verb.rawValue) \(address):<id>' to target one."
    } else {
        header = "graftty: current worktree has \(panes.count) panes — specify a pane:"
        nextStep = "Use 'graftty pane \(verb.rawValue) <id>' to target one."
    }
    var out = header + "\n"
    for p in panes { out += "  " + p.formattedLine() + "\n" }
    out += nextStep + "\n"
    return out
}

/// Write a `graftty: <msg>` line to `sink` (newline included). Mirror
/// of `CLIEnv.printError` but goes through the injected sink so tests
/// can capture the output.
private func emit(_ msg: String, to sink: TextSink) {
    sink.write("graftty: \(msg)\n")
}

// MARK: - Test seams

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

    /// Resolve the optional `<addr>` positional shared by every
    /// `graftty pane *` subcommand to a `(worktree path, optional
    /// pane id)`. Empty / `<id>` forms resolve via the current PWD just
    /// like `resolveWorktree()`; `<wt>` / `<wt>:<id>` forms look up the
    /// worktree by sanitized branch name in the persisted state. The
    /// missing-current-worktree, unknown-worktree, and invalid-address
    /// branches all surface a copy-pasteable next-step hint via the
    /// injected sink and throw `ExitCode(1)`.
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

    /// PWD-resolution failure on a `pane *` command needs the longer
    /// next-step hint so the agent can fix it without reading the docs.
    /// The bare `resolveWorktree()` (used by `notify`) keeps its short
    /// historical message.
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
