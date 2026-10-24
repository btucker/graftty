import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct RemoteSkills: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "Export and stage user and project skills for remote agents",
        discussion: "Snapshots contain skill directories and supporting files only. Use sync to transfer a snapshot, then remote placement create --skill-revision to install it in a container. Plugin installation, settings, and authentication remain separate. Review the skill content you intend to share; credential filenames and private keys are rejected, but arbitrary secrets embedded in prose cannot be detected reliably.",
        subcommands: [RemoteSkillsExport.self, RemoteSkillsStage.self, RemoteSkillsSync.self])
}

struct RemoteSkillsExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Capture a bounded skill snapshot without changing the source")
    @Option(help: "Agent runtime: codex or claude") var runtime: String
    @Option(help: "Absolute source project or worktree root") var workspace: String
    @Option(help: "Alternate user home; uses native directories here instead of runtime-home environment overrides") var sourceHome: String?
    @Option(help: "New private snapshot file in an existing directory; never overwritten") var output: String

    func validate() throws {
        guard TeamHookRuntime(rawValue: runtime) != nil else { throw ValidationError("Choose codex or claude.") }
        for path in [workspace, output] + (sourceHome.map { [$0] } ?? []) { try RemoteSkillCLIOutput.validatePath(path) }
    }

    func run() throws {
        guard let runtime = TeamHookRuntime(rawValue: runtime) else { throw ValidationError("Choose codex or claude.") }
        let snapshot = try RemoteSkillSnapshot.capture(runtime: runtime,
            home: URL(fileURLWithPath: sourceHome ?? NSHomeDirectory(), isDirectory: true),
            workspace: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: sourceHome == nil ? ProcessInfo.processInfo.environment : [:])
        try snapshot.write(to: URL(fileURLWithPath: output))
        try RemoteSkillCLIOutput.printJSON(["status": "exported", "runtime": runtime.rawValue, "revision": try snapshot.revision,
                                           "fileCount": snapshot.files.count, "output": output])
    }
}

struct RemoteSkillsStage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stage", abstract: "Validate a snapshot revision and stage isolated native skill trees",
        discussion: "Run on the destination after transferring the snapshot through a trusted connection. Parent and project IDs partition local storage; they do not authenticate a sender. Staging does not install into a global home, mount a container, or launch an agent.")
    @Option(help: "Absolute path to the received snapshot file") var input: String
    @Option(help: "Expected SHA-256 revision from the trusted parent export") var revision: String
    @Option(help: "Parent identity associated with this local staging operation") var parentID: String
    @Option(help: "Project identity associated with this local staging operation") var projectID: String
    @Option(help: "Absolute skill store directory; defaults to the host state directory's agent-skills folder") var directory: String?

    func validate() throws {
        try RemoteSkillCLIOutput.validatePath(input)
        if let directory { try RemoteSkillCLIOutput.validatePath(directory) }
        guard revision.count == 64, revision.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ValidationError("Provide the 64-character lowercase revision from the parent export.") }
        guard !parentID.isEmpty, !projectID.isEmpty else { throw ValidationError("Provide parent and project identities.") }
    }

    func run() throws {
        let snapshot = try RemoteSkillSnapshot.read(from: URL(fileURLWithPath: input))
        guard try snapshot.revision == revision else { throw ValidationError("Snapshot revision does not match the expected parent export; nothing was staged.") }
        let root = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? HostConfiguration.defaultStateDirectory().appendingPathComponent("agent-skills", isDirectory: true)
        let installed = try RemoteSkillStore(directory: root).stage(snapshot, parentID: parentID, projectID: projectID)
        try RemoteSkillCLIOutput.printJSON(["status": "staged", "runtime": snapshot.runtime.rawValue, "revision": installed.revision,
            "fileCount": snapshot.files.count, "directory": installed.directory.path,
            "userDirectory": installed.userDirectory.path, "projectDirectory": installed.projectDirectory.path])
    }
}

private enum RemoteSkillCLIOutput {
    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError("Use absolute paths without control characters.")
        }
    }
    static func printJSON(_ fields: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}

struct RemoteSkillsSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Transfer and stage a snapshot on an authenticated paired host",
        discussion: "Requires an updated running parent app, an updated Linux host, and a repository already registered there. Reuse the same snapshot and operation UUID after a lost reply. This stages skills only; it does not activate agent configuration.")
    @Option(help: "Exact connected host name or device ID") var host: String
    @Option(help: "Exact registered repository path on the destination") var repository: String
    @Option(help: "Absolute path to the exported skill snapshot") var input: String
    @Option(help: "Expected revision from the parent export") var revision: String
    @Option(name: .customLong("operation-id"), help: "Stable transfer UUID; reuse it with the same snapshot on retries") var operationID: String

    func validate() throws {
        try RemoteSkillCLIOutput.validatePath(repository)
        try RemoteSkillCLIOutput.validatePath(input)
        guard !host.isEmpty, UUID(uuidString: operationID) != nil,
              revision.count == 64, revision.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ValidationError("Provide a host, stable operation UUID, and the expected snapshot revision.")
        }
    }
    func run() async throws {
        let snapshot = try RemoteSkillSnapshot.read(from: URL(fileURLWithPath: input))
        guard try snapshot.revision == revision else { throw ValidationError("Snapshot does not match the expected revision; nothing was sent.") }
        guard let id = UUID(uuidString: operationID) else { throw ValidationError("Provide a valid operation UUID.") }
        let identity = try RemotePlacementTarget.resolve(host, hosts: RemoteHosts.fetch())
        let result: RemoteSkillTransferStatus
        do {
            result = try await Self.transfer(snapshot, to: identity, repository: repository, operationID: id) { try CLIEnv.sendRequest($0) }
        } catch let error as RemoteSkillError {
            throw ValidationError(error.description)
        } catch {
            throw ValidationError("Skill transfer was not confirmed. Retry the same host, snapshot, and operation UUID; the host may already have staged it. \(error)")
        }
        try RemoteSkillCLIOutput.printJSON(["status": result.phase.rawValue, "runtime": result.descriptor.runtime,
            "revision": result.descriptor.revision, "operationID": result.descriptor.operationID.uuidString,
            "host": identity.deviceID.value, "repository": repository, "receivedBytes": result.receivedBytes])
    }

    static func transfer(_ snapshot: RemoteSkillSnapshot, to identity: RemoteMacConnectionSummary.ID,
                         repository: String, operationID: UUID,
                         send: @Sendable (NotificationMessage) throws -> ResponseMessage) async throws -> RemoteSkillTransferStatus {
        try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: repository, operationID: operationID) { request in
            let response = try send(.remoteSkills(host: identity, request: request))
            switch response {
            case .agentSkills(let status): return status
            case .error(let message): throw RemoteSkillError(message)
            default: throw RemoteSkillError("Parent app did not return a skill transfer response; update both hosts.")
            }
        }
    }
}
