import ArgumentParser
import Foundation
import GrafttyKit

struct RemoteSkills: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "Export and stage user and project skills for remote agents",
        discussion: "Snapshots contain skill directories and supporting files only. Plugin installation, settings, authentication, automatic transfer, and agent activation are separate. Review the skill content you intend to share; credential filenames and private keys are rejected, but arbitrary secrets embedded in prose cannot be detected reliably.",
        subcommands: [RemoteSkillsExport.self, RemoteSkillsStage.self])
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
