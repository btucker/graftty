import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Remote: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up and manage remote hosts",
        subcommands: [RemoteSkills.self, RemotePlacement.self, RemotePlacementPlan.self, RemoteHosts.self, RemoteReconnect.self, RemoteReconnectClient.self, RemoteSetupLinux.self]
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
        try CLIEnv.expectOk(CLIEnv.sendRequest(.reconnectRemoteClient(target: target)), for: "remote reconnect-client")
        print("Reconnect requested from \(target). Check that Mac's Remote Hosts sidebar for status.")
    }
}

struct RemoteReconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reconnect",
        abstract: "Request a reconnect to a paired Remote Mac",
        discussion: """
        Use the exact saved name shown in the Remote Hosts sidebar or a device ID.
        Quote names containing spaces. Graftty must be running on this Mac.
        This command works outside a worktree and returns once the request is
        accepted. Check the Remote Hosts sidebar for connection status.

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
        try CLIEnv.expectOk(CLIEnv.sendRequest(.reconnectRemoteMac(target: target)), for: "remote reconnect")
        print("Reconnect requested for \(target). Check the Remote Hosts sidebar for status.")
    }
}

struct RemoteHosts: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hosts", abstract: "List paired hosts and authenticated resource observations",
        discussion: "Graftty must be running. Unknown or stale metrics do not imply spare capacity. Disk measurements apply only to the reported filesystem path. AWS inventory is available separately through provider hosts aws.")
    @Flag(help: "Print identities, connection states, resource observations, and freshness as JSON") var json = false
    static func fetch() throws -> [RemoteMacConnectionSummary] {
        let response = try CLIEnv.sendRequest(.listRemoteHosts)
        guard case .remoteHosts(let hosts) = response else {
            try CLIEnv.expectOk(response, for: "remote hosts")
            throw ValidationError("The running Graftty version does not support host telemetry.")
        }
        return hosts
    }
    func run() throws {
        let hosts = try Self.fetch()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(hosts), as: UTF8.self))
            return
        }
        print("DEVICE\tNAME\tCONNECTION\tMETRICS\tARCH\tVCPU\tCPU_FRACTION\tAVAILABLE_MEMORY_BYTES\tAVAILABLE_DISK_BYTES\tDISK_PATH")
        for host in hosts {
            let fresh = host.resourceObservation?.isFresh() == true && host.state == .connected
            let sample = fresh ? host.resourceObservation?.sample : nil
            let cells: [String] = [host.deviceID.value, host.label, host.state.rawValue,
                fresh ? "fresh" : (host.resourceObservation == nil ? "unavailable" : "stale"),
                sample?.architecture ?? "unknown", Self.metric(sample?.cpuCount), Self.metric(sample?.cpuUtilization),
                Self.metric(sample?.memoryAvailableBytes), Self.metric(sample?.diskAvailableBytes), sample?.diskPath ?? "unknown"]
            print(cells.map { $0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined() }.joined(separator: "\t"))
        }
        if hosts.isEmpty { print("No paired hosts.") }
    }
    private static func metric<T: CustomStringConvertible>(_ value: T?) -> String {
        value.map { $0.description } ?? "unknown"
    }

}
