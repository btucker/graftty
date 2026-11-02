import ArgumentParser
import Foundation
import GrafttyKit

struct Project: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage local projects in the running Mac app",
        subcommands: [ProjectAdd.self]
    )
}

struct ProjectAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Register a local Git project in the running Mac app",
        discussion: """
        Relative paths resolve against your current working directory. Git roots,
        linked worktrees, and repositories with no commits are supported. Repeating
        an addition preserves the existing project. This command does not initialize
        Git. Use Add Repository in the app for projects without Git.

        Example: graftty project add ../my-project
        """
    )

    @Argument(help: "Path to a local Git repository or linked worktree")
    var path: String

    func run() throws {
        try ProjectAddCommand.run(path: path)
    }
}

enum ProjectAddCommand {
    static func run(
        path: String,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        send: (NotificationMessage) throws -> ResponseMessage = { try SocketClient.sendExpectingResponse($0) },
        writeLine: (String) -> Void = { print($0) }
    ) throws {
        guard !path.isEmpty else { throw ValidationError("Provide a project directory path") }
        let absolutePath = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
            .standardizedFileURL.path
        try CapabilityProbe.require([.projectAdd], send: send)
        let response = try CLIEnv.sendRequest(.addProject(path: absolutePath), using: send, writeError: CLIEnv.printError)
        try CLIEnv.expectOk(response, for: "project add")
        writeLine("registered project=\(WorktreeAgentLaunchCommand.shellLiteral(absolutePath))")
    }
}
