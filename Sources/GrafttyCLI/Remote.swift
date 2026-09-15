import ArgumentParser
import Foundation
import GrafttyKit

struct Remote: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage paired Remote Macs",
        subcommands: [RemoteReconnect.self, RemoteReconnectClient.self]
    )
}

struct RemoteReconnectClient: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reconnect-client",
        abstract: "Ask a connected viewing Mac to reconnect to this Mac",
        discussion: """
        Run on the Mac hosting the remote shell. Use the viewing Mac's exact
        paired name or device ID. A targeting error lists connected clients.
        Both Macs need a version of Graftty supporting this command, and the
        existing control channel must still work. No current worktree is required.
        Success means the viewer accepted the request; connection establishment
        continues on that Mac. This command does not resend team messages.

        Example:
          graftty remote reconnect-client "Laptop"
        """
    )

    @Argument(help: ArgumentHelp("Connected viewing Mac name or device ID", valueName: "name-or-id"))
    var target: String

    func validate() throws {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("Provide a connected viewing Mac name or device ID")
        }
    }

    func run() throws {
        try CLIEnv.expectOk(CLIEnv.sendRequest(.reconnectRemoteClient(target: target)))
        print("Reconnect requested from \(target). Check that Mac's Remote Macs sidebar for status.")
    }
}

struct RemoteReconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reconnect",
        abstract: "Request a reconnect to a paired Remote Mac",
        discussion: """
        Use the exact saved name shown in the Remote Macs sidebar or a device ID.
        Quote names containing spaces. Graftty must be running on this Mac.
        This command works outside a worktree and returns once the request is
        accepted. Check the Remote Macs sidebar for connection status.

        Example:
          graftty remote reconnect "Studio Mac"
        """
    )

    @Argument(help: ArgumentHelp("Saved Remote Mac name or device ID", valueName: "name-or-id"))
    var target: String

    func validate() throws {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("Provide a saved Remote Mac name or device ID")
        }
    }

    func run() throws {
        try CLIEnv.expectOk(CLIEnv.sendRequest(.reconnectRemoteMac(target: target)))
        print("Reconnect requested for \(target). Check the Remote Macs sidebar for status.")
    }
}
