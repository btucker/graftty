import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct RemotePlacement: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "placement", abstract: "Admit a workload and create a worktree on a paired Linux host",
        discussion: "Requires an already registered repository. Creation uses the host shell; Dev Container preparation and AWS instance launch are not yet integrated. Reuse the same operation UUID when retrying, including after a lost reply. No credentials are copied.",
        subcommands: [RemotePlacementCreate.self, RemotePlacementStatus.self])
}

struct RemotePlacementResources: ParsableArguments {
    @Option(help: "Required architecture: arm64 or x86_64") var architecture: String
    @Option(help: "Required CPU capacity in vCPUs") var cpus: Double = 1
    @Option(help: "Required memory in MiB") var memoryMib: Int64 = 1024
    @Option(help: "Required disk space in MiB") var diskMib: Int64 = 1024
    func demand() throws -> HostPlacementDemand {
        .init(architecture: architecture, cpus: cpus, memoryBytes: try Self.bytes(memoryMib), diskBytes: try Self.bytes(diskMib))
    }
    static func bytes(_ mib: Int64) throws -> Int64 {
        let (bytes, overflow) = mib.multipliedReportingOverflow(by: 1024 * 1024)
        guard !overflow, mib >= 0 else { throw ValidationError("Memory and disk amounts must be non-negative MiB values within range.") }
        return bytes
    }
}

struct RemotePlacementTarget: ParsableArguments {
    @Option(help: "Exact paired host name or device ID from remote hosts") var host: String
    @Option(name: .customLong("operation-id"), help: "Stable UUID for this placement; reuse it on retries") var operationID: String
    @Flag(help: "Print the retained operation as JSON") var json = false
    func validate() throws {
        guard !host.isEmpty, UUID(uuidString: operationID) != nil else { throw ValidationError("Provide a paired host and a valid operation UUID.") }
    }
    func uuid() throws -> UUID {
        guard let value = UUID(uuidString: operationID) else { throw ValidationError("Provide a valid operation UUID.") }
        return value
    }
    static func resolve(_ target: String, hosts: [RemoteMacConnectionSummary]) throws -> RemoteMacConnectionSummary.ID {
        let ids = hosts.filter { $0.deviceID.value == target }
        let matches = ids.isEmpty ? hosts.filter { $0.label == target } : ids
        guard matches.count == 1, let host = matches.first else {
            throw ValidationError("Host is unknown or ambiguous. Use a unique paired device ID from remote hosts.")
        }
        guard host.state == .connected else { throw ValidationError("Host is not connected. Reconnect it before placement.") }
        return host.id
    }
    func run(_ request: HostPlacementRequest) throws {
        let identity = try Self.resolve(host, hosts: RemoteHosts.fetch())
        let response: ResponseMessage
        do { response = try CLIEnv.sendRequest(.remotePlacement(host: identity, request: request)) }
        catch {
            CLIEnv.printError("The placement outcome may be unknown. Query remote placement status with the same host and operation UUID before retrying.")
            throw error
        }
        guard case .placement(let record) = response else {
            try CLIEnv.expectOk(response)
            throw ValidationError("The running Graftty version did not return a placement result.")
        }
        if json {
            let encoder = JSONEncoder.iso8601(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(record), as: UTF8.self))
        } else {
            print("\(record.operationID.uuidString): \(record.state.rawValue)")
            if let path = record.worktreeID { print(String(reflecting: path)) }
            if let message = record.message { print(String(reflecting: message)) }
        }
        if record.state == .outcomeUnknown { throw ExitCode(1) }
    }
}

struct RemotePlacementCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Reserve host resources and create a new branch and worktree")
    @OptionGroup var target: RemotePlacementTarget
    @OptionGroup var resources: RemotePlacementResources
    @Option(help: "Exact registered repository path on the remote host") var repository: String
    @Option(help: "New worktree name") var name: String
    @Option(help: "New branch name; defaults to the worktree name") var branch: String?
    func validate() throws {
        guard repository.hasPrefix("/") else { throw ValidationError("Provide the registered absolute repository path on the remote host.") }
        if let error = WorktreeCreationInput.validationError(worktreeName: name, branchName: branch ?? name) { throw ValidationError(error) }
        try HostPlacementPlanner.validate(demand: resources.demand(), policy: .init())
    }
    func run() throws {
        try target.run(.create(operationID: target.uuid(), intent: .init(repositoryID: repository, worktreeName: name,
            branchName: branch ?? name, demand: resources.demand())))
    }
}

struct RemotePlacementStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Query a retained placement operation on its host")
    @OptionGroup var target: RemotePlacementTarget
    func run() throws { try target.run(.status(operationID: target.uuid())) }
}
