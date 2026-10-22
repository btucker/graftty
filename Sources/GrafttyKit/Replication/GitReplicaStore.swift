import Foundation
import GrafttyProtocol

public enum GitReplicaObjectFormat: String, Sendable { case sha1, sha256 }

/// A parent-owned receive process plan. Keep its hook directory intact until the
/// process and its children have exited: Git treats an absent pre-receive hook as
/// permission to proceed. No automatic deletion occurs when this value is dropped.
public struct GitReceiveCommand: Sendable {
    public let repository: URL
    public let hooksDirectory: URL
    public let arguments: [String]
    public let environment: [String: String]
    public var executable: URL { URL(fileURLWithPath: "/usr/bin/env") }

    /// Useful for Git's --receive-pack entry point. Incoming command arguments
    /// cannot select a different repository or alter the parent-owned hook path.
    public var shellCommand: String {
        let env = environment.keys.sorted().map { $0 + "=" + environment[$0]! }
        return "#!/bin/sh\nexec " + ([executable.path, "-i"] + env + arguments)
            .map(WorktreeAgentLaunchCommand.shellLiteral).joined(separator: " ") + "\n"
    }

    static func gitEnvironment() -> [String: String] {
        let inherited = CLIRunner.enrichedEnvironment()
        var result: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "LC_ALL"] { result[key] = inherited[key] }
        result["GIT_CONFIG_NOSYSTEM"] = "1"
        result["GIT_CONFIG_GLOBAL"] = "/dev/null"
        result["GIT_TERMINAL_PROMPT"] = "0"
        return result
    }
}

/// Owned by the parent's receiver service. Only this service creates replicas;
/// peer payloads cannot choose a filesystem path or origin destination.
public actor GitReplicaStore {
    private let directory: URL
    private let delegations: GitDelegationStore
    private let cliExecutable: URL
    private var preparing: Set<URL> = []

    public init(directory: URL, delegations: GitDelegationStore, cliExecutable: URL) {
        self.directory = directory; self.delegations = delegations; self.cliExecutable = cliExecutable
    }

    public func prepareReceive(scope: GitDelegationScope, authenticatedPeer: RemoteMacConnectionSummary.ID,
                               objectFormat: GitReplicaObjectFormat) async throws -> GitReceiveCommand {
        let assignment = try delegations.authorize(scope, authenticatedPeer: authenticatedPeer)
        guard directory.isFileURL, cliExecutable.isFileURL,
              FileManager.default.isExecutableFile(atPath: cliExecutable.path) else { throw GitReceiveHookError.invalidContext }
        let root = URL(fileURLWithPath: CanonicalPath.canonicalize(directory.path), isDirectory: true)
        let assignmentDirectory = root.appendingPathComponent(assignment.id.uuidString.lowercased(), isDirectory: true)
        let generationDirectory = assignmentDirectory.appendingPathComponent(String(assignment.generation), isDirectory: true)
        let repository = generationDirectory.appendingPathComponent("repository.git", isDirectory: true)
        guard preparing.insert(repository).inserted else { throw HostRuntimeError.busy("Replica preparation is already in progress") }
        defer { preparing.remove(repository) }
        for path in [root, assignmentDirectory, generationDirectory, repository] { try Self.privateDirectory(path) }
        let environment = GitReceiveCommand.gitEnvironment()
        // Empty templates prevent inherited repository hooks from running. The
        // generated path is always a separate bare repository, never a checkout.
        _ = try await git(["init", "--bare", "--template=", "--object-format=" + objectFormat.rawValue, repository.path],
                          at: generationDirectory, environment: environment)
        let bare = try await git(["rev-parse", "--is-bare-repository"], at: repository, environment: environment)
        let format = try await git(["rev-parse", "--show-object-format"], at: repository, environment: environment)
        guard bare == "true", format == objectFormat.rawValue else { throw GitReceiveHookError.wrongRepository }
        let hooks = generationDirectory.appendingPathComponent("receive-" + UUID().uuidString.lowercased(), isDirectory: true)
        try Self.privateDirectory(hooks)
        let context = GitReceiveHookContext(delegationDirectory: delegations.directory.path, repositoryPath: repository.path,
            scope: scope, authenticatedPeer: authenticatedPeer)
        let contextFile = hooks.appendingPathComponent("context.json")
        try JSONFileStore<GitReceiveHookContext>(fileURL: contextFile, posixPermissions: 0o600).save(context)
        let hook = hooks.appendingPathComponent("pre-receive")
        try Data(GitReceiveHook.script(executable: cliExecutable.path, contextFile: contextFile.path).utf8).write(to: hook, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try Task.checkCancellation()
        _ = try delegations.authorize(scope, authenticatedPeer: authenticatedPeer)
        return GitReceiveCommand(repository: repository, hooksDirectory: hooks, arguments: ["git",
            "-c", "core.hooksPath=" + hooks.path, "-c", "receive.fsckObjects=true", "-c", "receive.denyDeletes=true",
            "-c", "receive.autogc=false", "receive-pack", repository.path], environment: environment)
    }

    private static func privateDirectory(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw GitReceiveHookError.invalidContext }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func git(_ args: [String], at directory: URL, environment: [String: String]) async throws -> String {
        let output = try await Subprocess.run(.init(executable: "/usr/bin/env", arguments: ["git"] + args,
            directory: directory.path, environment: environment, timeout: .seconds(30), timeoutLabel: "git", terminatesOnCancellation: true))
        guard output.status == 0 else {
            throw CLIError.nonZeroExit(command: "git", exitCode: output.status, stderr: String(decoding: output.stderr, as: UTF8.self))
        }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
