import ArgumentParser
import Foundation
import EspalierKit

@main
struct EspalierCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "espalier",
        abstract: "Espalier terminal multiplexer CLI",
        subcommands: [Notify.self]
    )
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an attention notification to Espalier")

    @Argument(help: "Notification text to display in the sidebar")
    var text: String?

    @Flag(name: .long, help: "Clear the attention notification")
    var clear: Bool = false

    @Option(name: .long, help: "Auto-clear the notification after N seconds")
    var clearAfter: Int?

    func validate() throws {
        if !clear && text == nil {
            throw ValidationError("Provide notification text or use --clear")
        }
    }

    func run() throws {
        let worktreePath: String
        do {
            worktreePath = try WorktreeResolver.resolve()
        } catch {
            printError("Not inside a tracked worktree")
            throw ExitCode(1)
        }

        let message: NotificationMessage
        if clear {
            message = .clear(path: worktreePath)
        } else {
            message = .notify(path: worktreePath, text: text!, clearAfter: clearAfter.map { TimeInterval($0) })
        }

        do {
            try SocketClient.send(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        }
    }

    private func printError(_ msg: String) {
        FileHandle.standardError.write(Data("espalier: \(msg)\n".utf8))
    }
}
