import ArgumentParser
import Foundation
import GrafttyKit

struct Team: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coordinate with teammates in a Graftty agent team",
        subcommands: [TeamMsg.self, TeamList.self]
    )
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
            .teamMessage(callerWorktree: worktreePath, recipient: member, text: text)
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
        switch response {
        case .teamList(let teamName, let members):
            print("team=\(teamName)  members=\(members.count)")
            for m in members {
                print("\(m.name)  branch=\(m.branch)  worktree=\(m.worktreePath)  role=\(m.role)  running=\(m.isRunning)")
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList:
            CLIEnv.printError("Unexpected response for team list")
            throw ExitCode(1)
        }
    }
}
