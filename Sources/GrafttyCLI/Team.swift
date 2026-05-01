import ArgumentParser
import Foundation
import GrafttyKit

struct Team: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coordinate with teammates in a Graftty agent team",
        subcommands: [
            TeamSend.self,
            TeamBroadcast.self,
            TeamMembers.self,
            TeamHook.self,
            TeamInbox.self,
            TeamMsg.self,
            TeamList.self,
        ]
    )
}

struct TeamSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a teammate by name"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Member name of the teammate to message")
    var member: String

    @Argument(help: "Message text")
    var text: String?

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let body = try TeamMessageInput.resolve(text: text, stdin: stdin)
        let response = try CLIEnv.sendRequest(
            .teamSend(
                callerWorktree: worktreePath,
                recipient: member,
                text: body,
                priority: urgent ? .urgent : .normal
            )
        )
        try CLIEnv.expectOk(response)
    }
}

struct TeamBroadcast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Send the same message to every teammate"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Message text")
    var text: String?

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let body = try TeamMessageInput.resolve(text: text, stdin: stdin)
        let response = try CLIEnv.sendRequest(
            .teamBroadcast(
                callerWorktree: worktreePath,
                text: body,
                priority: urgent ? .urgent : .normal
            )
        )
        try CLIEnv.expectOk(response)
    }
}

struct TeamMembers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List the members of a worktree's team"
    )

    @Option(name: .long, help: "Worktree path or member name to inspect")
    var worktree: String?

    @Option(name: .long, help: "Repository path to inspect")
    var repo: String?

    func run() throws {
        let callerWorktree = try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        let response = try CLIEnv.sendRequest(
            .teamMembers(callerWorktree: callerWorktree, worktree: worktree, repo: repo)
        )
        try TeamOutput.printMembers(response)
    }
}

struct TeamHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Render agent-team hook context for an agent runtime"
    )

    @Argument(help: "Runtime: codex or claude")
    var runtime: String

    @Argument(help: "Hook event: session-start, post-tool-use, or stop")
    var event: String

    @Option(name: [.customLong("session-id"), .customLong("session")], help: "Stable runtime session identifier")
    var sessionID: String?

    func validate() throws {
        guard TeamHookRuntime(rawValue: runtime) != nil else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        guard TeamHookEvent(rawValue: event) != nil else {
            throw ValidationError("event must be one of: session-start, post-tool-use, stop")
        }
    }

    func run() throws {
        guard let worktreePath = try? WorktreeResolver.resolve() else {
            print("{}")
            return
        }
        let runtime = TeamHookRuntime(rawValue: runtime)!
        let event = TeamHookEvent(rawValue: event)!
        let resolvedSessionID = sessionID ?? ProcessInfo.processInfo.environment["GRAFTTY_AGENT_SESSION_ID"]
        do {
            let response = try SocketClient.sendExpectingResponse(
                .teamHook(
                    callerWorktree: worktreePath,
                    runtime: runtime,
                    event: event,
                    sessionID: resolvedSessionID
                )
            )
            switch response {
            case .teamHookOutput(let output):
                print(output)
            case .error:
                print("{}")
            case .ok, .paneList, .teamList, .teamInbox:
                print("{}")
            }
        } catch {
            print("{}")
        }
    }
}

struct TeamInbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Read team inbox messages without advancing agent cursors"
    )

    @Option(name: .long, help: "Worktree path or member name to inspect")
    var worktree: String?

    @Option(name: .long, help: "Repository path to inspect")
    var repo: String?

    @Option(name: .long, help: "Member name to inspect")
    var member: String?

    @Flag(name: .long, help: "Show unread messages only")
    var unread: Bool = false

    @Flag(name: .long, help: "Show all messages")
    var all: Bool = false

    @Flag(name: .long, help: "Print JSON")
    var json: Bool = false

    func run() throws {
        let callerWorktree = try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        let response = try CLIEnv.sendRequest(
            .teamInbox(
                callerWorktree: callerWorktree,
                worktree: worktree,
                repo: repo,
                member: member,
                unread: unread,
                all: all
            )
        )
        switch response {
        case .teamInbox(let messages):
            if json {
                let data = try JSONEncoder().encode(messages)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                for message in messages {
                    print(TeamOutput.inboxLine(message))
                }
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList, .teamList, .teamHookOutput:
            CLIEnv.printError("Unexpected response for team inbox")
            throw ExitCode(1)
        }
    }
}

struct TeamMsg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send a message to a teammate by name"
    )

    @Argument(help: "Member name (sanitized branch name) of the teammate to message")
    var member: String

    @Argument(help: "Message text")
    var text: String

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(
            .teamSend(callerWorktree: worktreePath, recipient: member, text: text, priority: .normal)
        )
        try CLIEnv.expectOk(response)
    }
}

struct TeamList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the members of this worktree's team"
    )

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.teamList(callerWorktree: worktreePath))
        try TeamOutput.printMembers(response)
    }
}

private enum TeamMessageInput {
    static func resolve(text: String?, stdin: Bool) throws -> String {
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let body = String(data: data, encoding: .utf8) ?? ""
            guard !body.isEmpty else {
                throw ValidationError("message text is required")
            }
            return body
        }
        guard let text, !text.isEmpty else {
            throw ValidationError("message text is required unless --stdin is set")
        }
        return text
    }
}

private enum TeamDiagnosticScope {
    static func resolveCaller(worktree: String?, repo: String?) throws -> String? {
        if worktree != nil || repo != nil {
            return try? WorktreeResolver.resolve()
        }
        return try CLIEnv.resolveWorktree()
    }
}

private enum TeamOutput {
    static func printMembers(_ response: ResponseMessage) throws {
        switch response {
        case .teamList(let teamName, let members):
            print("team=\(teamName)  members=\(members.count)")
            for m in members {
                print(memberLine(m))
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList, .teamHookOutput, .teamInbox:
            CLIEnv.printError("Unexpected response for team members")
            throw ExitCode(1)
        }
    }

    static func memberLine(_ member: TeamListMember) -> String {
        "\(member.name)  branch=\(member.branch)  worktree=\(member.worktreePath)  role=\(member.role)  running=\(member.isRunning)"
    }

    static func inboxLine(_ message: TeamInboxMessage) -> String {
        "\(message.id)  from=\(message.from.member)  to=\(message.to.member)  priority=\(message.priority.rawValue)  \(message.body)"
    }
}
